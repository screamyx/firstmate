#!/usr/bin/env bash
# tests/fm-ps-width.test.sh - process identity reads survive a tiny display size.
#
# Claude Code runs Stop hooks with a 4x2 display size, and procps cuts every
# variable-width ps column to the ambient width unless the read asks for
# unlimited width: `ps -o comm=` reads "clau" and `ps -o args=` reads "/hom" for
# a live claude process. Each case runs a real process and asks the public
# entry point that owns one identity, harness, or liveness verdict about it with
# COLUMNS=4 LINES=2, then asserts the verdict a wide shell would reach.
# The end-to-end Stop auto-arm case lives in tests/fm-session-lock-ancestry.test.sh
# and the tmux pane classifier case in tests/fm-tmux-agent-liveness.test.sh.
# shellcheck disable=SC2016 # single quotes are deliberate: the fixture child expands its own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ps-width)

# A long-running stand-in whose executable name is a harness name. The target is
# bash rather than sleep, because a multicall coreutils sleep dispatches on its
# argv[0] and would exit at once under a harness name.
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/install/claude"
ln -s "$(command -v bash)" "$TMP_ROOT/bin/claude"
ln -s "$(command -v bash)" "$TMP_ROOT/bin/node"
printf '%s\n' 'sleep 300' ':' > "$TMP_ROOT/install/claude/cli.js"

PIDS=()
cleanup_pids() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_pids' EXIT

start() {  # <cmd...> - start a background process and print its pid
  "$@" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

CLAUDE_PID=$(start "$TMP_ROOT/bin/claude" -c 'sleep 300; :')
PIDS+=("$CLAUDE_PID")
NODE_PID=$(start "$TMP_ROOT/bin/node" "$TMP_ROOT/install/claude/cli.js")
PIDS+=("$NODE_PID")
sleep 0.2
kill -0 "$CLAUDE_PID" 2>/dev/null || fail "the claude stand-in did not stay alive"
kill -0 "$NODE_PID" 2>/dev/null || fail "the node stand-in did not stay alive"

# The width really is the hazard on this host: an unpinned read is cut short, so
# no case below can pass vacuously.
assert_width_cuts_unpinned_reads() {
  local comm
  comm=$(COLUMNS=4 LINES=2 ps -o comm= -p "$CLAUDE_PID" 2>/dev/null | tr -d '[:space:]')
  case "$comm" in
    *claude*) fail "this host's ps does not cut comm under COLUMNS=4 (got '$comm'), so the cases below would prove nothing" ;;
  esac
  pass "ps width: an unpinned comm read is cut short under a 4x2 width on this host"
}

test_harness_ancestry_names_claude_by_comm() {
  local got
  got=$(COLUMNS=4 LINES=2 "$ROOT/bin/fm-harness.sh" ancestry "$CLAUDE_PID" 2>/dev/null)
  [ "$got" = "comm claude" ] || fail "fm-harness.sh ancestry under a 4x2 width: expected 'comm claude', got '$got'"
  pass "ps width: harness ancestry names a claude process by its executable under a 4x2 width"
}

test_harness_ancestry_names_claude_by_interpreter_args() {
  local got
  got=$(COLUMNS=4 LINES=2 "$ROOT/bin/fm-harness.sh" ancestry "$NODE_PID" 2>/dev/null)
  [ "$got" = "args claude" ] || fail "fm-harness.sh ancestry under a 4x2 width: expected 'args claude', got '$got'"
  pass "ps width: harness ancestry names an interpreter-run claude by its script path under a 4x2 width"
}

test_session_lock_sees_a_live_harness() {
  COLUMNS=4 LINES=2 bash -c '. "$1"; fm_harness_pid_alive "$2"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$CLAUDE_PID" \
    || fail "fm_harness_pid_alive read a live claude process as not a harness under a 4x2 width"
  pass "ps width: the session lock recognises a live harness owner under a 4x2 width"
}

test_session_lock_ancestry_finds_the_harness() {
  local out
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID COLUMNS=4 LINES=2 \
    "$TMP_ROOT/bin/claude" -c 'echo "$$"; bash -c ". \"\$1\"; fm_harness_ancestry_pids" _ "$1"; :' _ "$ROOT/bin/fm-session-lock-lib.sh")
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "$(printf '%s\n' "$out" | sed -n 1p)" ] \
    || fail "fm_harness_ancestry_pids under a 4x2 width did not start at the claude parent: $(printf '%s' "$out" | tr '\n' ' ')"
  pass "ps width: the session-lock ancestry walk finds its harness parent under a 4x2 width"
}

test_pid_identities_are_width_invariant() {
  local fn lib narrow wide
  for fn in fm_pid_identity fm_pending_reply_pid_identity; do
    lib=$ROOT/bin/fm-wake-lib.sh
    [ "$fn" = fm_pid_identity ] || lib=$ROOT/bin/fm-pending-reply-lib.sh
    narrow=$(COLUMNS=4 LINES=2 FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" bash -c '. "$1"; "$2" "$3"' _ "$lib" "$fn" "$NODE_PID" 2>/dev/null)
    wide=$(COLUMNS=1000 FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" bash -c '. "$1"; "$2" "$3"' _ "$lib" "$fn" "$NODE_PID" 2>/dev/null)
    case "$wide" in
      *"install/claude/cli.js"*) ;;
      *) fail "$fn dropped the full command under a wide width (got '$wide')" ;;
    esac
    [ "$narrow" = "$wide" ] || fail "$fn varied with width (narrow '$narrow', wide '$wide')"
  done
  pass "ps width: recorded process identities are byte-identical under a 4x2 width"
}

assert_width_cuts_unpinned_reads
test_harness_ancestry_names_claude_by_comm
test_harness_ancestry_names_claude_by_interpreter_args
test_session_lock_sees_a_live_harness
test_session_lock_ancestry_finds_the_harness
test_pid_identities_are_width_invariant
