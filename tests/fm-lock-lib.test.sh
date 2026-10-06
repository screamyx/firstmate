#!/usr/bin/env bash
# tests/fm-lock-lib.test.sh - fm_lock_lsof_holder's verdicts against stub lsof
# binaries, including the Docker host whose lsof prints overlay-filesystem
# warnings on stderr unless run with -w. The stubs cannot prove the real flag;
# the PR evidence records the real lsof run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-lib-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# shellcheck source=bin/fm-lock-lib.sh
. "$ROOT/bin/fm-lock-lib.sh"

holder_verdict() {  # echoes "<status>|<stderr>"
  local status err
  err=$(PATH="$FAKEBIN:$PATH" fm_lock_lsof_holder /some/lock 2>&1 >/dev/null)
  status=$?
  printf '%s|%s' "$status" "$err"
}

write_lsof() {
  cat > "$FAKEBIN/lsof"
  chmod +x "$FAKEBIN/lsof"
}

# Docker host: warnings and exit 1 unless -w is given, then silent exit 1.
write_lsof <<'SH'
#!/usr/bin/env bash
quiet=0
for a in "$@"; do [ "$a" = -w ] && quiet=1; done
if [ "$quiet" -eq 0 ]; then
  echo "lsof: WARNING: can't stat() overlay file system /x" >&2
  echo "      Output information may be incomplete." >&2
fi
exit 1
SH
verdict=$(holder_verdict)
assert_equals "1|" "$verdict" "docker overlay warnings are not an lsof error"
pass "overlay warnings with exit 1 yield provably none"

write_lsof <<'SH'
#!/usr/bin/env bash
echo "lsof: status error on /x: Permission denied" >&2
exit 1
SH
verdict=$(holder_verdict)
case "$verdict" in 2\|*"Permission denied"*) ;; *) fail "real error output must stay cannot-tell: $verdict" ;; esac
pass "real error output yields cannot tell"

write_lsof <<'SH'
#!/usr/bin/env bash
exit 3
SH
verdict=$(holder_verdict)
case "$verdict" in 2\|*"exit 3"*) ;; *) fail "non-1 exit must stay cannot-tell: $verdict" ;; esac
pass "non-1 failure exit yields cannot tell"

write_lsof <<'SH'
#!/usr/bin/env bash
echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
echo "git 123 u 3w REG 0,1 0 1 /some/lock"
exit 0
SH
verdict=$(holder_verdict)
assert_equals "0|" "$verdict" "a listed holder is reported held"
pass "listed holder yields held"
