# shellcheck shell=bash
# fm-task-output-lib.sh - a task's own output folder outside its worktree.
#
# ONE OWNER for three things; the spawn, brief, teardown and sweep scripts only
# call it.
#
#   1. Where the folder is. fm_task_output_dir <data> <task-id> prints
#      <store>/<home-key>/<task-id> when <store> (/store/agent-outputs) holds a
#      real, writable <home-key> folder for this home, else <data>/<task-id> in
#      this home's data/ folder. Neither root can be changed by an environment
#      variable or a config file.
#      <home-key> is distinct per firstmate home, so two homes sharing the store
#      never share a task folder. These are the only two output roots. The
#      folder has a build/ part (rebuildable output: cargo target,
#      cargo-home, node_modules, build dirs, lab binaries) and a proof/ part
#      (files a PR body or the owner still needs). fm_task_output_prepare
#      creates both. bin/fm-spawn.sh records the two paths in state/<id>.meta
#      as output_build= and output_proof= and appends the same folder to the
#      launch brief; bin/fm-brief.sh names it through the same resolver.
#
#   2. The delete guard. fm_task_output_reclaim <delete|list> ... removes or
#      lists ONE recorded build folder, and only when every rule holds:
#        - the recorded path is absolute, normalized (no ".", "..", doubled or
#          trailing slash), non-empty, and is itself not a symlink;
#        - its resolved real path sits under a listed output root
#          (/store/agent-outputs or this home's data/ folder, never "/" or a
#          one-level root) and at least two levels below it, so an id folder or
#          a root can never be a target;
#        - the literal path resolves to the same place its text claims, so a
#          symlinked parent below the root cannot redirect the delete;
#        - no other live task (a state/*.meta other than its own) records the
#          same folder, a folder above or inside it, or a proof folder inside
#          it, and its own proof folder is neither inside nor above it;
#        - no process holds anything open inside it (one lsof listing: open
#          files, working folders, mapped binaries). A listing that cannot be
#          read, or an lsof that fails, counts as held. lsof only sees the
#          calling user's processes; another home's user never holds this
#          home's folder because task folders are per home.
#      The delete itself never follows a symlink: the symlink is removed as an
#      entry and its target is untouched. --force never reaches this library,
#      so a forced teardown follows the same rules.
#
#   3. The record a finished task leaves for the sweep. teardown removes
#      state/<id>.meta, so a folder it had to keep is written to
#      <data>/<id>/output.record in the same output_build= format
#      (fm_task_output_record_leftover), and bin/fm-output-sweep.sh reads it.
#
# fm_task_output_reclaim prints tab-separated result lines and always returns 0:
#   freed<TAB><kb><TAB><path>       deleted (delete mode)
#   would-free<TAB><kb><TAB><path>  would be deleted (list mode)
#   kept<TAB><reason><TAB><path>    left in place, with the rule that kept it

# fm_task_output_human <kb>: 1536 -> 1.5M.
fm_task_output_human() {
  awk -v kb="${1:-0}" 'BEGIN {
    split("K M G T", u, " "); v = kb + 0; i = 1
    while (v >= 1024 && i < 4) { v /= 1024; i++ }
    if (i == 1) printf "%dK", v; else printf "%.1f%s", v, u[i]
  }'
}

# fm_task_output_size_kb <path>: disk use in KiB, 0 when unreadable.
fm_task_output_size_kb() {
  local kb
  kb=$(du -sk -- "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  printf '%s' "$kb"
}

# fm_task_output_real <dir>: physical path of an existing directory.
fm_task_output_real() {
  ( CDPATH='' cd -- "$1" 2>/dev/null && pwd -P )
}

# fm_task_output_normalized <path>: absolute, no ".", "..", "//" or trailing "/".
fm_task_output_normalized() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    */) return 1 ;;
    *//*|*/./*|*/.|*/../*|*/..) return 1 ;;
  esac
  return 0
}

FM_TASK_OUTPUT_STORE_ROOT=/store/agent-outputs

# fm_task_output_root_ok <real-root>: a root must sit at least two levels below
# "/", so "/", "/store" and "/home" can never be a root.
fm_task_output_root_ok() {
  case "$1" in
    /*/*) return 0 ;;
  esac
  return 1
}

# fm_task_output_roots <data>: one "literal|real" line per usable root.
fm_task_output_roots() {
  local root real
  for root in "$FM_TASK_OUTPUT_STORE_ROOT" "${1%/}"; do
    [ "$root" = "${1%/}" ] || [ ! -L "$root" ] || continue
    real=$(fm_task_output_real "$root") || continue
    fm_task_output_root_ok "$real" || continue
    printf '%s|%s\n' "$root" "$real"
  done
}

# fm_task_output_home_key <data>: a short key distinct per firstmate home.
fm_task_output_home_key() {
  printf 'home-%s' "$(printf '%s' "${1%/}" | cksum | awk '{print $1}')"
}

# fm_task_output_dir <data> <task-id>: the task's output folder. The store is
# used only when this home's folder in it already exists as a real, writable
# directory; the owner creates it once per home. Returns 1 when the task folder
# is a symlink.
fm_task_output_dir() {
  local home="$FM_TASK_OUTPUT_STORE_ROOT/$(fm_task_output_home_key "$1")"
  if [ -d "$FM_TASK_OUTPUT_STORE_ROOT" ] && [ ! -L "$FM_TASK_OUTPUT_STORE_ROOT" ] \
    && [ -d "$home" ] && [ ! -L "$home" ] && [ -w "$home" ]; then
    [ ! -L "$home/$2" ] || return 1
    printf '%s/%s' "$home" "$2"
  else
    printf '%s/%s' "${1%/}" "$2"
  fi
}

# fm_task_output_prepare <dir>: create <dir>/build and <dir>/proof as real
# directories. Returns 1 when either cannot be made or is a symlink.
fm_task_output_prepare() {
  local dir=$1 part
  fm_task_output_normalized "$dir" || return 1
  mkdir -p -- "$dir/build" "$dir/proof" 2>/dev/null || return 1
  for part in "$dir" "$dir/build" "$dir/proof"; do
    [ -d "$part" ] && [ ! -L "$part" ] && [ -w "$part" ] || return 1
  done
}

# fm_task_output_overlaps <a> <b>: equal, or one is inside the other.
fm_task_output_overlaps() {
  case "$1/" in "$2"/*) return 0 ;; esac
  case "$2/" in "$1"/*) return 0 ;; esac
  return 1
}

# fm_task_output_other_record <state> <task-id> <candidate>: print
# the id of another live task whose recorded folders overlap <candidate>.
fm_task_output_other_record() {
  local state=$1 task=$2 cand=$3 meta other line path real
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    other=${meta##*/}
    other=${other%.meta}
    [ "$other" != "$task" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        output_build=*|output_proof=*) path=${line#*=} ;;
        *) continue ;;
      esac
      [ -n "$path" ] || continue
      path=${path%/}
      real=$(fm_task_output_real "$path") || real=$path
      if fm_task_output_overlaps "$cand" "$path" || fm_task_output_overlaps "$cand" "$real"; then
        printf '%s' "$other"
        return 0
      fi
    done < "$meta"
  done
  return 1
}

# fm_task_output_held <real-dir>: 0 when a process holds anything inside it or
# the holders cannot be listed (the safe answer), 1 when nothing does.
fm_task_output_held() {
  local dir=$1 out line rc=0
  command -v lsof >/dev/null 2>&1 || return 0
  out=$(lsof -w -F n 2>/dev/null) || rc=$?
  [ "$rc" -le 1 ] && [ -n "$out" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      n"$dir"|n"$dir"/*) return 0 ;;
    esac
  done <<EOF
$out
EOF
  return 1
}

# fm_task_output_remove <real-dir>: delete without following symlinks.
fm_task_output_remove() {
  local dir=$1 flag=
  if rm --version 2>/dev/null | grep -q GNU; then flag=--one-file-system; fi
  rm -rf ${flag:+"$flag"} -- "$dir" 2>/dev/null && return 0
  # A tool can leave a read-only tree (a Go module cache, for one); make it
  # writable without following symlinks, then try once more.
  chmod -R u+w -- "$dir" 2>/dev/null || true
  rm -rf ${flag:+"$flag"} -- "$dir" 2>/dev/null
}

# fm_task_output_reclaim <delete|list> <task-id> <state> <data> <build> [<proof>]
fm_task_output_reclaim() {
  local mode=$1 task=$2 state=$3 data=$4 build=$5 proof=${6:-}
  local real roots entry rl rr rel lit_real holder kb after root_real=
  [ -n "$build" ] || return 0
  if ! fm_task_output_normalized "$build"; then
    printf 'kept\tnot a normalized absolute path\t%s\n' "$build"; return 0
  fi
  if [ -L "$build" ]; then
    printf 'kept\tthe recorded path is a symlink\t%s\n' "$build"; return 0
  fi
  [ -e "$build" ] || return 0
  if [ ! -d "$build" ]; then
    printf 'kept\tnot a directory\t%s\n' "$build"; return 0
  fi
  real=$(fm_task_output_real "$build") || {
    printf 'kept\tcannot be resolved\t%s\n' "$build"; return 0
  }
  roots=$(fm_task_output_roots "$data")
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rl=${entry%%|*}
    rr=${entry#*|}
    case "$real" in "$rr"/*) ;; *) continue ;; esac
    rel=${real#"$rr"/}
    case "$rel" in */?*) ;; *) continue ;; esac   # two levels below the root
    # The text of the path must lead to the same place it names.
    if [ "$build" = "$real" ]; then
      root_real=$rr
    else
      case "$build" in "$rl"/*) ;; *) continue ;; esac
      lit_real="$rr/${build#"$rl"/}"
      [ "$lit_real" = "$real" ] || continue
      root_real=$rr
    fi
    break
  done <<EOF
$roots
EOF
  if [ -z "$root_real" ]; then
    printf 'kept\toutside the output roots or fewer than two levels deep\t%s\n' "$build"; return 0
  fi
  if holder=$(fm_task_output_other_record "$state" "$task" "$real"); then
    printf 'kept\trecorded by live task %s\t%s\n' "$holder" "$build"; return 0
  fi
  if [ -n "$proof" ] && fm_task_output_overlaps "$real" "${proof%/}"; then
    printf 'kept\toverlaps the task proof folder\t%s\n' "$build"; return 0
  fi
  if fm_task_output_held "$real"; then
    printf 'kept\theld by a running process, or holders could not be listed\t%s\n' "$build"; return 0
  fi
  kb=$(fm_task_output_size_kb "$real")
  if [ "$mode" != delete ]; then
    printf 'would-free\t%s\t%s\n' "$kb" "$build"; return 0
  fi
  if fm_task_output_remove "$real" && [ ! -e "$real" ]; then
    printf 'freed\t%s\t%s\n' "$kb" "$build"; return 0
  fi
  after=$(fm_task_output_size_kb "$real")
  [ "$after" -lt "$kb" ] || after=$kb
  [ "$kb" -eq "$after" ] || printf 'freed\t%s\t%s\n' "$((kb - after))" "$build"
  printf 'kept\tcould not be fully removed\t%s\n' "$build"
}

# fm_task_output_record_leftover <data> <task-id> <build>...: record the folders
# a finished task left behind, atomically. The record keeps every folder it
# already named that is still on disk (an earlier task that used this id) plus
# the given ones; with none left, the record is removed.
fm_task_output_record_leftover() {
  local data=$1 task=$2 file tmp build body= seen=$'\n' old
  shift 2
  file="$data/$task/output.record"
  old=()
  [ ! -f "$file" ] || mapfile -t old < <(sed -n 's/^output_build=//p' "$file")
  for build in "$@" ${old[@]+"${old[@]}"}; do
    [ -e "$build" ] || [ -L "$build" ] || continue
    case "$seen" in *$'\n'"$build"$'\n'*) continue ;; esac
    seen="$seen$build"$'\n'
    body="$body$(printf 'output_build=%s\n.' "$build")"
  done
  body=${body//$'\n.'/$'\n'}
  if [ -z "$body" ]; then
    rm -f -- "$file" 2>/dev/null || true
    return 0
  fi
  mkdir -p -- "$data/$task" 2>/dev/null || return 1
  tmp="$file.tmp.$$"
  if ! printf '%s' "$body" > "$tmp" || ! printf '%s' "$body" | cmp -s - "$tmp" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp" 2>/dev/null
    return 1
  fi
}

# fm_task_output_teardown <task-id> <state> <data> <build> <proof>: the
# teardown step. Deletes the recorded build folder under the guard, prints one
# "freed" or "kept" line per folder, lists a non-empty proof folder as kept, and
# leaves <data>/<id>/output.record for any build folder still on disk so
# bin/fm-output-sweep.sh can retry it. Returns 1 only when a build folder is
# still on disk and its record could not be written; the caller then keeps the
# task record, so the leftover stays recoverable.
fm_task_output_teardown() {
  local task=$1 state=$2 data=$3 build=$4 proof=$5 kind a b
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      freed) printf 'teardown %s output freed %s: %s\n' "$task" "$(fm_task_output_human "$a")" "$b" ;;
      kept) printf 'teardown %s output kept (%s): %s\n' "$task" "$a" "$b" ;;
    esac
  done < <(fm_task_output_reclaim delete "$task" "$state" "$data" "$build" "$proof")
  if [ -n "$proof" ] && [ -d "$proof" ] && [ ! -L "$proof" ] && [ -n "$(ls -A -- "$proof" 2>/dev/null)" ]; then
    printf 'teardown %s output kept (proof folder, files a PR cites): %s (%s)\n' \
      "$task" "$proof" "$(fm_task_output_human "$(fm_task_output_size_kb "$proof")")"
  fi
  fm_task_output_record_leftover "$data" "$task" "$build"
}
