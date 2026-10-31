#!/usr/bin/env bash
# test-home-exposure.sh — fixture tests for scripts/check-home-exposure.sh.
#
# Builds small fictional home directories under a temporary directory and
# checks the verdict, the exit code, which paths are listed, and that file
# contents never reach the output. ACL cases need setfacl and a filesystem
# with POSIX ACL support; they are reported as SKIP otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/check-home-exposure.sh"
PASS=0
FAIL=0
SKIP=0

ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# The marker is written into every fixture file. It must never be printed.
MARKER="FIXTURE_CONTENT_MUST_NOT_PRINT_7f3a"

# An id that is not the current user, for ACL entries. 65534 is the
# conventional "nobody" id; numeric ids work even if no account exists.
ACL_ID=65534

run() { # run <home> [args...]; sets OUT and RC
  local h="$1"; shift
  OUT="$(bash "$SCRIPT" --home "$h" "$@" 2>&1)"
  RC=$?
}

show_out() { printf '%s\n' "$OUT" | sed 's/^/       /'; }
expect_rc() {
  if [ "$RC" -eq "$1" ]; then ok "$2 (exit $RC)"; else bad "$2 (exit $RC, expected $1)"; show_out; fi
}
expect_line() {
  if printf '%s\n' "$OUT" | grep -qE "$1"; then ok "$2"; else bad "$2"; show_out; fi
}
expect_no_line() {
  if printf '%s\n' "$OUT" | grep -qE "$1"; then bad "$2"; show_out; else ok "$2"; fi
}
no_marker() {
  if printf '%s\n' "$OUT" | grep -qF "$MARKER"; then bad "contents leaked: $1"; else ok "no contents printed: $1"; fi
}

mkfile() { # mkfile <path> <mode>
  mkdir -p "$(dirname "$1")"
  printf 'API_TOKEN=%s\n' "$MARKER" > "$1"
  chmod "$2" "$1"
}

# A home with an application tree whose directories are world-traversable
# and whose secret files are world-readable — the common real-world layout.
mkhome() { # mkhome <dir> <home-mode>
  local h="$1"
  mkdir -p "$h/projects/example-api/data" "$h/projects/example-api/node_modules/pkg" "$h/closed"
  chmod 755 "$h/projects" "$h/projects/example-api" "$h/projects/example-api/data"
  mkfile "$h/projects/example-api/.env" 664
  mkfile "$h/projects/example-api/.env.example" 664
  mkfile "$h/projects/example-api/data/app.db" 644
  mkfile "$h/projects/example-api/node_modules/pkg/.env" 644
  mkfile "$h/projects/example-api/README.md" 644
  chmod 700 "$h/closed"
  mkfile "$h/closed/.env" 644
  chmod "$2" "$h"
}

# Some sandboxes (user namespaces) refuse ACL entries for ids they do not
# map; fall back to a named entry for the current uid, which exercises the
# same parsing and mask logic.
acl_ok=0
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
  mkdir -p "$TMP/acl-probe"
  for cand in "$ACL_ID" "$(id -u)"; do
    if setfacl -m "u:$cand:--x" "$TMP/acl-probe" 2>/dev/null; then
      ACL_ID="$cand"; acl_ok=1; break
    fi
  done
fi

echo "check-home-exposure — fixture tests"

echo
echo "== usage =="
OUT="$(bash "$SCRIPT" --bogus 2>&1)"; RC=$?
expect_rc 64 "unknown argument is a usage error"
OUT="$(bash "$SCRIPT" --max abc --home "$TMP" 2>&1)"; RC=$?
expect_rc 64 "non-numeric --max is a usage error"
run "$TMP/does-not-exist"
expect_rc 2 "missing directory is UNKNOWN"
expect_line '^VERDICT: UNKNOWN' "missing directory verdict line"
OUT="$(bash "$SCRIPT" --help 2>&1)"; RC=$?
expect_rc 0 "--help exits 0"
expect_line 'Exit codes' "--help shows the exit codes"

echo
echo "== 0700 home, no ACL: PRIVATE =="
mkhome "$TMP/h1" 700
run "$TMP/h1"
if [ "$acl_ok" -eq 0 ] && ! command -v getfacl >/dev/null 2>&1; then
  expect_rc 0 "private home without getfacl still evaluates"
else
  expect_rc 0 "private home exits 0"
fi
expect_line '^VERDICT: PRIVATE$' "verdict PRIVATE"
expect_no_line 'example-api/\.env' "no file listing for a private home"
no_marker "private home"

echo
echo "== 0751 home (other may traverse): EXPOSED =="
mkhome "$TMP/h2" 751
run "$TMP/h2"
expect_rc 1 "other-traversable home with readable .env exits 1"
expect_line '^VERDICT: EXPOSED — 2 credential-shaped' "two files reported"
expect_line '664 +.*/projects/example-api/\.env$' ".env listed with its mode"
expect_line '644 +.*/projects/example-api/data/app\.db$' "database listed"
expect_no_line '\.env\.example' "template files are not listed"
expect_no_line '/node_modules/' "node_modules is skipped"
expect_no_line '/closed/' "files below a closed directory are not listed"
expect_no_line 'README' "ordinary files are not listed"
expect_line 'every local account' "names the principal"
no_marker "other-traversable home"

echo
echo "== --max truncates the listing =="
run "$TMP/h2" --max 1
expect_rc 1 "truncated listing still exits 1"
expect_line '\.\.\. and 1 more' "truncation notice"
no_marker "truncated listing"

echo
echo "== 0751 home, secrets tightened: TRAVERSABLE, not exposed =="
mkhome "$TMP/h3" 751
chmod 600 "$TMP/h3/projects/example-api/.env" "$TMP/h3/projects/example-api/data/app.db"
run "$TMP/h3"
expect_rc 0 "no reachable credential file exits 0"
expect_line '^VERDICT: TRAVERSABLE — no credential-shaped file is reachable' "verdict TRAVERSABLE"
no_marker "tightened home"

echo
echo "== directory without other-execute blocks the walk =="
mkhome "$TMP/h4" 751
chmod 750 "$TMP/h4/projects"
run "$TMP/h4"
expect_rc 0 "closed intermediate directory exits 0"
expect_no_line 'example-api' "nothing below the closed directory is listed"

echo
echo "== 0750 home + named ACL traverse entry: EXPOSED =="
if [ "$acl_ok" -eq 1 ]; then
  mkhome "$TMP/h5" 750
  setfacl -m "u:$ACL_ID:--x" "$TMP/h5"
  run "$TMP/h5"
  expect_rc 1 "ACL-traversable home with readable .env exits 1"
  expect_line "acl: +user .*$ACL_ID.* can traverse" "ACL principal is named"
  expect_line '^VERDICT: EXPOSED' "verdict EXPOSED"
  expect_line '/projects/example-api/\.env$' ".env listed"
  no_marker "ACL home"

  echo
  echo "== ACL entry neutralised by the mask: PRIVATE =="
  mkhome "$TMP/h6" 700
  setfacl -m "u:$ACL_ID:--x" "$TMP/h6"
  setfacl -m "m::---" "$TMP/h6"
  run "$TMP/h6"
  expect_rc 0 "masked ACL entry exits 0"
  expect_line 'without effective execute' "masked entry reported as ineffective"
  expect_line '^VERDICT: PRIVATE$' "verdict PRIVATE"

  echo
  echo "== mask without a visible named entry: UNKNOWN, never PRIVATE =="
  mkhome "$TMP/h10" 750
  setfacl -m "u:$ACL_ID:--x" "$TMP/h10"
  setfacl -x "u:$ACL_ID" "$TMP/h10"
  run "$TMP/h10"
  expect_rc 2 "orphan mask exits 2"
  expect_line 'mask entry exists but no named entry is visible -> UNKNOWN' "explains the hidden-entry possibility"
  expect_no_line '^VERDICT: PRIVATE' "does not claim PRIVATE"
  no_marker "orphan mask"

  echo
  echo "== default ACL entries are reported =="
  mkhome "$TMP/h7" 700
  setfacl -d -m "u:$ACL_ID:r-x" "$TMP/h7"
  run "$TMP/h7"
  expect_line 'default ACL entries present' "default ACL noted"
else
  skip "ACL cases (setfacl unavailable or filesystem lacks ACL support)"
fi

echo
echo "== ACL present but getfacl missing: UNKNOWN =="
if [ "$acl_ok" -eq 1 ]; then
  mkhome "$TMP/h8" 750
  setfacl -m "u:$ACL_ID:--x" "$TMP/h8"
  shim="$TMP/shim"; mkdir -p "$shim"
  for c in bash env date stat cat cut tr grep awk sed sort head find ls getent printf pwd dirname; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$shim/$c"
  done
  OUT="$(PATH="$shim" bash "$SCRIPT" --home "$TMP/h8" 2>&1)"; RC=$?
  expect_rc 2 "unreadable ACL model exits 2"
  expect_line 'getfacl is not installed -> UNKNOWN' "says UNKNOWN instead of guessing"
  no_marker "getfacl missing"
else
  skip "getfacl-missing case (needs an ACL fixture)"
fi

echo
echo "== the script never changes permissions =="
mkhome "$TMP/h9" 751
before="$(find "$TMP/h9" -printf '%m %p\n' | sort)"
run "$TMP/h9"
after="$(find "$TMP/h9" -printf '%m %p\n' | sort)"
if [ "$before" = "$after" ]; then ok "modes unchanged after a run"; else bad "modes changed by the script"; fi
if grep -qE '(^|[^a-z])(chmod|chown|setfacl|chgrp)[[:space:]]+[^"]*"\$' "$SCRIPT"; then
  bad "script contains a permission-changing command"
else
  ok "script contains no permission-changing command"
fi
if grep -qE '\bcat\b[^|]*"\$(HOME_DIR|rel)|while read.*<[[:space:]]*"\$HOME_DIR' "$SCRIPT"; then
  bad "script reads file contents"
else
  ok "script does not read file contents"
fi

echo
echo "================================"
printf 'passed: %d   failed: %d   skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo "HOME EXPOSURE TESTS: FAIL"
  exit 1
fi
echo "HOME EXPOSURE TESTS: PASS"
exit 0
