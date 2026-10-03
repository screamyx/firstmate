#!/usr/bin/env bash
# Live check of bin/fm-remote-job-reap-orphans.sh --dry-run at a 4x2 width.
# A real stand-in remote job worker (/bin/bash <root>/bin/fm-remote-job-worker.sh --serve)
# runs from a fixture code root that is then pruned (AGENTS.md removed), which is
# exactly the reaper's candidate rule. The reaper's scan line and its live re-read
# must agree for the candidate to be reported. --dry-run signals nothing.
set -u
WT=/home/user/.no-mistakes/worktrees/5cf2740bfd30/01M41QQYPP1ZP31YCVAQEYH82V
BASE=72ec8e018848d5bd4ad37d69fa56e437c9fbb642
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-reapw.XXXXXX")
R="$T/pruned-root-with-a-long-enough-path"
mkdir -p "$R/bin"
printf '%s\n' '#!/bin/bash' 'sleep 120' > "$R/bin/fm-remote-job-worker.sh"
chmod +x "$R/bin/fm-remote-job-worker.sh"
: > "$R/AGENTS.md"
git clone -q "$WT" "$T/base"
git -C "$T/base" checkout -q "$BASE"

setsid /bin/bash "$R/bin/fm-remote-job-worker.sh" --serve >/dev/null 2>&1 &
sleep 0.5
WORKER=$(pgrep -f "^/bin/bash $R/bin/fm-remote-job-worker.sh --serve" | head -1)

cleanup() {
  [ -n "$WORKER" ] && { pkill -P "$WORKER" 2>/dev/null; kill "$WORKER" 2>/dev/null; }
  rm -rf -- "$T"
}
trap cleanup EXIT

rm -f "$R/AGENTS.md"   # prune: the root is no longer a live Firstmate code root
echo "# stand-in worker pid=$WORKER command: $(ps -ww -o command= -p "$WORKER")"
echo "# unpinned command at 4x2: '$(COLUMNS=4 LINES=2 ps -o command= -p "$WORKER" 2>/dev/null)'"
echo
for tree in target base; do
  root=$WT; [ "$tree" = base ] && root=$T/base
  for width in "COLUMNS=4 LINES=2" "COLUMNS=1000"; do
    # shellcheck disable=SC2086
    out=$(env $width "$root/bin/fm-remote-job-reap-orphans.sh" --dry-run 2>&1 | grep -F "worker $WORKER " || true)
    printf '%-6s %-17s -> %s\n' "$tree" "$width" "${out:-(no candidate reported)}"
  done
done
kill -0 "$WORKER" 2>/dev/null && echo && echo "# stand-in worker still alive after every dry run (nothing signalled)"
