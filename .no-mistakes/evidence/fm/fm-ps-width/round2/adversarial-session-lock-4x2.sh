#!/usr/bin/env bash
# Adversarial check: unlimited-width reads must not make a non-harness or dead
# lock owner look like a live harness under the 4x2 Stop-hook width.
# Real processes: a claude stand-in, a 'claude-decoy' stand-in, a plain sleep,
# and a pid that has already exited. Each is asked about through the public
# fm_harness_pid_alive verdict at COLUMNS=4 LINES=2, for target and base trees.
set -u
WT=/home/user/.no-mistakes/worktrees/5cf2740bfd30/01M41QQYPP1ZP31YCVAQEYH82V
BASE=72ec8e018848d5bd4ad37d69fa56e437c9fbb642
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-adv.XXXXXX")
mkdir -p "$T/bin"
ln -s "$(command -v bash)" "$T/bin/claude"
ln -s "$(command -v bash)" "$T/bin/claude-decoy"
git clone -q "$WT" "$T/base"
git -C "$T/base" checkout -q "$BASE"

"$T/bin/claude" -c 'sleep 120; :' >/dev/null 2>&1 & REAL=$!
"$T/bin/claude-decoy" -c 'sleep 120; :' >/dev/null 2>&1 & DECOY=$!
sleep 120 >/dev/null 2>&1 & SLEEP=$!
DEAD=$(bash -c 'echo $$')
sleep 0.3

cleanup() {
  pkill -P "$REAL" 2>/dev/null; pkill -P "$DECOY" 2>/dev/null
  kill "$REAL" "$DECOY" "$SLEEP" 2>/dev/null
  rm -rf -- "$T"
}
trap cleanup EXIT

echo "# fm_harness_pid_alive at COLUMNS=4 LINES=2 (target $(git -C "$WT" rev-parse --short HEAD) vs base $(git -C "$T/base" rev-parse --short HEAD))"
for who in "real-claude:$REAL" "claude-decoy:$DECOY" "plain-sleep:$SLEEP" "dead-pid:$DEAD"; do
  name=${who%%:*}; pid=${who#*:}
  for tree in target base; do
    root=$WT; [ "$tree" = base ] && root=$T/base
    v=$(COLUMNS=4 LINES=2 bash -c '. "$1/bin/fm-session-lock-lib.sh"; fm_harness_pid_alive "$2" && echo live-harness || echo not-harness' _ "$root" "$pid" 2>/dev/null)
    printf '%-13s %-6s -> %s\n' "$name" "$tree" "$v"
  done
  v=$(COLUMNS=1000 bash -c '. "$1/bin/fm-session-lock-lib.sh"; fm_harness_pid_alive "$2" && echo live-harness || echo not-harness' _ "$T/base" "$pid" 2>/dev/null)
  printf '%-13s %-6s -> %s   (wide-shell reference: base at COLUMNS=1000)\n' "$name" base-w "$v"
done
echo
echo "unpinned comm at 4x2: real='$(COLUMNS=4 LINES=2 ps -o comm= -p "$REAL" 2>/dev/null)' decoy='$(COLUMNS=4 LINES=2 ps -o comm= -p "$DECOY" 2>/dev/null)'"
echo "-ww comm at 4x2:      real='$(COLUMNS=4 LINES=2 ps -ww -o comm= -p "$REAL" 2>/dev/null)' decoy='$(COLUMNS=4 LINES=2 ps -ww -o comm= -p "$DECOY" 2>/dev/null)'"
