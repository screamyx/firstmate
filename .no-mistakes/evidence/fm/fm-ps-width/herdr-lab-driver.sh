#!/usr/bin/env bash
# Live Herdr lab driver for the descendant-scan width fix in
# fm_backend_herdr_pane_process_state_sample (bin/backends/herdr.sh).
# Usage: herdr-lab-driver.sh <evidence-dir> <base-clone-root>
#
# A named non-default fm-lab-* Herdr session is provisioned and torn down only
# through bin/fm-herdr-lab.sh. One pane's shell starts a claude stand-in (a
# bash symlink named claude) as a BACKGROUND job, so Herdr reports only the
# pane shell in the foreground and only the descendant scan of the real process
# table can find the harness. The sampler is then asked about that pane at
# COLUMNS=4 LINES=2 (the Claude Stop-hook display size) and at a wide width,
# with the target tree (run worktree) and the base tree (a clone at the base
# commit). All Herdr calls from the sampler go through a shim that forwards to
# `fm-herdr-lab.sh run <session>`, exactly as tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh does.
set -u

EV=${1:?evidence dir}
BASE_ROOT=${2:?base clone root}
WT=/home/user/.no-mistakes/worktrees/5cf2740bfd30/01M41QQYPP1ZP31YCVAQEYH82V
OUT="$EV/live-herdr"
mkdir -p "$OUT"
LOG="$OUT/driver.log"
: > "$LOG"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
HELPER="$WT/bin/fm-herdr-lab.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-pswidth.XXXXXX")
mkdir -p "$WORK/fakebin" "$WORK/bin" "$WORK/project"
ln -s "$(command -v bash)" "$WORK/bin/claude"
ORIG_PATH=$PATH
SESSION=$("$HELPER" name pswidth)
export HERDR_LAB_HELPER="$HELPER" HERDR_LAB_SESSION="$SESSION" HERDR_ORIGINAL_PATH="$ORIG_PATH"

cleanup() {
  env PATH="$ORIG_PATH" "$HELPER" teardown "$SESSION" >>"$LOG" 2>&1 && log "lab session $SESSION torn down" || log "TEARDOWN FAILED for $SESSION"
  pkill -f "$WORK/bin/claude" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

"$HELPER" provision "$SESSION" >>"$LOG" 2>&1 || { log "provision failed"; exit 1; }
log "provisioned lab session $SESSION (herdr $(herdr --version 2>/dev/null))"

cat > "$WORK/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$WORK/fakebin/herdr"
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"; }

CREATE=$(lab workspace create --cwd "$WORK/project" --label pswidth --no-focus) || { log "workspace create failed"; exit 1; }
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') || { log "no pane id"; exit 1; }
log "workspace created, pane=$PANE"
sleep 1
lab pane run "$PANE" "$WORK/bin/claude -c 'sleep 600; :' &" >/dev/null || { log "pane run failed"; exit 1; }
sleep 2

INFO=$(lab pane process-info --pane "$PANE")
printf '%s\n' "$INFO" | jq '.result.process_info | {shell_pid, foreground_processes: [.foreground_processes[] | {pid, name, argv}]}' > "$OUT/pane-process-info.json"
SHELL_PID=$(printf '%s' "$INFO" | jq -r '.result.process_info.shell_pid')
log "herdr pane process-info: shell_pid=$SHELL_PID foreground=$(printf '%s' "$INFO" | jq -c '[.result.process_info.foreground_processes[].name]')"
STAND_IN=$(pgrep -P "$SHELL_PID" -f "$WORK/bin/claude" | head -1)
log "background harness stand-in under the pane shell: pid=$STAND_IN"
{
  echo "# process table as seen by an unpinned read vs -ww at COLUMNS=4 LINES=2"
  echo "unpinned: $(COLUMNS=4 LINES=2 ps -o pid=,ppid=,comm= -p "$STAND_IN" 2>/dev/null)"
  echo "-ww:      $(COLUMNS=4 LINES=2 ps -ww -o pid=,ppid=,comm= -p "$STAND_IN" 2>/dev/null)"
  echo "unpinned args: $(COLUMNS=4 LINES=2 ps -o args= -p "$STAND_IN" 2>/dev/null)"
  echo "-ww args:      $(COLUMNS=4 LINES=2 ps -ww -o args= -p "$STAND_IN" 2>/dev/null)"
} | tee -a "$LOG"

sample() {  # <root> <width-env...>
  local root=$1; shift
  env "$@" PATH="$WORK/fakebin:$ORIG_PATH" bash -c '
    set -u
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_pane_process_state_sample "$2" "$3"
  ' _ "$root" "$SESSION" "$PANE" 2>/dev/null
}
bare_shell() {  # <root> <width-env...>
  local root=$1; shift
  env "$@" bash -c '
    set -u
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_pid_is_bare_shell ps "$2" && echo bare-shell || echo not-bare-shell
  ' _ "$root" "$SHELL_PID" 2>/dev/null
}

{
  echo "| tree | width | pane process-state sample | pane shell bare-shell check |"
  echo "|---|---|---|---|"
  for tree in target base; do
    root=$WT; [ "$tree" = base ] && root=$BASE_ROOT
    echo "| $tree ($(git -C "$root" rev-parse --short HEAD)) | COLUMNS=4 LINES=2 | $(sample "$root" COLUMNS=4 LINES=2) | $(bare_shell "$root" COLUMNS=4 LINES=2) |"
    echo "| $tree ($(git -C "$root" rev-parse --short HEAD)) | COLUMNS=1000 | $(sample "$root" COLUMNS=1000) | $(bare_shell "$root" COLUMNS=1000) |"
  done
  echo
  echo "pane shell comm (unpinned at 4x2): '$(COLUMNS=4 LINES=2 ps -o comm= -p "$SHELL_PID" 2>/dev/null)'  (-ww: '$(ps -ww -o comm= -p "$SHELL_PID" 2>/dev/null)')"
} | tee "$OUT/results.md" | tee -a "$LOG"
