#!/usr/bin/env bash
# validate-system-map.sh — structural checks for a filled-in System Map.
#
# Usage: validate-system-map.sh [path-to-map-directory]
#
# Checks that the map is structurally honest: documents present, headings
# present, placeholders resolved, exposure values valid, cross-references
# consistent, recovery status declared.
#
# It NEVER edits your files. It exits non-zero if anything fails.
# It is deliberately not a policy engine.

set -uo pipefail

MAP_DIR="${1:-.}"

PASS=0
FAIL=0
WARN=0

ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  warn  %s\n' "$1"; WARN=$((WARN + 1)); }

echo "AI System Map — validator"
echo "Map directory: $MAP_DIR"

if [ ! -d "$MAP_DIR" ]; then
  echo "FAIL: not a directory: $MAP_DIR"
  exit 2
fi

REQUIRED_DOCS="SYSTEM.md SERVICES.md PORTS.md SECURITY.md BACKUPS.md RESTORE.md"

echo
echo "== required documents =="
for doc in $REQUIRED_DOCS; do
  if [ -f "$MAP_DIR/$doc" ]; then
    ok "$doc present"
  else
    bad "$doc missing"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "RESULT: FAIL — required documents are missing; stopping here."
  exit 1
fi

echo
echo "== required headings =="
check_heading() { # $1 file, $2 heading regex, $3 label
  if grep -qiE "$2" "$MAP_DIR/$1" 2>/dev/null; then
    ok "$1: $3"
  else
    bad "$1: missing $3"
  fi
}
check_heading "SYSTEM.md"   '^##[[:space:]]+Purpose'          "Purpose section"
check_heading "SERVICES.md" '^##[[:space:]]+Services'          "Services section"
check_heading "PORTS.md"    '^##[[:space:]]+Listeners'         "Listeners section"
check_heading "SECURITY.md" '^##[[:space:]]+(Existing )?[Cc]ontrols' "Controls section"
check_heading "BACKUPS.md"  '^##[[:space:]]+(What is )?[Cc]overed|^##[[:space:]]+Summary' "coverage section"
check_heading "RESTORE.md"  '^##[[:space:]]+Status'            "Status section"

echo
echo "== unresolved placeholders =="
# A placeholder is <something> left from the templates.
for doc in $REQUIRED_DOCS; do
  n="$(grep -cE '<[A-Za-z0-9 ._/~-][^>]*>' "$MAP_DIR/$doc" 2>/dev/null || true)"
  n="${n:-0}"
  if [ "$n" -eq 0 ]; then
    ok "$doc: no unresolved placeholders"
  else
    bad "$doc: $n unresolved placeholder(s) remain"
  fi
done

echo
echo "== exposure classifications =="
VALID_EXPOSURE="LOCAL_ONLY LAN PRIVATE_OVERLAY PUBLIC_VIA_PROXY DIRECT_PUBLIC UNKNOWN"

# Only the data rows of the Listeners table are checked. Scanning the whole
# document would also hit the classification legend and any prose, which is
# how a naive check ends up flagging its own documentation.
listener_rows() {
  awk '
    /^##[[:space:]]+Listeners/ { inside = 1; next }
    /^##[[:space:]]/           { inside = 0 }
    inside && /^\|/            { print }
  ' "$MAP_DIR/PORTS.md" 2>/dev/null \
    | grep -vE '^\|[[:space:]]*-|^\|[[:space:]]*Port[[:space:]]*\|'
}

found_exposure=0
unknown_count=0
row_count=0

while IFS= read -r row; do
  [ -n "$row" ] || continue
  row_count=$((row_count + 1))
  # Pull the token that looks like an exposure value from this row.
  tok="$(printf '%s\n' "$row" | grep -oE '\b[A-Z][A-Z_]{2,}\b' | head -1)"
  if [ -z "$tok" ]; then
    bad "PORTS.md: listener row has no exposure classification: $(printf '%s' "$row" | cut -c1-50)"
    continue
  fi
  case " $VALID_EXPOSURE " in
    *" $tok "*)
      found_exposure=1
      [ "$tok" = "UNKNOWN" ] && unknown_count=$((unknown_count + 1))
      ;;
    *)
      bad "PORTS.md: unsupported exposure value '$tok'"
      ;;
  esac
done <<EOF
$(listener_rows)
EOF

if [ "$row_count" -eq 0 ]; then
  bad "PORTS.md: no listener rows found under '## Listeners'"
elif [ "$found_exposure" -eq 1 ]; then
  ok "PORTS.md: $row_count listener row(s), all exposure values supported"
else
  bad "PORTS.md: no valid exposure classification found"
fi

if [ "$unknown_count" -gt 0 ]; then
  warn "PORTS.md: $unknown_count listener(s) classified UNKNOWN — treat as potentially public"
fi

echo
echo "== cross-references =="
# Every service named in PORTS.md should appear in SERVICES.md.
missing_refs=0
while read -r svc; do
  [ -n "$svc" ] || continue
  if grep -qF "$svc" "$MAP_DIR/SERVICES.md" 2>/dev/null; then
    :
  else
    bad "PORTS.md references '$svc' which is not in SERVICES.md"
    missing_refs=$((missing_refs + 1))
  fi
done <<EOF
$(grep -oE '\b[a-z0-9][a-z0-9._-]*\.service\b' "$MAP_DIR/PORTS.md" 2>/dev/null | sort -u)
EOF
[ "$missing_refs" -eq 0 ] && ok "all services referenced in PORTS.md exist in SERVICES.md"

echo
echo "== recovery declarations =="
# Read the declared status from the Status table row, not from prose
# elsewhere in the document.
restore_status="$(awk -F'|' '
  /^\|[[:space:]]*Procedure status[[:space:]]*\|/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3; exit }
' "$MAP_DIR/RESTORE.md" 2>/dev/null)"

if [ -n "$restore_status" ]; then
  ok "RESTORE.md declares a procedure status: $restore_status"
  case "$restore_status" in
    *NOT-TESTED*|*UNTESTED*|*NEVER*)
      warn "RESTORE.md: recovery is unverified — an untested backup is a hypothesis" ;;
  esac
else
  bad "RESTORE.md: no 'Procedure status' row found in the Status table"
fi

if grep -qiE 'not covered|NOT covered|accepted loss' "$MAP_DIR/BACKUPS.md" 2>/dev/null; then
  ok "BACKUPS.md declares what is not covered"
else
  bad "BACKUPS.md: no statement of what is NOT covered"
fi

echo
echo "== obvious secret material =="
# Structural safety net only. This is not a secret scanner; use a dedicated
# tool for that. It catches the careless paste.
secret_hits=0
for doc in $REQUIRED_DOCS; do
  if grep -qE 'BEGIN [A-Z ]*PRIVATE KEY' "$MAP_DIR/$doc" 2>/dev/null; then
    bad "$doc: contains a private key block"
    secret_hits=$((secret_hits + 1))
  fi
  if grep -qiE '^[[:space:]]*[A-Z_]*(PASSWORD|SECRET|TOKEN|API_KEY)[A-Z_]*[[:space:]]*=[[:space:]]*[^<[:space:]]' \
      "$MAP_DIR/$doc" 2>/dev/null; then
    bad "$doc: looks like an assigned credential value (names only, never values)"
    secret_hits=$((secret_hits + 1))
  fi
done
[ "$secret_hits" -eq 0 ] && ok "no obvious credential values found"

echo
echo "================================"
printf 'passed: %d   warnings: %d   failed: %d\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "SYSTEM MAP: INVALID"
  exit 1
fi
echo "SYSTEM MAP: VALID"
exit 0
