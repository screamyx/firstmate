#!/usr/bin/env bash
# fm-supervision-host-repeat-lib.sh - sourced by bin/fm-supervision-host.sh. The
# repeat idle alert skip (docs/supervision-host.md "Repeat idle alerts"): a
# claim made only of bare "stale: <pane>" rows for workers whose last outcome
# is already recorded for a stale wake at the status file's present position,
# whatever the status (bin/fm-outcome-index-lib.sh fm_idle_repeat_recorded), is settled
# without an engine turn.
#
# Needs from the host: SCRIPT_DIR, STATE, GEN, log_line, and the grant already
# published for the claimed rows.
#
# fm_host_repeat_settle <rows> <tasks> <unscoped> <wake-line> returns 0 only
# after it has consumed every claimed row through the branch drain (without presenting
# status) and acknowledgement the engine would have run, and logged one skip line. Anything
# short of that returns 1 with nothing acknowledged, and the caller runs the
# turn as before. Decorated stale reasons (wedge escalations, unread
# instructions, dialogs, dead agents) are never skipped.

fm_host_repeat_claim_is_bare_stale() {  # <rows>
  local rows=$1
  [ -n "$rows" ] || return 1
  [ -f "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' -v rows="$rows" '
    BEGIN { n = split(rows, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
    NF >= 5 && ($2 in want) { seen++; if ($3 != "stale" || $5 !~ /^stale: [^ ]+$/) bad = 1 }
    END { exit !(seen == n && !bad) }
  ' "$FM_WAKE_QUEUE" 2>/dev/null
}

fm_host_repeat_settle() {  # <rows> <tasks> <unscoped> <wake-line>
  local rows=$1 tasks=$2 unscoped=$3 wake=$4 task drain ack left
  [ "$unscoped" != 1 ] && [ -n "$tasks" ] || return 1
  fm_host_repeat_claim_is_bare_stale "$rows" || return 1
  for task in $tasks; do
    fm_idle_repeat_recorded "$task" || return 1
  done
  drain=$(FM_WAKE_DRAIN_SETTLE_ONLY=1 FM_SUPERVISION_ACTOR=branch "$SCRIPT_DIR/fm-wake-drain.sh" 2>&1) || return 1
  ack=$(printf '%s\n' "$drain" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  [ -n "$ack" ] || return 1
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  FM_SUPERVISION_ACTOR=branch "$SCRIPT_DIR/fm-wake-drain.sh" $ack >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2086 # rows is a space-separated list of sequence numbers.
  left=$(fm_wake_rows_queued $rows) || return 1
  [ -z "$left" ] || return 1
  log_line "skipped-repeat	$wake	$tasks	no engine turn: the status is unchanged since the outcome already recorded"
}
