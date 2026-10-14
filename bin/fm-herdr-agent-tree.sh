#!/usr/bin/env bash
# fm-herdr-agent-tree.sh - Agent Tree pane tags for this home.
#
# Herdr's Agent Tree plugin nests each worker pane under the coordinator pane
# that launched it, linking the two by home hash (docs/herdr-backend.md "Agent
# Tree pane tags"). This script is the one entry point for every tag:
# bin/fm-spawn.sh tags a worker pane at launch, and bin/fm-session-start.sh tags
# its own coordinator pane and the live workers it re-adopts from state/*.meta.
#
# Usage:
#   fm-herdr-agent-tree.sh coordinator
#       Tag this session's own pane ($HERDR_PANE_ID in $HERDR_SESSION, default
#       `default`) with at_home_owner=<home-hash6>. state/.herdr-agent-tree-owner
#       records the owner pane on its first line and, below it, every earlier
#       owner pane whose tag is not yet confirmed gone, each as
#       <session>:<pane-id>. Each run sends --clear-token at_home_owner to every
#       such earlier pane that still carries this home's hash, and keeps a pane
#       in the record until a read confirms it gone or untagged by this home, or
#       a clear succeeds, so a failed read or clear is retried on the next
#       start. No-op without HERDR_PANE_ID. The caller must already hold this
#       home's session lock; a lock-refused session must not run it.
#   fm-herdr-agent-tree.sh child <session>:<pane-id> [<agb-id>]
#       Tag one worker pane with at_home=<home-hash6>, plus at_agb=<agb-id>
#       when given; without an agb id it clears any at_agb the pane still
#       carries from an earlier occupant.
#
# The home hash is `bin/fm-agb.sh home-hash` for $FM_HOME, so run it with the
# LAUNCHING home's FM_HOME. Every run is bounded by FM_HERDR_AGENT_TREE_TIMEOUT
# seconds (default 3), which covers herdr's client-reselection retry and kills
# the whole process group at the bound. Every tag is display-only and
# best-effort: this script prints nothing and always exits 0, so it never
# changes a launch, a session start, or an adoption outcome.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
esac

if [ -z "${FM_HERDR_AGENT_TREE_BOUNDED:-}" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  budget=${FM_HERDR_AGENT_TREE_TIMEOUT:-3}
  case "$budget" in ''|*[!0-9]*) budget=3 ;; esac
  [ "$budget" -gt 0 ] 2>/dev/null || budget=3
  FM_HERDR_AGENT_TREE_BOUNDED=1 fm_run_timed "$budget" bash "${BASH_SOURCE[0]}" "$@" </dev/null >/dev/null 2>&1 || true
  exit 0
fi

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr || exit 0

fm_herdr_agent_tree_home_hash() {
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-agb.sh" home-hash 2>/dev/null
}

# fm_herdr_agent_tree_retire <target> <hash>: succeed only once <target> is
# confirmed not to carry this home's at_home_owner any more.
fm_herdr_agent_tree_retire() {
  local state
  fm_backend_herdr_parse_target "$1" || return 0
  state=$(fm_backend_herdr_pane_token_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" at_home_owner)
  case "$state" in
    absent) return 0 ;;
    "value $2")
      fm_backend_herdr_agent_tree_report "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        --clear-token at_home_owner
      ;;
    value\ *) return 0 ;;
    *) return 1 ;;
  esac
}

fm_herdr_agent_tree_coordinator() {
  local pane=${HERDR_PANE_ID:-} hash record current prior tmp line
  local -a pending=()
  [ -n "$pane" ] || return 0
  hash=$(fm_herdr_agent_tree_home_hash) && [ -n "$hash" ] || return 0
  current="$(fm_backend_herdr_session):$pane"
  record="$STATE/.herdr-agent-tree-owner"
  prior=
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    prior=$(cat "$record" 2>/dev/null) || prior=
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && [ "$line" != "$current" ] || continue
    fm_herdr_agent_tree_retire "$line" "$hash" || pending+=("$line")
  done <<EOF
$prior
EOF
  fm_backend_herdr_agent_tree_report "${current%%:*}" "$pane" --token "at_home_owner=$hash" || true
  [ -d "$STATE" ] || return 0
  tmp=$(mktemp "$STATE/.herdr-agent-tree-owner.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$current" ${pending[@]+"${pending[@]}"} >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$record" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
}

fm_herdr_agent_tree_child() {  # <session>:<pane-id> [<agb-id>]
  local hash
  local -a tokens
  fm_backend_herdr_parse_target "$1" || return 0
  hash=$(fm_herdr_agent_tree_home_hash) && [ -n "$hash" ] || return 0
  tokens=(--token "at_home=$hash")
  if [ -n "${2:-}" ]; then
    tokens+=(--token "at_agb=$2")
  else
    tokens+=(--clear-token at_agb)
  fi
  fm_backend_herdr_agent_tree_report "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" "${tokens[@]}" || true
}

case "${1:-}" in
  coordinator) [ $# -eq 1 ] && fm_herdr_agent_tree_coordinator ;;
  child) { [ $# -eq 2 ] || [ $# -eq 3 ]; } && fm_herdr_agent_tree_child "$2" "${3:-}" ;;
esac
exit 0
