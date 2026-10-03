#!/usr/bin/env bash
# Live lab driver for the 4x2 Stop-hook auto-arm scenario.
# Usage: lab-driver.sh <target|base> <evidence-dir> [wide]
#   wide: control run that never shrinks the pane (stays 200x50)
#
# Runs the real installed Claude Code interactively on a private tmux socket
# (fm-lab) against a marked disposable lab FM_HOME. The firstmate project is a
# plain git clone of the run worktree (the gate worktree itself is a linked
# worktree, so fm_primary_scope_matches makes every Stop hook inert there),
# checked out at the target commit or the base commit. The clone keeps the
# real tracked .claude/settings.json hooks; only bin/fm-watch-arm.sh and
# bin/fm-wake-drain.sh are replaced by the bounded fixtures that
# tests/fm-claude-stop-autoarm-live-e2e.test.sh uses, so the rewake loop ends
# after two cycles. The session starts at 200x50, session start takes the lock,
# then the pane is shrunk to 4x2 before the first turn ends - the display size
# Claude then hands its Stop hooks as COLUMNS=4 LINES=2.
set -u

VARIANT=${1:?variant}
EV=${2:?evidence dir}
WIDTH_MODE=${3:-narrow}
WT=/home/user/.no-mistakes/worktrees/5cf2740bfd30/01M41QQYPP1ZP31YCVAQEYH82V
BASE=72ec8e018848d5bd4ad37d69fa56e437c9fbb642
OUT="$EV/live-$VARIANT"
[ "$WIDTH_MODE" = wide ] && OUT="$EV/live-$VARIANT-wide-control"
mkdir -p "$OUT"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$OUT/driver.log"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
PROJ=$(mktemp -d "${TMPDIR:-/tmp}/fm-labproj.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { log "lab home create failed"; exit 1; }
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }

teardown() {
  T kill-server 2>/dev/null || true
  sleep 1
  local stray
  stray=$(pgrep -af "$LAB|$PROJ" 2>/dev/null | grep -v pgrep || true)
  if [ -n "$stray" ]; then
    log "stray processes after kill-server: $stray"
    pgrep -f "$LAB|$PROJ" | xargs -r kill 2>/dev/null || true
  fi
  rm -rf "$LAB" "$PROJ"
  log "teardown done: lab and project removed"
}
trap teardown EXIT

git clone -q "$WT" "$PROJ/fm"
if [ "$VARIANT" = base ]; then
  git -C "$PROJ/fm" checkout -q "$BASE"
fi
log "variant=$VARIANT project=$PROJ/fm head=$(git -C "$PROJ/fm" rev-parse --short HEAD) FM_HOME=$LAB"

cat > "$PROJ/fm/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON
cat > "$PROJ/fm/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
cat > "$PROJ/fm/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$ COLUMNS=${COLUMNS-unset} LINES=${LINES-unset}" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
cat > "$PROJ/fm/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJ/fm/bin/tool-logger.sh" "$PROJ/fm/bin/fm-watch-arm.sh" "$PROJ/fm/bin/fm-wake-drain.sh"

printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$LAB/state/task.meta"
printf '9999999\n' > "$LAB/state/.lock"

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$PROJ/fm" \
  -e FM_HOME="$LAB" -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  claude --model haiku --dangerously-skip-permissions
log "claude started on private socket fm-lab"

# Trust dialog for the fresh clone path.
for _ in $(seq 1 30); do
  sleep 1
  if T capture-pane -p -t primary | grep -q 'Yes, I trust this folder'; then
    T send-keys -t primary Down; sleep 0.5; T send-keys -t primary Enter
    log "accepted the folder trust dialog"
    break
  fi
  T capture-pane -p -t primary | grep -q 'Claude Code v' && break
done

for _ in $(seq 1 120); do
  [ -e "$LAB/state/.session-start-complete" ] && [ "$(cat "$LAB/state/.lock" 2>/dev/null)" != 9999999 ] && break
  sleep 1
done
LOCK_PID=$(sed -n 1p "$LAB/state/.lock" 2>/dev/null)
log "session start complete=$([ -e "$LAB/state/.session-start-complete" ] && echo yes || echo no) lock=$LOCK_PID"
ps -ww -o pid=,ppid=,comm=,args= -p "$LOCK_PID" 2>/dev/null | cut -c1-160 | sed 's/^/lock owner: /' | tee -a "$OUT/driver.log"
T capture-pane -p -t primary > "$OUT/pane-after-session-start.txt"

if [ "$WIDTH_MODE" != wide ]; then
  T set-option -t primary window-size manual
  T resize-window -t primary -x 4 -y 2
fi
sleep 1
log "pane resized to $(T display-message -p -t primary '#{window_width}x#{window_height}')"

PROMPT='After reading the complete session-start digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'
T send-keys -t primary -l "$PROMPT"
sleep 1
T send-keys -t primary Enter
log "prompt sent at $(T display-message -p -t primary '#{window_width}x#{window_height}')"

TRANSCRIPT_DIR="$HOME/.claude/projects/$(printf '%s' "$PROJ/fm" | sed 's|[/.]|-|g')"
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 3
  JSONL=$(ls -t "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | head -1)
  drains=$(wc -l < "$LAB/state/drain-ran" 2>/dev/null | tr -d ' ')
  if [ "$VARIANT" = target ]; then
    [ "${drains:-0}" -ge 3 ] && [ ! -e "$LAB/state/task.meta" ] && break
  else
    [ -n "$JSONL" ] && grep -q 'TURN WOULD END BLIND' "$JSONL" 2>/dev/null && { sleep 8; break; }
  fi
done
sleep 5
log "wait finished: drains=${drains:-0} transcript=${JSONL:-none}"

T resize-window -t primary -x 200 -y 50
sleep 2
T capture-pane -p -S - -t primary > "$OUT/pane-final.txt"

{
  echo "## state/.lock"; cat "$LAB/state/.lock" 2>/dev/null
  echo "## lock owner process (ps -ww)"; ps -ww -o pid=,comm=,args= -p "$(sed -n 1p "$LAB/state/.lock" 2>/dev/null)" 2>/dev/null | cut -c1-160
  echo "## state/.claude-autoarm-epoch"; cat "$LAB/state/.claude-autoarm-epoch" 2>/dev/null || echo "(absent)"
  echo "## state/arm-ran (hook-owned arm invocations)"; cat "$LAB/state/arm-ran" 2>/dev/null || echo "(absent)"
  echo "## state/drain-ran"; cat "$LAB/state/drain-ran" 2>/dev/null || echo "(absent)"
  echo "## state/tool-calls.log (model-issued Bash)"; cat "$LAB/state/tool-calls.log" 2>/dev/null || echo "(absent)"
  echo "## state/task.meta present?"; [ -e "$LAB/state/task.meta" ] && echo yes || echo no
  echo "## state listing"; ls -la "$LAB/state"
} > "$OUT/state.txt" 2>&1

if [ -n "${JSONL:-}" ]; then
  jq -r '
    select(.type == "user" or .type == "assistant" or .type == "system")
    | [.type, (
        if (.message.content | type) == "string" then .message.content
        else ([.message.content[]? | (.text // .content // (.input | tostring?) // "") | tostring] | join(" | "))
        end
      ), (.content // "")] | @tsv
  ' "$JSONL" 2>/dev/null | cut -c1-600 > "$OUT/transcript-digest.tsv"
  grep -c 'Stop hook feedback' "$JSONL" | sed 's/^/Stop hook feedback mentions: /' >> "$OUT/driver.log"
  grep -c 'TURN WOULD END BLIND' "$JSONL" | sed 's/^/TURN WOULD END BLIND mentions: /' >> "$OUT/driver.log"
  grep -o 'stale: fixture-rapid-[0-9]' "$JSONL" | sort | uniq -c | sed 's/^/rewake reason: /' >> "$OUT/driver.log"
fi
log "evidence written to $OUT"
