#!/usr/bin/env bash
# fm-outcome-index-lib.sh - sourced by bin/fm-branch-outcome.sh (writer),
# bin/fm-wake-drain.sh, bin/fm-watch.sh, and bin/fm-supervision-host.sh. The
# one reader and capturer of the bounded per-task outcome index
# ($STATE/.<task>.branch-outcome-index, format owned by bin/fm-branch-outcome.sh).
#
# Needs: STATE, and bin/fm-classify-lib.sh sourced first.
#
# capture_status_position <task> sets CAPTURED_STATUS_ENDPOINT (the status
# file's size) and CAPTURED_STATUS_IDENT (its file identity), or 0 and "-" when
# the file is unreadable or changed while read. The identity alone is a file
# identity, not a content fingerprint, so a status position is the pair.
#
# fm_status_position_recorded <task> returns 0 only when the task's latest
# recorded outcome was captured at exactly the status file's present position
# (any status verb). fm_open_question_recorded <task> adds that the newest status
# line is an open needs-decision or blocked event. Any
# missing, unreadable, or unready piece returns 1, so the caller treats the
# question as new: a repeat alert or a paid turn costs less than a missed one.

BRANCH_OUTCOME_INDEX_VERSION=fm-branch-outcome-index-v1
BRANCH_OUTCOME_INDEX_MAX_BYTES=512
BRANCH_OUTCOME_INDEX_STATE=ok
BRANCH_OUTCOME_INDEX_ENDPOINT=
BRANCH_OUTCOME_INDEX_IDENT=
outcome_index_ready_ok() { # <ready-path>
  local seq
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || return 1
  seq=$(LC_ALL=C command cat "$1" 2>/dev/null) || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

load_branch_outcome_index() { # <task>
  local task=$1 path data version seq endpoint ident extra size
  BRANCH_OUTCOME_INDEX_STATE=ok
  BRANCH_OUTCOME_INDEX_ENDPOINT=
  BRANCH_OUTCOME_INDEX_IDENT=
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  path="$STATE/.$task.branch-outcome-index"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ ! -f "$path" ] || [ ! -r "$path" ] || [ -L "$path" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  size=$(_fm_status_file_size "$path") || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  if [ "$size" -gt "$BRANCH_OUTCOME_INDEX_MAX_BYTES" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) \
    || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  case "$data" in *$'\n'*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  IFS=$(printf '\t') read -r version seq endpoint ident extra <<EOF
$data
EOF
  if [ "$version" != "$BRANCH_OUTCOME_INDEX_VERSION" ] || [ -n "$extra" ]; then
    BRANCH_OUTCOME_INDEX_STATE=invalid
    return 0
  fi
  case "$seq:$endpoint" in *[!0-9:]*) BRANCH_OUTCOME_INDEX_STATE=invalid; return 0 ;; esac
  [ -n "$seq" ] && [ -n "$endpoint" ] && [ -n "$ident" ] \
    && [ "${#seq}" -le 16 ] && [ "${#endpoint}" -le 16 ] \
    && [ "$seq" -le 9007199254740991 ] && [ "$endpoint" -le 9007199254740991 ] \
    || { BRANCH_OUTCOME_INDEX_STATE=invalid; return 0; }
  BRANCH_OUTCOME_INDEX_ENDPOINT=$endpoint
  BRANCH_OUTCOME_INDEX_IDENT=$ident
}

capture_status_position() { # <task>
  local f="$STATE/$1.status" size ident size_after ident_after
  CAPTURED_STATUS_ENDPOINT=0
  CAPTURED_STATUS_IDENT=-
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  size=$(_fm_status_file_size "$f") || return 0
  size=${size//[[:space:]]/}
  ident=$(_fm_open_decisions_file_ident "$f") || return 0
  size_after=$(_fm_status_file_size "$f") || return 0
  size_after=${size_after//[[:space:]]/}
  ident_after=$(_fm_open_decisions_file_ident "$f") || return 0
  case "$size:$size_after" in *[!0-9:]*) return 0 ;; esac
  [ "$size" = "$size_after" ] && [ "$ident" = "$ident_after" ] || return 0
  case "$ident" in *$'\t'*|*$'\n'*|'') return 0 ;; esac
  CAPTURED_STATUS_ENDPOINT=$size
  CAPTURED_STATUS_IDENT=$ident
}

fm_status_position_recorded() {  # <task>
  local task=$1
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  outcome_index_ready_ok "$STATE/.branch-outcome-index-ready" || return 1
  load_branch_outcome_index "$task"
  [ "$BRANCH_OUTCOME_INDEX_STATE" = ok ] && [ -n "$BRANCH_OUTCOME_INDEX_ENDPOINT" ] || return 1
  [ "$BRANCH_OUTCOME_INDEX_ENDPOINT" -gt 0 ] && [ "$BRANCH_OUTCOME_INDEX_IDENT" != - ] || return 1
  capture_status_position "$task"
  [ "$CAPTURED_STATUS_ENDPOINT" = "$BRANCH_OUTCOME_INDEX_ENDPOINT" ] \
    && [ "$CAPTURED_STATUS_IDENT" = "$BRANCH_OUTCOME_INDEX_IDENT" ]
}

fm_open_question_recorded() {  # <task>
  local task=$1 line verb
  line=$(last_status_line "$STATE/$task.status") || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in needs-decision|blocked) ;; *) return 1 ;; esac
  fm_status_position_recorded "$task"
}
