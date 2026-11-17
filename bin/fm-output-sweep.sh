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
# The sweep only looks under /store/agent-outputs and this home's data/ folder,
# never anywhere else.
#
# Folders directly under /store/agent-outputs (and inside its home-* folders) that no task record or live task names
# (another user's, another agent's, anything unknown), and this home's
# data/<id>/<folder> folders other than proof likewise, are listed as "unrecorded" with their size
# and are never deleted, with or without --delete.
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
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
  lock=$(fm_meta_lock_path "$STATE/$id.meta") || continue
  if ! fm_lock_try_acquire "$lock"; then
    printf 'kept (task %s is being spawned or torn down) %s\n' "$id" "$record"
    continue
  fi
  if [ -e "$STATE/$id.meta" ]; then
    fm_lock_release "$lock" || true
    printf 'kept (task %s is still live) %s\n' "$id" "$record"
    continue
  fi
  remaining=()
  while IFS= read -r build; do
    [ -n "$build" ] || continue
    named="$named$build"$'\n'
    while IFS=$'\t' read -r kind a b; do emit "$kind" "$a" "$b"; done \
      < <(fm_task_output_reclaim "$MODE" "$id" "$STATE" "$DATA" "$build")
    if [ -e "$build" ] || [ -L "$build" ]; then remaining+=("$build"); fi
  done < <(sed -n 's/^output_build=//p' "$record")
  if [ "$MODE" = delete ]; then
    fm_task_output_record_leftover "$DATA" "$id" ${remaining[@]+"${remaining[@]}"} || true
  fi
  fm_lock_release "$lock" || true
done

# Unrecorded folders, listed only: the id folders and their per-home folders
# under /store/agent-outputs, and this home's
# <data>/<id>/<folder> folders.
list_unrecorded() {  # <dir>
  local dir=$1 path recorded=0
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if fm_task_output_overlaps "$dir" "$path"; then recorded=1; break; fi
  done <<NAMED
$named
NAMED
  [ "$recorded" = 1 ] || printf 'unrecorded %s %s\n' \
    "$(fm_task_output_human "$(fm_task_output_size_kb "$dir")")" "$dir"
}
names_inside() {  # <dir>: 0 when a recorded path sits inside <dir>
  local path
  while IFS= read -r path; do
    case "$path/" in "$1"/?*) return 0 ;; esac
  done <<NAMED
$named
NAMED
  return 1
}
own_key=$(fm_task_output_home_key "$DATA")
shopt -s nullglob dotglob
# shellcheck disable=SC2066 # single store root, kept as a loop for the shared body
for scan in "$FM_TASK_OUTPUT_STORE_ROOT"; do
  [ -d "$scan" ] && [ ! -L "$scan" ] || continue
  for dir in "$scan"/*; do
    case "${dir##*/}" in
      home-*)
        if [ "${dir##*/}" = "$own_key" ] || names_inside "$dir"; then
          [ -L "$dir" ] || for task_dir in "$dir"/*; do list_unrecorded "$task_dir"; done
        else
          list_unrecorded "$dir"
        fi ;;
      *) list_unrecorded "$dir" ;;
    esac
  done
done | sort -u
for dir in "$DATA"/*/*; do
  [ ! -L "${dir%/*}" ] || continue
  [ "${dir##*/}" != proof ] || continue
  list_unrecorded "$dir"
done
shopt -u nullglob dotglob
[ "$MODE" != delete ] || printf 'sweep freed %s in total\n' "$(fm_task_output_human "$freed_kb")"
