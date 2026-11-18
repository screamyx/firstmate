#!/usr/bin/env bash
# Cases for a worker parked at an open question that its outcome already
# records (bin/fm-outcome-index-lib.sh, docs/supervision-host.md "Repeat idle
# alerts"). Sourced by tests/fm-supervision-host-hook.test.sh after
# tests/supervision-host-helpers.sh; each case drives the real watcher, host,
# wake grant, drain, and outcome store with the stub engine.

# The worker's pane is idle and its content changes every few seconds, as a
# real pane with a clock or counter does, so every change is a new stale hash.
parked_pane_churns() {  # <home>
  local home=$1
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-demo\n'; exit 0 ;;
  capture-pane) printf 'Pi idle prompt; waiting on the captain; tick %s\n' "$(( $(date +%s) / 3 ))"; exit 0 ;;
  display-message) printf 'node\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  printf 'window=firstmate:fm-demo\nproject=demo\nkind=ship\nharness=pi\nbackend=tmux\n' > "$home/state/demo.meta"
}

# A home with the away record, a live host session, and a worker whose first
# blocked line was handled by one engine turn. Sets PARKED_HOME (a command
# substitution would hold the background session's output open).
parked_question_home() {  # <name>
  local home
  home=$(make_primary_home "$1")
  PARKED_HOME=$home
  ln -s "$ROOT/.agents" "$home/.agents"
  FM_HOME="$home" "$CONTRACT" enter --words 'keep the worker moving' >/dev/null 2>&1 \
    || fail "$1: could not record away posture"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "$1: no watcher started"
  append_status "$home" 'which schema do you want' blocked
  wait_until 250 handled_at_least "$home" 1 || fail "$1: the blocked line was not handled"
}

test_parked_question_is_not_raised_again_while_its_status_is_unchanged() {
  local home
  parked_question_home parked-question
  home=$PARKED_HOME
  parked_pane_churns "$home"
  sleep 25
  [ "$(engine_calls "$home")" -eq 1 ] \
    || fail "parked question: an idle alert for an unchanged recorded question ran $(engine_calls "$home") engine turns: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'absorbed stale' "$home/state/.watch-triage.log" "parked question: the watcher never reached the stale path"
  append_status "$home" 'a different question' blocked
  wait_until 250 handled_at_least "$home" 2 || fail "parked question: a changed status did not get its turn"
  stop_home_processes "$home"
  pass "host+watch: an unchanged recorded question raises no further idle alert and a changed status still does"
}

# The host's settle step against a real queue, grant, drain, and outcome store:
# a claim of bare idle alerts for a question whose outcome is recorded at the
# status file's present position is consumed with no engine; anything else is
# left untouched for the turn.
# settle_case <name> <queued wake text> <status line after the outcome or ''>
# prints "<settle rc> <rows left> <skip lines logged>".
settle_case() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'window=firstmate:fm-demo\nproject=demo\nkind=ship\nharness=pi\nbackend=tmux\n' > "$home/state/demo.meta"
  append_status "$home" 'which schema do you want' blocked
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine \
    --summary 'still waiting on the captain' >/dev/null || fail "$1: could not record the outcome"
  [ -z "${3:-}" ] || append_status "$home" "$3" blocked
  FM_HOME="$home" FM_ROOT="$ROOT" WAKE_TEXT="$2" bash -c '
    SCRIPT_DIR=$FM_ROOT/bin
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    . "$SCRIPT_DIR/fm-outcome-index-lib.sh"
    . "$SCRIPT_DIR/fm-supervision-host-repeat-lib.sh"
    HOST_LOG=$STATE/.supervision-host.log
    log_line() { printf "%s\t%s\n" "$(date +%s)" "$1" >> "$HOST_LOG"; }
    GEN=gen1
    fm_wake_append stale firstmate:fm-demo "$WAKE_TEXT" || exit 9
    "$SCRIPT_DIR/fm-wake-grant.sh" activate "$$" "$GEN" || exit 9
    "$SCRIPT_DIR/fm-wake-grant.sh" publish "$GEN" 1 || exit 9
    fm_host_repeat_settle "1" "demo" 0 "stale: firstmate:fm-demo"
    rc=$?
    printf "%s %s %s\n" "$rc" "$(fm_wake_rows_queued 1 | wc -l | tr -d " ")" "$(cat "$HOST_LOG" 2>/dev/null | grep -c "skipped-repeat")"
  ' 2>/dev/null | tail -n 1
}

test_host_settles_a_bare_idle_alert_for_a_recorded_question() {
  [ "$(settle_case settle-bare 'stale: firstmate:fm-demo' '')" = "0 0 1" ] \
    || fail "settle: a bare idle alert for a recorded question was not consumed without a turn"
  pass "host: a bare idle alert for an already recorded question is consumed without an engine turn"
}

test_host_leaves_every_other_idle_alert_for_its_turn() {
  r=$(settle_case settle-newer "stale: firstmate:fm-demo" "a different question"); [ "$r" = "1 1 0" ] \
    || fail "settle: an alert after a newer status line must keep its turn (got: $r)"
  [ "$(settle_case settle-decorated 'stale: firstmate:fm-demo (idle 300s, possible wedge, escalation 1)' '')" = "1 1 0" ] \
    || fail "settle: a decorated idle alert must keep its turn"
  pass "host: an alert after a newer status line, or a decorated one, keeps its engine turn"
}
