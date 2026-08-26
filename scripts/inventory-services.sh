#!/usr/bin/env bash
# inventory-services.sh — read-only service inventory.
#
# Lists supervised services and, where readable, what they run and from where.
# Deliberately omits Environment= and EnvironmentFile= VALUES: unit files
# routinely carry credentials inline. Variable names are shown, values are not.

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n== %s ==\n' "$1"; }

echo "AI System Map — service inventory"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Read-only. Environment values are never printed."

if ! have systemctl; then
  section "SUPERVISOR"
  echo "UNKNOWN — systemctl not available; this script covers systemd only."
  echo "Record supervised processes in SERVICES.md by hand."
  exit 0
fi

if ! systemctl list-units --type=service --no-pager >/dev/null 2>&1; then
  section "SUPERVISOR"
  echo "UNKNOWN — cannot query systemd from this context."
  echo "Re-run from a session with access to the system bus."
  exit 0
fi

section "RUNNING SERVICES (system scope)"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | awk '{printf "%-45s %s\n", $1, $4}' | head -60

section "ENABLED SERVICES (start at boot)"
systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null \
  | awk '{printf "%-45s %s\n", $1, $2}' | head -60

section "FAILED SERVICES"
failed="$(systemctl list-units --type=service --state=failed --no-pager --no-legend 2>/dev/null)"
if [ -n "$failed" ]; then
  printf '%s\n' "$failed" | awk '{printf "%-45s %s\n", $1, $4}'
else
  echo "none"
fi

section "USER SERVICES"
if systemctl --user list-units --type=service --state=running --no-pager >/dev/null 2>&1; then
  systemctl --user list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
    | awk '{printf "%-45s %s\n", $1, $4}' | head -30
else
  echo "UNKNOWN — no reachable user bus in this context"
fi

section "SERVICE DETAIL (start time, source, entrypoint)"
echo "For each service you care about, run:"
echo
echo "  systemctl show <unit> -p ExecMainStartTimestamp -p FragmentPath \\"
echo "                        -p WorkingDirectory -p ExecStart"
echo
echo "ExecMainStartTimestamp is the one people forget. A service started"
echo "before its source tree was last updated is running the older code:"
echo "committed is not the same as deployed."
echo
echo "Sample for currently running units (names and start times only):"
echo
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | awk '{print $1}' | head -15 | while read -r unit; do
      ts="$(systemctl show "$unit" -p ExecMainStartTimestamp --value 2>/dev/null)"
      [ -n "$ts" ] || ts="UNKNOWN"
      printf '%-45s %s\n' "$unit" "$ts"
    done

section "TIMERS"
if systemctl list-timers --all --no-pager >/dev/null 2>&1; then
  systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | awk '{printf "%-40s next: %s %s\n", $NF, $1, $2}' | head -20
else
  echo "UNKNOWN"
fi

section "NEXT STEPS"
cat <<'EOF'
Record in SERVICES.md:
  - one row per supervised service: supervisor, entrypoint, source tree,
    local bind, environment
  - how new code actually reaches each running process
  - anything important that is NOT supervised

Values from Environment= / EnvironmentFile= are intentionally not shown here.
Record variable NAMES in SECURITY.md; never record values anywhere.
EOF
