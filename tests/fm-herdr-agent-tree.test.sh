#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-agent-tree.sh and the Agent Tree pane tags
# (docs/herdr-backend.md "Agent Tree pane tags"): exact report-metadata call
# shapes with no TTL, at_agb omission, the coordinator clear-then-set on a
# changed pane, the pane-id-reuse guard, and failures that never surface.
# A stateful fake herdr keeps per-pane tokens so every assertion reads the
# resulting pane state as well as the exact argv sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-agent-tree)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

TREE="$ROOT/bin/fm-herdr-agent-tree.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
# Fake herdr: logs each call's argv tab-separated, and keeps each pane's tokens
# in $FM_FAKE_HERDR_PANES/<session>/<pane>.json. A pane exists iff its file does.
# FM_FAKE_HERDR_FAIL fails every report, FM_FAKE_HERDR_FAIL_MATCH fails only a
# report whose argv contains it, FM_FAKE_HERDR_HANG makes every report hang
# (recording its pid), and FM_FAKE_HERDR_GET_FAIL makes `pane get` of that
# pane answer with an unreadable transport error.
set -u
(IFS=$'\t'; printf '%s\n' "$*") >> "$FM_FAKE_HERDR_LOG"
args=("$@")
session=
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = --session ] && session=${args[$((i + 1))]:-}
done
pane=${3:-}
file="$FM_FAKE_HERDR_PANES/$session/$pane.json"
case "${1:-} ${2:-}" in
  "pane get")
    [ "$pane" != "${FM_FAKE_HERDR_GET_FAIL:-}" ] || { printf 'fake herdr: socket closed\n' >&2; exit 2; }
    [ -f "$file" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    jq -c --arg p "$pane" '{result: {pane: {pane_id: $p, tokens: .}}}' "$file"
    ;;
  "pane report-metadata")
    if [ -n "${FM_FAKE_HERDR_HANG:-}" ]; then
      printf '%s\n' "$$" >> "$FM_FAKE_HERDR_HANG"
      sleep 30
    fi
    case "$*" in *"${FM_FAKE_HERDR_FAIL_MATCH:-\x01never}"*) printf 'fake herdr: refused\n' >&2; exit 7 ;; esac
    if [ -n "${FM_FAKE_HERDR_FAIL:-}" ]; then
      printf 'fake herdr stdout noise\n'
      printf 'fake herdr: server unreachable\n' >&2
      exit 7
    fi
    [ -f "$file" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    tokens=$(cat "$file")
    for ((i = 3; i < ${#args[@]}; i++)); do
      case "${args[$i]}" in
        --token) kv=${args[$((i + 1))]}; tokens=$(printf '%s' "$tokens" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v') ;;
        --clear-token) tokens=$(printf '%s' "$tokens" | jq -c --arg k "${args[$((i + 1))]}" 'del(.[$k])') ;;
      esac
    done
    printf '%s\n' "$tokens" > "$file"
    printf '{"result":{"type":"ok"}}\n'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# new_case <name>: a fresh home, call log, and pane store; sets HOME_DIR, LOG,
# PANES, and HASH (the home's own hash, from the agb identity owner).
new_case() {
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  LOG="$dir/herdr.log"
  PANES="$dir/panes"
  mkdir -p "$HOME_DIR/state" "$PANES"
  : > "$LOG"
  HASH=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-agb.sh" home-hash)
  [ "${#HASH}" -eq 6 ] || fail "$1: home hash was not six characters: '$HASH'"
}

add_pane() {  # <session> <pane> [tokens-json]
  local tokens=${3:-}
  [ -n "$tokens" ] || tokens='{}'
  mkdir -p "$PANES/$1"
  printf '%s\n' "$tokens" > "$PANES/$1/$2.json"
}

pane_tokens() {  # <session> <pane>
  jq -cS . "$PANES/$1/$2.json"
}

run_tree() {  # <pane-id|""> <session|""> <args...>
  local pane=$1 session=$2
  shift 2
  env -u HERDR_PANE_ID -u HERDR_SESSION -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE \
    ${pane:+HERDR_PANE_ID="$pane"} ${session:+HERDR_SESSION="$session"} \
    FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_LOG="$LOG" FM_FAKE_HERDR_PANES="$PANES" \
    bash "$TREE" "$@"
}

report_calls() { grep $'^pane\treport-metadata' "$LOG" || true; }

test_coordinator_first_start_tags_own_pane_and_records_it() {
  local out
  new_case coord-first
  add_pane lab w1:p1
  out=$(run_tree w1:p1 lab coordinator 2>&1)
  assert_equals "" "$out" "the coordinator tag must print nothing"
  assert_equals $'pane\treport-metadata\tw1:p1\t--source\tfirstmate\t--token\tat_home_owner='"$HASH"$'\t--session\tlab' \
    "$(report_calls)" "the coordinator tag call shape"
  assert_equals "{\"at_home_owner\":\"$HASH\"}" "$(pane_tokens lab w1:p1)" "the coordinator pane token"
  assert_equals "lab:w1:p1" "$(cat "$HOME_DIR/state/.herdr-agent-tree-owner")" "the recorded owner pane"
  assert_no_grep "--ttl-ms" "$LOG" "no Agent Tree tag may carry a TTL"
  pass "a locked session start tags its own pane with this home's hash and records it"
}

test_coordinator_default_session_when_unset() {
  new_case coord-default
  add_pane default w2:p3
  run_tree w2:p3 "" coordinator >/dev/null 2>&1
  assert_equals "{\"at_home_owner\":\"$HASH\"}" "$(pane_tokens default w2:p3)" "the default-session coordinator token"
  assert_equals "default:w2:p3" "$(cat "$HOME_DIR/state/.herdr-agent-tree-owner")" "the default-session owner record"
  pass "a coordinator with no HERDR_SESSION tags its pane in herdr's default session"
}

test_coordinator_clears_its_previous_pane_before_setting_the_new_one() {
  local calls
  new_case coord-move
  add_pane lab w1:p1 "{\"at_home_owner\":\"$HASH\",\"keep\":\"x\"}"
  add_pane lab w4:p2
  printf 'lab:w1:p1\n' > "$HOME_DIR/state/.herdr-agent-tree-owner"
  run_tree w4:p2 lab coordinator >/dev/null 2>&1
  calls=$(report_calls)
  assert_equals $'pane\treport-metadata\tw1:p1\t--source\tfirstmate\t--clear-token\tat_home_owner\t--session\tlab\npane\treport-metadata\tw4:p2\t--source\tfirstmate\t--token\tat_home_owner='"$HASH"$'\t--session\tlab' \
    "$calls" "the clear on the old pane must precede the set on the new one"
  assert_equals '{"keep":"x"}' "$(pane_tokens lab w1:p1)" "only at_home_owner is cleared on the old pane"
  assert_equals "{\"at_home_owner\":\"$HASH\"}" "$(pane_tokens lab w4:p2)" "the new coordinator pane token"
  assert_equals "lab:w4:p2" "$(cat "$HOME_DIR/state/.herdr-agent-tree-owner")" "the owner record follows the new pane"
  pass "a restarted coordinator on a new pane clears at_home_owner on its old live pane first"
}

test_coordinator_never_clears_a_reused_pane_id_owned_by_another_home() {
  new_case coord-reuse
  add_pane lab w1:p1 '{"at_home_owner":"zzz999"}'
  add_pane lab w4:p2
  printf 'lab:w1:p1\n' > "$HOME_DIR/state/.herdr-agent-tree-owner"
  run_tree w4:p2 lab coordinator >/dev/null 2>&1
  assert_no_grep "--clear-token" "$LOG" "a pane now owned by another home must not be cleared"
  assert_equals '{"at_home_owner":"zzz999"}' "$(pane_tokens lab w1:p1)" "the other home's coordinator tag"
  pass "a recorded pane id that now carries another home's tag is left alone"
}

test_coordinator_skips_a_gone_previous_pane() {
  new_case coord-gone
  add_pane lab w4:p2
  printf 'lab:w1:p1\n' > "$HOME_DIR/state/.herdr-agent-tree-owner"
  run_tree w4:p2 lab coordinator >/dev/null 2>&1
  assert_no_grep "--clear-token" "$LOG" "a gone previous pane needs no clear"
  assert_equals "{\"at_home_owner\":\"$HASH\"}" "$(pane_tokens lab w4:p2)" "the new coordinator pane token"
  pass "a previous coordinator pane that is gone is skipped and the new pane is tagged"
}

test_coordinator_rerun_on_the_same_pane_only_resets_the_tag() {
  new_case coord-same
  add_pane lab w1:p1
  run_tree w1:p1 lab coordinator >/dev/null 2>&1
  run_tree w1:p1 lab coordinator >/dev/null 2>&1
  assert_no_grep "--clear-token" "$LOG" "a rerun on the same pane must not clear its own tag"
  assert_equals 2 "$(report_calls | grep -c at_home_owner=)" "each start re-reports the tag"
  assert_equals "{\"at_home_owner\":\"$HASH\"}" "$(pane_tokens lab w1:p1)" "the coordinator pane token after a rerun"
  pass "a re-emit or rename rerun on the same pane re-reports the same tag without clearing it"
}

test_coordinator_without_a_herdr_pane_is_a_no_op() {
  new_case coord-none
  run_tree "" lab coordinator >/dev/null 2>&1
  assert_equals "" "$(cat "$LOG")" "no herdr call without HERDR_PANE_ID"
  assert_absent "$HOME_DIR/state/.herdr-agent-tree-owner" "no owner record without HERDR_PANE_ID"
  pass "a session outside herdr makes no herdr call and records nothing"
}

test_child_carries_home_and_agb_tokens() {
  new_case child-agb
  add_pane lab w3:p7
  run_tree "" "" child lab:w3:p7 "fm-$HASH-task-a" >/dev/null 2>&1
  assert_equals $'pane\treport-metadata\tw3:p7\t--source\tfirstmate\t--token\tat_home='"$HASH"$'\t--token\tat_agb=fm-'"$HASH"$'-task-a\t--session\tlab' \
    "$(report_calls)" "the adopted-worker tag call shape"
  assert_equals "{\"at_agb\":\"fm-$HASH-task-a\",\"at_home\":\"$HASH\"}" "$(pane_tokens lab w3:p7)" "the adopted-worker tokens"
  assert_no_grep "--ttl-ms" "$LOG" "no Agent Tree tag may carry a TTL"
  pass "an adopted worker pane is re-tagged with this home's hash and its agb id"
}

test_child_without_an_agb_id_clears_a_stale_at_agb() {
  new_case child-plain
  add_pane lab w3:p8 '{"at_agb":"fm-old-home-old-task","at_home":"old000"}'
  run_tree "" "" child lab:w3:p8 >/dev/null 2>&1
  assert_equals $'pane\treport-metadata\tw3:p8\t--source\tfirstmate\t--token\tat_home='"$HASH"$'\t--clear-token\tat_agb\t--session\tlab' \
    "$(report_calls)" "a worker with no agb id sets at_home and clears at_agb in one report"
  assert_equals "{\"at_home\":\"$HASH\"}" "$(pane_tokens lab w3:p8)" "a reused pane must not keep an earlier occupant's at_agb"
  pass "a worker with no agb id carries no at_agb, even on a pane that held one before"
}

test_a_hanging_report_is_bounded_and_kills_its_process() {
  local hang_pids out status=0 started elapsed pid
  new_case hang
  add_pane lab w5:p1
  hang_pids="$TMP_ROOT/hang/pids"
  : > "$hang_pids"
  started=$(date +%s)
  out=$(FM_FAKE_HERDR_HANG="$hang_pids" FM_HERDR_AGENT_TREE_TIMEOUT=1 run_tree "" "" child lab:w5:p1 fm-x 2>&1) || status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$status" "a worker tag whose report hangs"
  assert_equals "" "$out" "a hanging worker tag must print nothing"
  [ "$elapsed" -le 5 ] || fail "a hanging worker tag took ${elapsed}s against a 1s budget"
  [ -s "$hang_pids" ] || fail "the hang fixture never reached report-metadata"
  sleep 1
  while IFS= read -r pid; do
    ! kill -0 "$pid" 2>/dev/null || fail "the hung report process $pid outlived the bound"
  done < "$hang_pids"
  status=0
  started=$(date +%s)
  FM_FAKE_HERDR_HANG="$hang_pids" FM_HERDR_AGENT_TREE_TIMEOUT=1 run_tree w5:p1 lab coordinator >/dev/null 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$status" "a coordinator tag whose report hangs"
  [ "$elapsed" -le 5 ] || fail "a hanging coordinator tag took ${elapsed}s against a 1s budget"
  pass "a hanging report returns success within the tag budget and its process group is killed"
}

test_coordinator_retries_an_old_pane_whose_clear_failed() {
  new_case coord-clear-retry
  add_pane lab w1:p1 "{\"at_home_owner\":\"$HASH\"}"
  add_pane lab w2:p2
  printf 'lab:w1:p1\n' > "$HOME_DIR/state/.herdr-agent-tree-owner"
  FM_FAKE_HERDR_FAIL_MATCH=--clear-token run_tree w2:p2 lab coordinator >/dev/null 2>&1
  assert_equals "{\"at_home_owner\":\"$HASH\"}" "$(pane_tokens lab w2:p2)" "a failed old clear must not stop the new pane's tag"
  assert_equals $'lab:w2:p2\nlab:w1:p1' "$(cat "$HOME_DIR/state/.herdr-agent-tree-owner")" "an unconfirmed old pane must stay recorded"
  run_tree w2:p2 lab coordinator >/dev/null 2>&1
  assert_equals '{}' "$(pane_tokens lab w1:p1)" "the healthy rerun must clear the old owner tag"
  assert_equals "lab:w2:p2" "$(cat "$HOME_DIR/state/.herdr-agent-tree-owner")" "the record drops the old pane once its clear succeeds"
  pass "a failed old-pane clear is retried by the next start until it succeeds"
}

test_coordinator_retries_an_old_pane_whose_read_failed() {
  new_case coord-read-retry
  add_pane lab w1:p1 "{\"at_home_owner\":\"$HASH\"}"
  add_pane lab w2:p2
  printf 'lab:w1:p1\n' > "$HOME_DIR/state/.herdr-agent-tree-owner"
  FM_FAKE_HERDR_GET_FAIL=w1:p1 run_tree w2:p2 lab coordinator >/dev/null 2>&1
  assert_no_grep "--clear-token" "$LOG" "an unreadable old pane must not be cleared blind"
  assert_equals $'lab:w2:p2\nlab:w1:p1' "$(cat "$HOME_DIR/state/.herdr-agent-tree-owner")" "an unreadable old pane must stay recorded"
  run_tree w2:p2 lab coordinator >/dev/null 2>&1
  assert_equals '{}' "$(pane_tokens lab w1:p1)" "the healthy rerun must clear the old owner tag"
  assert_equals "lab:w2:p2" "$(cat "$HOME_DIR/state/.herdr-agent-tree-owner")" "the record drops the old pane once it is cleared"
  pass "an unreadable old pane is kept and cleared by the next healthy start"
}

test_herdr_failures_never_surface() {
  local out status=0
  new_case failures
  add_pane lab w1:p1
  out=$(FM_FAKE_HERDR_FAIL=1 run_tree w1:p1 lab coordinator 2>&1) || status=$?
  expect_code 0 "$status" "a failing coordinator tag"
  assert_equals "" "$out" "a failing coordinator tag must print nothing"
  status=0
  out=$(FM_FAKE_HERDR_FAIL=1 run_tree "" "" child lab:w1:p1 fm-x 2>&1) || status=$?
  expect_code 0 "$status" "a failing worker tag"
  assert_equals "" "$out" "a failing worker tag must print nothing"
  status=0
  out=$(run_tree "" "" child lab:w9:p9 2>&1) || status=$?
  expect_code 0 "$status" "a worker tag on a missing pane"
  assert_equals "" "$out" "a worker tag on a missing pane must print nothing"
  status=0
  out=$(env -u HERDR_PANE_ID HERDR_PANE_ID=w1:p1 FM_HOME="$HOME_DIR" PATH="$TMP_ROOT/no-such-dir:/usr/bin:/bin" bash "$TREE" coordinator 2>&1) || status=$?
  expect_code 0 "$status" "a coordinator tag with no herdr installed"
  assert_equals "" "$out" "a coordinator tag with no herdr installed must print nothing"
  pass "herdr errors, missing panes, and a missing herdr binary exit 0 and print nothing"
}

test_coordinator_first_start_tags_own_pane_and_records_it
test_coordinator_default_session_when_unset
test_coordinator_clears_its_previous_pane_before_setting_the_new_one
test_coordinator_never_clears_a_reused_pane_id_owned_by_another_home
test_coordinator_skips_a_gone_previous_pane
test_coordinator_rerun_on_the_same_pane_only_resets_the_tag
test_coordinator_without_a_herdr_pane_is_a_no_op
test_child_carries_home_and_agb_tokens
test_child_without_an_agb_id_clears_a_stale_at_agb
test_a_hanging_report_is_bounded_and_kills_its_process
test_coordinator_retries_an_old_pane_whose_clear_failed
test_coordinator_retries_an_old_pane_whose_read_failed
test_herdr_failures_never_surface
