#!/usr/bin/env bash
# test-basic.sh — smoke tests for AI System Map.
#
# Verifies that scripts parse, that the shipped example passes validation,
# that the validator actually rejects broken input, and that no script can
# print secret material. Read-only; uses a temporary directory it cleans up.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "AI System Map — basic tests"
echo "Root: $ROOT"

echo
echo "== shell syntax =="
for f in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then
    ok "syntax: $(basename "$f")"
  else
    bad "syntax: $(basename "$f")"
  fi
done

echo
echo "== required files =="
for f in README.md LICENSE SECURITY.md CONTRIBUTING.md .gitignore \
         docs/ARCHITECTURE.md docs/QUICKSTART.md docs/AGENT-INTEGRATION.md; do
  if [ -f "$ROOT/$f" ]; then ok "present: $f"; else bad "missing: $f"; fi
done

echo
echo "== templates and example are complete =="
for doc in SYSTEM.md SERVICES.md PORTS.md SECURITY.md BACKUPS.md RESTORE.md; do
  if [ -f "$ROOT/templates/$doc" ]; then ok "template: $doc"; else bad "template missing: $doc"; fi
  if [ -f "$ROOT/examples/sample-system-map/$doc" ]; then
    ok "example: $doc"
  else
    bad "example missing: $doc"
  fi
done

echo
echo "== validator accepts the shipped example =="
if bash "$ROOT/scripts/validate-system-map.sh" "$ROOT/examples/sample-system-map" >/dev/null 2>&1; then
  ok "example map validates"
else
  bad "example map does not validate"
  bash "$ROOT/scripts/validate-system-map.sh" "$ROOT/examples/sample-system-map" 2>&1 | sed 's/^/       /'
fi

echo
echo "== validator rejects an incomplete map =="
mkdir -p "$TMP/empty"
if bash "$ROOT/scripts/validate-system-map.sh" "$TMP/empty" >/dev/null 2>&1; then
  bad "validator accepted an empty directory"
else
  ok "validator rejects an empty map"
fi

echo
echo "== validator rejects unresolved placeholders =="
mkdir -p "$TMP/tpl"
cp "$ROOT"/templates/*.md "$TMP/tpl/"
if bash "$ROOT/scripts/validate-system-map.sh" "$TMP/tpl" >/dev/null 2>&1; then
  bad "validator accepted raw templates with placeholders"
else
  ok "validator rejects raw templates"
fi

echo
echo "== validator rejects an unsupported exposure value =="
mkdir -p "$TMP/bad"
cp "$ROOT"/examples/sample-system-map/*.md "$TMP/bad/"
sed -i 's/PUBLIC_VIA_PROXY/TOTALLY_PUBLIC/' "$TMP/bad/PORTS.md"
if bash "$ROOT/scripts/validate-system-map.sh" "$TMP/bad" >/dev/null 2>&1; then
  bad "validator accepted an unsupported exposure value"
else
  ok "validator rejects an unsupported exposure value"
fi

echo
echo "== validator rejects a pasted credential value =="
mkdir -p "$TMP/leak"
cp "$ROOT"/examples/sample-system-map/*.md "$TMP/leak/"
printf '\nAPI_TOKEN=notarealvaluebutshapedlikeone\n' >> "$TMP/leak/SECURITY.md"
if bash "$ROOT/scripts/validate-system-map.sh" "$TMP/leak" >/dev/null 2>&1; then
  bad "validator accepted an assigned credential value"
else
  ok "validator rejects an assigned credential value"
fi

echo
echo "== inventory scripts run read-only and do not error out =="
for s in inventory-host.sh inventory-services.sh inventory-ports.sh check-public-exposure.sh; do
  if timeout 60 bash "$ROOT/scripts/$s" >"$TMP/$s.out" 2>&1; then
    ok "runs: $s"
  else
    # A non-zero exit is acceptable only if the script still produced a report.
    if [ -s "$TMP/$s.out" ]; then
      ok "runs with partial evidence: $s"
    else
      bad "produced no output: $s"
    fi
  fi
done

echo
echo "== empty listener sections say 'none' rather than printing blank =="
# Regression: `tail -n +2` exits 0 on empty input, so an `|| echo none`
# fallback never fires and the section rendered as a blank gap.
ports_out="$TMP/inventory-ports.sh.out"
if [ -f "$ports_out" ]; then
  for heading in "loopback" "wildcard" "specific non-loopback"; do
    body="$(awk -v h="$heading" '
      index($0, h) && /^---/ { grab = 1; next }
      grab && /^---/         { exit }
      grab && /^==/          { exit }
      grab                   { print }
    ' "$ports_out" | tr -d '[:space:]')"
    if [ -n "$body" ]; then
      ok "section '$heading' is non-empty"
    else
      bad "section '$heading' rendered blank (should say 'none')"
    fi
  done
else
  bad "inventory-ports.sh output not captured"
fi

echo
echo "== scripts do not print secret material =="
# The scripts must not emit anything that looks like a credential, even when
# run on a host that has them.
for s in inventory-host.sh inventory-services.sh inventory-ports.sh check-public-exposure.sh; do
  if grep -qiE 'BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{20,}\.' "$TMP/$s.out" 2>/dev/null; then
    bad "possible secret material in output of $s"
  else
    ok "no secret material: $s"
  fi
done

echo
echo "== scripts contain no environment-dumping commands =="
for f in "$ROOT"/scripts/*.sh; do
  if grep -qE '(^|[^a-zA-Z-])(printenv|set -o posix.*export)([^a-zA-Z-]|$)' "$f" 2>/dev/null; then
    bad "environment dump found in $(basename "$f")"
  elif grep -qE 'docker inspect.*Env|cat .*\.env' "$f" 2>/dev/null; then
    bad "reads environment values in $(basename "$f")"
  else
    ok "no environment dump: $(basename "$f")"
  fi
done

echo
echo "== home exposure check (fixture suite) =="
if bash "$ROOT/tests/test-home-exposure.sh" >"$TMP/home-exposure.out" 2>&1; then
  ok "tests/test-home-exposure.sh ($(grep -E '^passed:' "$TMP/home-exposure.out"))"
else
  bad "tests/test-home-exposure.sh"
  grep -E 'FAIL' "$TMP/home-exposure.out" | sed 's/^/       /'
fi

echo
echo "================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "TESTS: FAIL"
  exit 1
fi
echo "TESTS: PASS"
exit 0
