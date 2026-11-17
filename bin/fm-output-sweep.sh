#!/usr/bin/env bash
# fm-output-sweep.sh - one-time sweep of build output that finished tasks left
# behind outside their worktree.
#
# Usage: fm-output-sweep.sh [--delete]
#
# Without --delete it only lists, and deletes nothing. With --delete it removes
# the listed build folders. Only a folder that a finished task's record names is
# ever deleted: <data>/<id>/output.record, which bin/fm-teardown.sh writes for a
# build folder it had to keep (held by a process, shared with a live task, ...),
# for a task whose state/<id>.meta is gone. A task that still has its meta is
# live and skipped. Every deletion goes through the guard in
# bin/fm-task-output-lib.sh, the same one teardown uses, which owns the rules
# (output roots, depth, symlinks, held files, overlap with live tasks).
# The sweep only looks under the configured output root (config/task-output-root)
# and this home's data/ folder, never anywhere else.
#
# Folders directly under the configured root that no task record or live task
# names (another user's, another agent's, anything unknown) are listed as
# "unrecorded" with their size and are never deleted, with or without --delete.
# Tasks that ended before this record existed left no record, so their folders
# are listed as unrecorded too.
#
# Output lines (tab-free, one per folder):
#   would-free <size> <path>    list mode: a recorded folder that would go
#   freed <size> <path>         --delete: removed
#   kept (<reason>) <path>      left in place, with the rule that kept it
#   unrecorded <size> <path>    no task record names it; never deleted
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-task-output-lib.sh
. "$SCRIPT_DIR/fm-task-output-lib.sh"

MODE=list
case "${1:-}" in
  '') ;;
  --delete) MODE=delete ;;
  *) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac

named=$'\n'   # every path a record names, newline-delimited
freed_kb=0
emit() {  # <kind> <a> <b>
  case "$1" in
    freed|would-free)
      [ "$1" != freed ] || freed_kb=$((freed_kb + $2))
      printf '%s %s %s\n' "$1" "$(fm_task_output_human "$2")" "$3" ;;
    kept) printf 'kept (%s) %s\n' "$2" "$3" ;;
  esac
}

# Live tasks: their folders are never the sweep's business.
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  for key in output_build output_proof; do
    value=$(sed -n "s/^$key=//p" "$meta" | tail -1)
    [ -z "$value" ] || named="$named$value"$'\n'
  done
done

for record in "$DATA"/*/output.record; do
  [ -f "$record" ] && [ ! -L "$record" ] || continue
  id=${record%/output.record}
  id=${id##*/}
  fm_task_id_path_safe "$id" || continue
  if [ -e "$STATE/$id.meta" ]; then
    printf 'kept (task %s is still live) %s\n' "$id" "$record"
    continue
  fi
  remaining=()
  while IFS= read -r build; do
    [ -n "$build" ] || continue
    named="$named$build"$'\n'
    while IFS=$'\t' read -r kind a b; do emit "$kind" "$a" "$b"; done \
      < <(fm_task_output_reclaim "$MODE" "$id" "$STATE" "$CONFIG" "$DATA" "$build")
    if [ -e "$build" ] || [ -L "$build" ]; then remaining+=("$build"); fi
  done < <(sed -n 's/^output_build=//p' "$record")
  if [ "$MODE" = delete ]; then
    fm_task_output_record_leftover "$DATA" "$id" ${remaining[@]+"${remaining[@]}"} || true
  fi
done

root=$(fm_task_output_configured_root "$CONFIG") || root=
if [ -n "$root" ] && [ -d "$root" ] && [ "$(fm_task_output_real "$root")" != "$(fm_task_output_real "$DATA")" ]; then
  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    recorded=0
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if fm_task_output_overlaps "$dir" "$path"; then recorded=1; break; fi
    done <<NAMED
$named
NAMED
    [ "$recorded" = 1 ] || printf 'unrecorded %s %s\n' \
      "$(fm_task_output_human "$(fm_task_output_size_kb "$dir")")" "$dir"
  done
fi
[ "$MODE" != delete ] || printf 'sweep freed %s in total\n' "$(fm_task_output_human "$freed_kb")"
