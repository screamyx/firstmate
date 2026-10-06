#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
MODE=${1:-stale}
LAB=$(mktemp -d "$ROOT/.fm-test-tmp/fm-lab.XXXXXX")
holder=
cleanup() {
  if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
  rm -rf "$LAB"
}
trap cleanup EXIT
for var in ${!FM_@}; do case "$var" in *_OVERRIDE) unset "$var" ;; esac; done
unset FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
bash "$ROOT/bin/fm-lab-home.sh" create "$LAB"
export FM_HOME="$LAB" TMPDIR="$ROOT/.fm-test-tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=lock-test GIT_AUTHOR_EMAIL=lock-test@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
origin="$LAB/origin.git"
seed="$LAB/seed"
project="$LAB/projects/lock-fixture"
git init -q --bare -b main "$origin"
git init -q -b main "$seed"
git -C "$seed" commit --allow-empty -qm baseline
git -C "$seed" remote add origin "$origin"
git -C "$seed" push -q origin main main:refs/heads/retired-topic
git clone -q "$origin" "$project"
git -C "$project" pack-refs --all
before=$(git -C "$project" rev-parse HEAD)
git -C "$seed" commit --allow-empty -qm 'new upstream work'
git -C "$seed" push -q origin main :retired-topic
expected=$(git -C "$seed" rev-parse HEAD)
lock="$project/.git/packed-refs.lock"
touch "$lock"
touch -d '4 minutes ago' "$lock"
case "$MODE" in
  stale) ;;
  cwd)
    bash -c 'cd "$1"; touch "$2"; exec sleep 120' _ "$project" "$LAB/ready" &
    holder=$!
    ;;
  fd)
    bash -c 'exec 8<"$1"; touch "$2"; exec sleep 120' _ "$project" "$LAB/ready" &
    holder=$!
    ;;
  *) exit 2 ;;
esac
if [ -n "$holder" ]; then
  for _ in {1..100}; do [ -e "$LAB/ready" ] && break; sleep .02; done
  [ -e "$LAB/ready" ]
  lsof -w -- "$project"
fi
printf 'Scenario: %s companion holder during real fleet-sync fetch --prune\n' "$MODE"
printf 'before HEAD=%s; upstream HEAD=%s; old lock=%s\n' "$before" "$expected" "$lock"
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 bash "$ROOT/bin/fm-fleet-sync.sh" lock-fixture
actual=$(git -C "$project" rev-parse HEAD)
if [ "$MODE" = stale ]; then
  [ ! -e "$lock" ]
  [ "$actual" = "$expected" ]
  if git -C "$project" show-ref --verify --quiet refs/remotes/origin/retired-topic; then exit 1; fi
  printf 'Persisted result: lock removed; clone HEAD=%s; retired remote-tracking branch absent\n' "$actual"
else
  [ -e "$lock" ]
  [ "$actual" = "$before" ]
  kill -0 "$holder"
  git -C "$project" show-ref --verify --quiet refs/remotes/origin/retired-topic
  printf 'Persisted result: lock preserved; clone HEAD=%s unchanged; companion holder alive; retired remote-tracking branch preserved\n' "$actual"
fi
printf 'Disposable lab will be removed.\n'
