#!/usr/bin/env bash
# inventory-host.sh — read-only host overview.
#
# Prints basic identity and environment facts to help fill in SYSTEM.md.
# Never prints environment variable values, credentials, or file contents.
# Reports UNKNOWN rather than escalating privileges.

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  printf '\n== %s ==\n' "$1"
}

value_or_unknown() {
  # $1: a value that may be empty
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; else printf 'UNKNOWN\n'; fi
}

echo "AI System Map — host inventory"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "This report is read-only evidence. It contains no secret values."

section "IDENTITY"
printf 'hostname:      %s\n' "$(value_or_unknown "$(hostname 2>/dev/null)")"
printf 'kernel:        %s\n' "$(value_or_unknown "$(uname -sr 2>/dev/null)")"
printf 'architecture:  %s\n' "$(value_or_unknown "$(uname -m 2>/dev/null)")"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  os_name="$(. /etc/os-release && printf '%s %s' "${NAME:-}" "${VERSION:-}")"
  printf 'os:            %s\n' "$(value_or_unknown "$os_name")"
else
  printf 'os:            UNKNOWN\n'
fi

printf 'current user:  %s\n' "$(value_or_unknown "$(id -un 2>/dev/null)")"

section "UPTIME AND BOOT"
printf 'booted:        %s\n' "$(value_or_unknown "$(uptime -s 2>/dev/null)")"
printf 'uptime:        %s\n' "$(value_or_unknown "$(uptime -p 2>/dev/null)")"
echo
echo "note: a process older than a configuration file is running the older"
echo "      code. Compare service start times against deploy times."

section "ENVIRONMENT"
for tool in systemctl docker podman ufw nft iptables ss netstat; do
  if have "$tool"; then
    printf '%-12s present\n' "$tool"
  else
    printf '%-12s absent\n' "$tool"
  fi
done

section "SERVICE SUPERVISOR"
if have systemctl; then
  if systemctl --version >/dev/null 2>&1; then
    printf 'systemd:       available\n'
  else
    printf 'systemd:       present but not queryable (UNKNOWN)\n'
  fi
else
  printf 'systemd:       absent\n'
fi

section "CONTAINER RUNTIME"
if have docker; then
  if docker info >/dev/null 2>&1; then
    printf 'docker:        available\n'
    printf 'containers:    %s running\n' "$(docker ps -q 2>/dev/null | wc -l)"
  else
    printf 'docker:        present, daemon not reachable by this user (UNKNOWN)\n'
  fi
else
  printf 'docker:        absent\n'
fi

section "DISK"
if have df; then
  df -h -x tmpfs -x devtmpfs 2>/dev/null | head -20
else
  echo "UNKNOWN (df unavailable)"
fi

section "PENDING REBOOT"
if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
  echo "yes — a reboot is pending"
  echo "note: services still run their pre-reboot code until restarted."
else
  echo "no marker found (or distribution does not use one)"
fi

section "NEXT STEPS"
cat <<'EOF'
Record in SYSTEM.md:
  - machine purpose and role
  - operating environment
  - directory layout and project index
  - standing constraints and their reasons

Then run:
  scripts/inventory-services.sh
  scripts/inventory-ports.sh
  scripts/check-public-exposure.sh
EOF
