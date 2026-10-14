#!/usr/bin/env bash
# fm-herdr-agent-tree.sh - session-start Agent Tree pane tags for this home.
#
# Herdr's Agent Tree plugin nests each worker pane under the coordinator pane
# that launched it, linking the two by home hash (docs/herdr-backend.md "Agent
# Tree pane tags"). bin/fm-spawn.sh tags a worker pane at launch; this script
# covers what a starting session owns: its own coordinator pane, and the live
# workers it re-adopts from state/*.meta.
#
# Usage:
#   fm-herdr-agent-tree.sh coordinator
#       Tag this session's own pane ($HERDR_PANE_ID in $HERDR_SESSION, default
#       `default`) with at_home_owner=<home-hash6>. When the previously recorded
#       owner pane is a different pane that still carries this home's
#       at_home_owner, clear that token on it first, so two overlapping panes
#       never both claim the home. The pane holding the tag is recorded in
#       state/.herdr-agent-tree-owner as <session>:<pane-id>. No-op without
#       HERDR_PANE_ID.
#   fm-herdr-agent-tree.sh child <session>:<pane-id> [<agb-id>]
#       Re-tag one adopted worker pane with at_home=<home-hash6> and, when
#       given, at_agb=<agb-id>.
#
# The caller must already hold this home's session lock; a lock-refused session
# must not run it. Every tag is display-only and best-effort: this script prints
# nothing and always exits 0, so it never changes a session-start outcome.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr || exit 0

fm_herdr_agent_tree_home_hash() {
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-agb.sh" home-hash 2>/dev/null
}

fm_herdr_agent_tree_coordinator() {
  local pane=${HERDR_PANE_ID:-} session hash record current recorded tmp
  [ -n "$pane" ] || return 0
  hash=$(fm_herdr_agent_tree_home_hash) && [ -n "$hash" ] || return 0
  session=$(fm_backend_herdr_session)
  current="$session:$pane"
  record="$STATE/.herdr-agent-tree-owner"
  recorded=
  [ -f "$record" ] && [ ! -L "$record" ] && recorded=$(awk 'NF { print $1; exit }' "$record" 2>/dev/null)
  if [ -n "$recorded" ] && [ "$recorded" != "$current" ] && fm_backend_herdr_parse_target "$recorded" \
    && [ "$(fm_backend_herdr_pane_token "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" at_home_owner)" = "$hash" ]; then
    fm_backend_herdr_agent_tree_report "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
      --clear-token at_home_owner
  fi
  fm_backend_herdr_agent_tree_report "$session" "$pane" --token "at_home_owner=$hash"
  [ "$recorded" = "$current" ] && return 0
  [ -d "$STATE" ] || return 0
  tmp=$(mktemp "$STATE/.herdr-agent-tree-owner.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$current" >"$tmp" 2>/dev/null && mv -f "$tmp" "$record" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
}

fm_herdr_agent_tree_child() {  # <session>:<pane-id> [<agb-id>]
  local hash session pane
  local -a tokens
  fm_backend_herdr_parse_target "$1" || return 0
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  hash=$(fm_herdr_agent_tree_home_hash) && [ -n "$hash" ] || return 0
  tokens=(--token "at_home=$hash")
  [ -z "${2:-}" ] || tokens+=(--token "at_agb=$2")
  fm_backend_herdr_agent_tree_report "$session" "$pane" "${tokens[@]}"
}

case "${1:-}" in
  coordinator) [ $# -eq 1 ] && fm_herdr_agent_tree_coordinator ;;
  child) { [ $# -eq 2 ] || [ $# -eq 3 ]; } && fm_herdr_agent_tree_child "$2" "${3:-}" ;;
  -h|--help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' ;;
esac
exit 0
