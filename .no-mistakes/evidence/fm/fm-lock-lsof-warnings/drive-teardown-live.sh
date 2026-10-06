#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
MODE=${1:-stale}
TREEHOUSE_BIN=$(command -v treehouse)
TASKS_BIN=$(command -v tasks-axi)
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
mkdir "$LAB/tools"
ln -s "$TREEHOUSE_BIN" "$LAB/tools/treehouse"
ln -s "$TASKS_BIN" "$LAB/tools/tasks-axi"
export PATH="$LAB/tools:/usr/bin:/bin"
export FM_HOME="$LAB" TMPDIR="$ROOT/.fm-test-tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=lock-test GIT_AUTHOR_EMAIL=lock-test@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
export TREEHOUSE_ROOT="$LAB/pool"
project="$LAB/projects/lock-fixture"
git init -q -b main "$project"
git -C "$project" commit --allow-empty -qm 'fixture baseline'
wt=$(cd "$project" && treehouse get --lease --no-fetch)
printf 'Real Treehouse lease: %s\n' "$wt"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
(cd "$LAB" && tasks-axi add lock-test 'disposable lock validation' --kind ship --file "$LAB/data/backlog.md" >/dev/null && tasks-axi start lock-test --file "$LAB/data/backlog.md" >/dev/null)
cat > "$LAB/state/lock-test.meta" <<META
worktree=$wt
project=$project
endpoint_task_id=lock-test
kind=ship
mode=local-only
META
lock=$(git -C "$wt" rev-parse --path-format=absolute --git-path index.lock)
touch "$lock"
touch -d '4 minutes ago' "$lock"
case "$MODE" in
  stale) ;;
  held)
    bash -c 'exec 9<"$1"; touch "$2"; exec sleep 120' _ "$lock" "$LAB/holder-ready" &
    holder=$!
    for _ in {1..100}; do [ -e "$LAB/holder-ready" ] && break; sleep .02; done
    [ -e "$LAB/holder-ready" ]
    lsof -w -- "$lock"
    ;;
  fresh) touch "$lock" ;;
  *) exit 2 ;;
esac
printf '\nScenario: %s index.lock via real fm-teardown and Treehouse return\n' "$MODE"
printf 'lock=%s; bytes=%s; mtime=%s\n' "$lock" "$(stat -c %s "$lock")" "$(stat -c %y "$lock")"
rc=0
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 bash "$ROOT/bin/fm-teardown.sh" lock-test || rc=$?
printf 'teardown exit=%s\n' "$rc"
if [ "$MODE" = stale ]; then
  [ "$rc" = 0 ]
  [ ! -e "$lock" ]
  [ ! -e "$LAB/state/lock-test.meta" ]
  printf 'Persisted result: lock absent; metadata absent; backlog follows:\n'
else
  [ "$rc" = 1 ]
  [ -e "$lock" ]
  [ -e "$LAB/state/lock-test.meta" ]
  [ "$(stat -c %s "$lock")" = 0 ]
  if [ -n "$holder" ]; then kill -0 "$holder"; fi
  printf 'Persisted result: lock and task metadata preserved; holder (if any) still alive; backlog follows:\n'
fi
(cd "$LAB" && tasks-axi show lock-test --file "$LAB/data/backlog.md")
(cd "$project" && treehouse status)
printf '\nScenario %s met its expected safety result; disposable lab will be removed.\n' "$MODE"
