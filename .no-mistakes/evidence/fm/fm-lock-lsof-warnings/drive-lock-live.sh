#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/user/.no-mistakes/evidence/01M47SEFHBEVNEBNC3WZB3TY9H
FIXTURE=$(mktemp -d "$ROOT/.fm-test-tmp/fm-lock-live.XXXXXX")
holder=
cleanup() {
  if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
  rm -rf "$FIXTURE"
}
trap cleanup EXIT
mkdir -p "$FIXTURE/worktree"
lock="$FIXTURE/worktree/index.lock"
touch "$lock"
touch -d '4 minutes ago' "$lock"
status_call() {
  local status=0
  "$@" || status=$?
  printf 'exit=%s\n' "$status"
  LAST_STATUS=$status
}
expect() { [ "$LAST_STATUS" = "$1" ] || { echo "FAIL: expected exit=$1"; exit 1; }; }
. "$EVIDENCE/baseline-fm-lock-lib.sh"
printf '\nBASELINE: original product library against real Docker-host lsof\n'
status_call fm_lock_lsof_holder "$lock"
expect 2
status_call fm_lock_is_provably_stale "$lock" "$FIXTURE/worktree" 30
expect 1
. "$ROOT/bin/fm-lock-lib.sh"
printf '\nCURRENT: four-minute-old empty lock, no live holder\n'
printf 'lock bytes=%s; age=%ss\n' "$(stat -c %s "$lock")" "$(fm_lock_age "$lock")"
status_call fm_lock_lsof_holder "$lock"
expect 1
status_call fm_lock_lsof_holder "$FIXTURE/worktree"
expect 1
status_call fm_lock_is_provably_stale "$lock" "$FIXTURE/worktree" 30
expect 0
printf '\nADVERSARIAL: real process keeps old lock open on fd 9\n'
bash -c 'exec 9<"$1"; touch "$2"; exec sleep 120' _ "$lock" "$FIXTURE/ready" &
holder=$!
for _ in {1..100}; do [ -e "$FIXTURE/ready" ] && break; sleep .02; done
[ -e "$FIXTURE/ready" ]
status_call lsof -w -- "$lock"
expect 0
status_call fm_lock_lsof_holder "$lock"
expect 0
status_call fm_lock_is_provably_stale "$lock" "$FIXTURE/worktree" 30
expect 1
[ -e "$lock" ]
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=
rm "$FIXTURE/ready"
printf '\nADVERSARIAL: real process has the companion worktree as cwd\n'
bash -c 'cd "$1"; touch "$2"; exec sleep 120' _ "$FIXTURE/worktree" "$FIXTURE/ready" &
holder=$!
for _ in {1..100}; do [ -e "$FIXTURE/ready" ] && break; sleep .02; done
[ -e "$FIXTURE/ready" ]
status_call lsof -w -- "$FIXTURE/worktree"
expect 0
status_call fm_lock_lsof_holder "$lock"
expect 1
status_call fm_lock_is_provably_stale "$lock" "$FIXTURE/worktree" 30
expect 1
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=
rm "$FIXTURE/ready"
printf '\nADVERSARIAL: real process keeps companion worktree open on fd 8\n'
bash -c 'exec 8<"$1"; touch "$2"; exec sleep 120' _ "$FIXTURE/worktree" "$FIXTURE/ready" &
holder=$!
for _ in {1..100}; do [ -e "$FIXTURE/ready" ] && break; sleep .02; done
[ -e "$FIXTURE/ready" ]
status_call lsof -w -- "$FIXTURE/worktree"
expect 0
status_call fm_lock_is_provably_stale "$lock" "$FIXTURE/worktree" 30
expect 1
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=
printf '\nADVERSARIAL: fresh unheld lock does not meet minimum age\n'
touch "$lock"
status_call fm_lock_lsof_holder "$lock"
expect 1
status_call fm_lock_is_provably_stale "$lock" "$FIXTURE/worktree" 30
expect 1
printf '\nERROR: real lsof receives a missing path; -w preserves its error\n'
status_call fm_lock_lsof_holder "$FIXTURE/missing.lock"
expect 2
touch -d '4 minutes ago' "$lock"
printf '\nERROR: companion-directory lookup fails, so old lock stays unproven\n'
status_call fm_lock_is_provably_stale "$lock" "$FIXTURE/missing-directory" 30
expect 1
[ -e "$lock" ]
printf '\nAll real-lsof scenarios met their expected verdicts.\n'
