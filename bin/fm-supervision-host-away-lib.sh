#!/usr/bin/env bash
# fm-supervision-host-away-lib.sh - sourced by bin/fm-supervision-host.sh. The
# away hand-back: while an away record exists, a finished engine turn that
# recorded a non-silent captain outcome wakes main once per distinct outcome, so main
# can pass it to the channel the away words name (docs/supervision-host.md
# "Away hand-back").
#
# Needs from the host: SCRIPT_DIR, STATE, RECEIPTS, HOST_LOG, log_line.
#
# fm_away_handback_prepare <turn> sets AWAY_HANDBACK_SEQS (store rows, comma
# separated), AWAY_HANDBACK_LINES (one "supervision-host:" line per row) and
# AWAY_HANDBACK_IDENTS (one "<task><TAB><keys><TAB><digest>" per row), and
# returns 0 only when at least one non-silent captain row has not been handed
# back already. The identity is the task, its open decision keys ("-" when it
# has none), and a digest of the outcome summary, so one question never wakes
# main twice while a newly opened decision, or a different outcome on the same
# task, does.
# A store lookup that fails counts as new: suppressing a question costs more
# than waking main twice.
#
# fm_away_handback_exit writes the ledger the check reads: one
# "away-handback<TAB>task<TAB>keys<TAB>digest" line per row in the host log
# (bin/fm-supervision-host.sh log_line), counted only from the current away
# record's entry on, so no state lives in the host's memory (the hand-back
# exits the host process), then exits to main.

fm_away_handback_seen() {  # <task> <keys> <digest>
  local since
  since=$(fm_afk_contract_read_field "$(fm_afk_contract_path "$STATE")" entered_epoch 2>/dev/null)
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  awk -F '\t' -v since="$since" -v task="$1" -v ident="$2" -v digest="$3" \
    '$1 >= since && $2 == "away-handback" && $3 == task && $4 == ident && $5 == digest { found = 1 } END { exit !found }' \
    "$HOST_LOG" 2>/dev/null
}

# The task's open decision keys now (bin/fm-classify-lib.sh status_open_decisions
# owns the fold), comma separated, or empty when it has none.
fm_away_handback_ident() {  # <task>
  status_open_decisions "$STATE/$1.status" 2>/dev/null | cut -f1 | sort | paste -sd, - | tr -d '\r'
}

fm_away_handback_prepare() {  # <turn>
  local seqs rows row task ident digest fresh_rows='' seq
  AWAY_HANDBACK_SEQS=
  AWAY_HANDBACK_LINES=
  AWAY_HANDBACK_IDENTS=
  [ -n "${1:-}" ] || return 1
  seqs=$(awk -F '\t' -v turn="$1" '$1 == turn && $3 == "captain" { printf "%s%s", sep, $2; sep = "," }' "$RECEIPTS" 2>/dev/null)
  [ -n "$seqs" ] || return 1
  if ! rows=$("$SCRIPT_DIR/fm-branch-outcome.sh" lookup --seqs "$seqs" 2>/dev/null) \
    || ! rows=$(printf '%s\n' "$rows" | jq -c 'select(.verdict == "captain" and .silent != true)' 2>/dev/null); then
    AWAY_HANDBACK_SEQS=$seqs
    AWAY_HANDBACK_LINES="supervision-host: outcome lookup failed for captain rows $seqs; main must review them"
    return 0
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    task=$(printf '%s' "$row" | jq -r '.task' | tr -d '\r\t\n')
    ident=$(fm_away_handback_ident "$task")
    ident=${ident:--}
    digest=$(printf '%s' "$row" | jq -r '.summary // ""' | tr -d '\r' | sha256sum | cut -c1-16)
    ! fm_away_handback_seen "$task" "$ident" "$digest" || continue
    seq=$(printf '%s' "$row" | jq -r '.seq')
    AWAY_HANDBACK_SEQS=${AWAY_HANDBACK_SEQS:+$AWAY_HANDBACK_SEQS, }$seq
    fresh_rows=${fresh_rows:+$fresh_rows$'\n'}$row
    AWAY_HANDBACK_IDENTS=${AWAY_HANDBACK_IDENTS:+$AWAY_HANDBACK_IDENTS$'\n'}$task$'\t'$ident$'\t'$digest
  done <<< "$rows"
  [ -n "$fresh_rows" ] || return 1
  AWAY_HANDBACK_LINES=$(printf '%s\n' "$fresh_rows" \
    | jq -r '"supervision-host: outcome \(.seq) for \(.task) [\(.verdict)]: \(.summary)"' | tr -d '\r')
}

# Exit to main without the close the engine handled, then park like a cycle
# boundary (bin/fm-supervision-host.sh boundary_exit): the handling episode is
# settled and the watcher stopped, which publishes downtime exactly as at a
# boundary, and main's drain acknowledges it before the owner's next host
# starts. Uses the host's own acknowledged_handback, emit, retire_successor,
# and ledger.
fm_away_handback_exit() {  # [further lines]
  local why="away-outcome: the supervision session handled this wake and recorded outcomes that need the captain (store rows $AWAY_HANDBACK_SEQS, listed next); drain and acknowledge as usual, then pass them to the channel the away words name, else leave them for the return"
  local task ident digest
  ARM_TEXT=
  while IFS=$'\t' read -r task ident digest; do
    [ -z "$task" ] || log_line "away-handback	$task	$ident	$digest"
  done <<< "$AWAY_HANDBACK_IDENTS"
  HANDBACK_DETAIL=$(printf '%s' "$AWAY_HANDBACK_LINES" | tr '\n\t\r' '   ' | sed 's/  */ /g')
  acknowledged_handback "supervision-host: $why" "$AWAY_HANDBACK_LINES" "${1:-}"
  fm_recovery_marker_handling_settled "$STATE/.watcher-down" || log_line "handling-settle-failed	away-handback"
  retire_successor
  log_line "to-main	$why"
  emit "supervision-host: $why" "$AWAY_HANDBACK_LINES" "${1:-}"
  exit 0
}
