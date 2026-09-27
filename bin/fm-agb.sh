#!/usr/bin/env bash
# fm-agb.sh - the single owner of Firstmate's agb (agent broker) integration.
#
# agb is a faster, optional delivery path layered over Firstmate's durable
# records; it never replaces them. The steering inbox file stays the delivery
# record (bin/fm-task-inbox-lib.sh) and state/<id>.status stays the worker's
# report record (bin/fm-brief.sh). agb carries only the firstmate -> worker
# doorbell, so a lost, dead-lettered, or refused agb message costs latency,
# never work: the terminal doorbell remains the fallback and is unchanged when
# agb is absent or disabled.
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
#            the worker. Only claude, codex, and opencode have an agb runtime;
#            registration is verified for claude, while a codex or opencode
#            worker without an agb hook stays unregistered and keeps the
#            typed doorbell.
#
# Direction: firstmate -> worker only.
#   `ring`   the doorbell line goes as agb mail when the task's inbox carries a .agb-id and agb reports that identity live;
#            otherwise the caller types the doorbell into the terminal as
#            before. agb mail is not delivery proof, exactly like a typed ring:
#            the worker's move into handled/ is the only acknowledgement, and
#            the watcher's re-ring ladder still applies.
#
# There is deliberately no worker -> firstmate agb mail. A status line is
# surfaced by the watcher's signal wake, which classifies it and lingers to
# coalesce the worker's turn end; an earlier agb wake reached firstmate before
# the watcher had classified anything, so its drain showed nothing and the
# watcher's own wake followed anyway - one empty turn per status line.
#
# Usage:
#   fm-agb.sh enabled                         exit 0 when agb is usable here
#   fm-agb.sh worker-id <task-id>             print the worker identity
#   fm-agb.sh runtime <harness>               print claude|codex|opencode, else exit 1
#   fm-agb.sh ring <record-path> <line>       exit 0 rang by agb, 1 caller must type
#   fm-agb.sh forget <task-id>                drop a finished worker identity (best-effort)
#   fm-agb.sh reserve <task-id> <recap>       hold the worker identity before launch (best-effort)
# Every agb call is bounded by FM_AGB_TIMEOUT seconds (default 5).
set -u

FM_AGB_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_AGB_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$FM_AGB_SELF_DIR/.." && pwd)}
FM_AGB_HOME=${FM_HOME:-$FM_AGB_ROOT}
FM_AGB_CONFIG=${FM_CONFIG_OVERRIDE:-$FM_AGB_HOME/config}
FM_AGB_TIMEOUT=${FM_AGB_TIMEOUT:-5}
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_AGB_SELF_DIR/fm-timeout-lib.sh"

fm_agb_call() {
  fm_run_timed "$FM_AGB_TIMEOUT" agb "$@"
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
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$root" | shasum -a 256 | cut -c1-6
  else
    printf '%s' "$root" | sha256sum | cut -c1-6
  fi
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

fm_agb_reserve() {  # <task-id> <recap>
  fm_agb_enabled || return 0
  fm_agb_call reserve "$(fm_agb_worker_id "$1")" --recap "$2" >/dev/null 2>&1 || true
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
    ring)
      [ $# -eq 2 ] || { echo "usage: fm-agb.sh ring <record-path> <doorbell-line>" >&2; return 2; }
      fm_agb_ring "$1" "$2"
      ;;
    reserve) [ $# -eq 2 ] || { echo "usage: fm-agb.sh reserve <task-id> <recap>" >&2; return 2; }; fm_agb_reserve "$1" "$2" ;;
    forget) [ $# -eq 1 ] || { echo "usage: fm-agb.sh forget <task-id>" >&2; return 2; }; fm_agb_forget "$1" ;;
    *) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; [ -n "$cmd" ] && [ "$cmd" != --help ] && [ "$cmd" != -h ] && return 2; return 0 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_agb_main "$@"
fi
