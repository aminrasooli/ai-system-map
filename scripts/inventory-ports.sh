#!/usr/bin/env bash
# inventory-ports.sh — read-only listener inventory.
#
# Lists listening sockets and groups them by bind scope. Bind scope is
# evidence, NOT a final exposure classification: see check-public-exposure.sh
# and PORTS.md for why a loopback bind can still be internet-reachable.

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s ==\n' "$1"; }

echo "AI System Map — port inventory"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Read-only. Bind scope is evidence, not a classification."

LISTEN_RAW=""
if have ss; then
  LISTEN_RAW="$(ss -tlnp 2>/dev/null || ss -tln 2>/dev/null)"
  SRC="ss"
elif have netstat; then
  LISTEN_RAW="$(netstat -tlnp 2>/dev/null || netstat -tln 2>/dev/null)"
  SRC="netstat"
else
  section "LISTENERS"
  echo "UNKNOWN — neither ss nor netstat is available."
  exit 0
fi

if [ -z "$LISTEN_RAW" ]; then
  section "LISTENERS"
  echo "UNKNOWN — could not read listening sockets in this context."
  exit 0
fi

section "ALL TCP LISTENERS (source: $SRC)"
printf '%s\n' "$LISTEN_RAW"
echo
echo "note: process names appear only if this user may see them."
echo "      Missing process detail is UNKNOWN, not 'no process'."

section "GROUPED BY BIND SCOPE"

echo "--- loopback (127.0.0.0/8, ::1) ---"
printf '%s\n' "$LISTEN_RAW" \
  | grep -E '(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\])' || echo "  none"

echo
echo "--- wildcard (0.0.0.0, [::]) — reachable on every interface ---"
printf '%s\n' "$LISTEN_RAW" \
  | grep -E '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):' || echo "  none"

echo
echo "--- specific non-loopback addresses ---"
# tail -n +2 drops the header row and still exits 0 on empty input, so the
# emptiness has to be tested rather than inferred from the exit status.
specific="$(printf '%s\n' "$LISTEN_RAW" \
  | grep -vE '(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]|0\.0\.0\.0|\*:|\[::\]:)' \
  | tail -n +2)"
if [ -n "$(printf '%s' "$specific" | tr -d '[:space:]')" ]; then
  printf '%s\n' "$specific"
else
  echo "  none"
fi

section "UDP LISTENERS"
if have ss; then
  ss -ulnp 2>/dev/null || ss -uln 2>/dev/null || echo "UNKNOWN"
else
  netstat -ulnp 2>/dev/null || netstat -uln 2>/dev/null || echo "UNKNOWN"
fi

section "CONTAINER PUBLISHED PORTS"
if have docker; then
  if docker info >/dev/null 2>&1; then
    out="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      echo
      echo "note: published container ports may bypass the host firewall,"
      echo "      depending on runtime and network configuration. Verify"
      echo "      rather than assuming the firewall covers them."
    else
      echo "no running containers"
    fi
  else
    echo "UNKNOWN — docker present but daemon not reachable by this user"
  fi
else
  echo "docker absent"
fi

section "INTERPRETATION"
cat <<'EOF'
Bind scope maps to a FIRST GUESS only:

  loopback   -> LOCAL_ONLY *if* nothing forwards to it
  wildcard   -> LAN or DIRECT_PUBLIC, depending on the firewall
  specific   -> depends on which interface the address belongs to

None of these is final. A loopback listener fronted by a reverse proxy or a
tunnel is PUBLIC_VIA_PROXY, and that is invisible here.

Run scripts/check-public-exposure.sh next, then record one classification per
listener in PORTS.md. Where you cannot confirm, record UNKNOWN.
EOF
