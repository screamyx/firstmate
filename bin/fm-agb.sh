#!/usr/bin/env bash
# fm-agb.sh - the single owner of Firstmate's agb (agent broker) integration.
#
# agb is a faster, optional delivery path layered over Firstmate's durable
# records; it never replaces them. The steering inbox file stays the delivery
# record (bin/fm-task-inbox-lib.sh) and state/<id>.status stays the worker's
# report record (bin/fm-brief.sh). agb only carries the "look now" nudge in
# each direction, so a lost, dead-lettered, or refused agb message costs
# latency, never work: the terminal doorbell and the watcher poll remain the
# fallback and are unchanged when agb is absent or disabled.
#
# Enablement: on when an `agb` binary is on PATH, unless the first non-empty
# line of local, gitignored config/agb is `off`. FM_AGB=off|on overrides the
# file for one process.
#
# Identities:
#   worker   fm-<home-hash6>-<task-id>, lowercased, every character outside
#            [a-z0-9-] mapped to `-`, trimmed to agb's 63-character limit.
#            The home hash keeps equal task ids in two homes apart.
#            bin/fm-spawn.sh reserves it and exports AGB_AGENT_ID,
#            AGB_AGENT_RECAP, and AGB_RUNTIME into the worker pane before
#            launch, so the harness's own agb session-start hook registers
#            the worker. Only claude, codex, and opencode have an agb runtime.
#   firstmate  whatever agb identity the supervising session holds
#            (AGB_AGENT_ID, else `agb status`). It is recorded in
#            state/.agb-supervisor at session start and at every spawn, and
#            read at send time, so a restarted firstmate is found by workers
#            launched before the restart.
#
# Directions:
#   firstmate -> worker  `ring`: the doorbell line goes as agb mail when the
#            task's inbox carries a .agb-id and agb reports that identity live;
#            otherwise the caller types the doorbell into the terminal as
#            before. agb mail is not delivery proof, exactly like a typed ring:
#            the worker's move into handled/ is the only acknowledgement, and
#            the watcher's re-ring ladder still applies.
#   worker -> firstmate  `notify`: after the status append, the worker's
#            status command mails the recorded firstmate identity one short
#            wake line, so firstmate reads the status within seconds instead
#            of at the next watcher poll. The status line itself is never in
#            the mail body; firstmate reads it from the durable record.
#
# Usage:
#   fm-agb.sh enabled                         exit 0 when agb is usable here
#   fm-agb.sh worker-id <task-id>             print the worker identity
#   fm-agb.sh runtime <harness>               print claude|codex|opencode, else exit 1
#   fm-agb.sh record-supervisor               write state/.agb-supervisor (best-effort)
#   fm-agb.sh ring <record-path> <line>       exit 0 rang by agb, 1 caller must type
#   fm-agb.sh notify <state-dir> <task-id>    worker wake to firstmate (best-effort, silent)
#   fm-agb.sh forget <task-id>                drop a finished worker identity (best-effort)
# Every agb call is bounded by FM_AGB_TIMEOUT seconds (default 5).
set -u

FM_AGB_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_AGB_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$FM_AGB_SELF_DIR/.." && pwd)}
FM_AGB_HOME=${FM_HOME:-$FM_AGB_ROOT}
FM_AGB_STATE=${FM_STATE_OVERRIDE:-$FM_AGB_HOME/state}
FM_AGB_CONFIG=${FM_CONFIG_OVERRIDE:-$FM_AGB_HOME/config}
FM_AGB_TIMEOUT=${FM_AGB_TIMEOUT:-5}

fm_agb_call() {
  timeout "$FM_AGB_TIMEOUT" agb "$@"
}

fm_agb_enabled() {
  local setting=${FM_AGB:-}
  command -v agb >/dev/null 2>&1 || return 1
  if [ -z "$setting" ] && [ -f "$FM_AGB_CONFIG/agb" ]; then
    setting=$(awk 'NF { print $1; exit }' "$FM_AGB_CONFIG/agb" 2>/dev/null)
  fi
  [ "$setting" != off ]
}

fm_agb_home_hash() {
  local root
  root=$(cd "$FM_AGB_HOME" 2>/dev/null && pwd -P) || root=$FM_AGB_HOME
  printf '%s' "$root" | sha256sum | cut -c1-6
}

fm_agb_worker_id() {  # <task-id>
  local slug
  slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  printf 'fm-%s-%s' "$(fm_agb_home_hash)" "$slug" | cut -c1-63
}

fm_agb_runtime() {  # <harness>
  case "${1-}" in
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    *) return 1 ;;
  esac
}

fm_agb_live() {  # <agent-id>
  fm_agb_call who --id "$1" --json 2>/dev/null |
    jq -e --arg id "$1" 'any(.agents[]?; .agent_id == $id and .liveness == "live")' >/dev/null 2>&1
}

fm_agb_record_supervisor() {
  local id=${AGB_AGENT_ID:-} tmp
  fm_agb_enabled || return 0
  if [ -z "$id" ]; then
    id=$(fm_agb_call status --json 2>/dev/null | jq -r '.agent_id // empty' 2>/dev/null) || id=
  fi
  [ -n "$id" ] || return 0
  mkdir -p "$FM_AGB_STATE" 2>/dev/null || return 0
  tmp="$FM_AGB_STATE/.agb-supervisor.$$"
  printf '%s\n' "$id" >"$tmp" 2>/dev/null && mv -f "$tmp" "$FM_AGB_STATE/.agb-supervisor" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# The inbox directory of a record, whether it sits in the inbox root or handled/.
fm_agb_inbox_of() {  # <record-path>
  local dir=${1%/*}
  printf '%s' "${dir%/handled}"
}

fm_agb_ring() {  # <record-path> <doorbell-line>
  local rec=$1 line=$2 inbox id
  fm_agb_enabled || return 1
  inbox=$(fm_agb_inbox_of "$rec")
  [ -f "$inbox/.agb-id" ] || return 1
  id=$(awk 'NF { print $1; exit }' "$inbox/.agb-id" 2>/dev/null)
  [ -n "$id" ] || return 1
  fm_agb_live "$id" || return 1
  fm_agb_call send "$id" "${line#: }" >/dev/null 2>&1
}

fm_agb_notify() {  # <state-dir> <task-id>
  local state=$1 task=$2 to
  fm_agb_enabled || return 0
  [ -f "$state/.agb-supervisor" ] || return 0
  to=$(awk 'NF { print $1; exit }' "$state/.agb-supervisor" 2>/dev/null)
  [ -n "$to" ] || return 0
  fm_agb_call send "$to" "Firstmate wake: task $task appended a status line. Run bin/fm-wake-drain.sh." >/dev/null 2>&1 || true
  return 0
}

fm_agb_forget() {  # <task-id>
  fm_agb_enabled || return 0
  fm_agb_call forget "$(fm_agb_worker_id "$1")" --dead-letter >/dev/null 2>&1 || true
  return 0
}

fm_agb_main() {
  local cmd=${1-}
  [ $# -gt 0 ] && shift
  case "$cmd" in
    enabled) fm_agb_enabled ;;
    worker-id) [ $# -eq 1 ] || { echo "usage: fm-agb.sh worker-id <task-id>" >&2; return 2; }; fm_agb_worker_id "$1" ;;
    runtime) fm_agb_runtime "${1-}" ;;
    record-supervisor) fm_agb_record_supervisor ;;
    ring)
      [ $# -eq 2 ] || { echo "usage: fm-agb.sh ring <record-path> <doorbell-line>" >&2; return 2; }
      fm_agb_ring "$1" "$2"
      ;;
    notify) [ $# -eq 2 ] || { echo "usage: fm-agb.sh notify <state-dir> <task-id>" >&2; return 2; }; fm_agb_notify "$1" "$2" ;;
    forget) [ $# -eq 1 ] || { echo "usage: fm-agb.sh forget <task-id>" >&2; return 2; }; fm_agb_forget "$1" ;;
    *) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; [ -n "$cmd" ] && [ "$cmd" != --help ] && [ "$cmd" != -h ] && return 2; return 0 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_agb_main "$@"
fi
