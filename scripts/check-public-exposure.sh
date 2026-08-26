#!/usr/bin/env bash
# check-public-exposure.sh — read-only public exposure evidence.
#
# Looks for the ways a service on this host can become internet-reachable,
# especially the non-obvious one: a loopback-bound process fronted by a
# reverse proxy or an outbound tunnel.
#
# This script COLLECTS EVIDENCE. It does not remediate, and it does not
# conclude on your behalf. It never prints tokens, tunnel credentials,
# container environments, .env contents, or private keys. When something is
# unreadable without elevation, it says UNKNOWN.

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s ==\n' "$1"; }

echo "AI System Map — public exposure evidence"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Read-only. No credential material is printed."

section "WILDCARD LISTENERS (directly reachable if the firewall allows)"
if have ss; then
  w="$(ss -tln 2>/dev/null | grep -E '(0\.0\.0\.0|\*|\[::\]):' || true)"
elif have netstat; then
  w="$(netstat -tln 2>/dev/null | grep -E '(0\.0\.0\.0|\*|\[::\]):' || true)"
else
  w=""
  echo "UNKNOWN — no socket tool available"
fi
if [ -n "${w:-}" ]; then
  printf '%s\n' "$w"
  echo
  echo "Each of these is DIRECT_PUBLIC unless a firewall blocks it."
else
  echo "none found"
fi

section "FIREWALL"
if have ufw; then
  if ufw status >/dev/null 2>&1; then
    ufw status verbose 2>/dev/null | head -20
  else
    echo "ufw present; rule list requires elevation -> UNKNOWN"
    if [ -r /etc/ufw/ufw.conf ]; then
      grep -E '^ENABLED' /etc/ufw/ufw.conf 2>/dev/null || true
    fi
    echo "note: do not infer a policy from unreadable rules. Record UNKNOWN."
  fi
elif have nft; then
  if nft list ruleset >/dev/null 2>&1; then
    nft list ruleset 2>/dev/null | head -30
  else
    echo "nftables present; ruleset requires elevation -> UNKNOWN"
  fi
elif have iptables; then
  if iptables -L -n >/dev/null 2>&1; then
    iptables -L -n 2>/dev/null | head -30
  else
    echo "iptables present; requires elevation -> UNKNOWN"
  fi
else
  echo "no recognised firewall tool found -> UNKNOWN"
fi

section "REVERSE PROXY / TUNNEL PROCESSES"
echo "Presence only. Configuration files are not dumped: they routinely"
echo "contain credentials."
echo
found_proxy=0
for p in nginx caddy traefik haproxy apache2 httpd envoy \
         cloudflared ngrok frpc autossh tailscaled; do
  if pgrep -x "$p" >/dev/null 2>&1; then
    printf '  %-14s RUNNING\n' "$p"
    found_proxy=1
  fi
done
[ "$found_proxy" -eq 1 ] || echo "  none of the recognised proxy/tunnel processes are running"

echo
echo "If any are running, a loopback-bound service may be PUBLIC_VIA_PROXY."
echo "Check that process's own routing configuration to map hostname ->"
echo "local port. Extract ONLY the hostname/port mapping. Do not copy"
echo "credentials, account identifiers, or tunnel secrets into your map."

section "PRIVATE OVERLAY NETWORK"
if have tailscale; then
  if tailscale status >/dev/null 2>&1; then
    echo "overlay CLI available and reporting."
    echo
    echo "Serve/Funnel state (routing metadata only):"
    if tailscale serve status >/dev/null 2>&1; then
      tailscale serve status 2>/dev/null | head -20
    else
      echo "  UNKNOWN or not configured"
    fi
    echo
    echo "note: a Funnel-style feature makes an overlay service PUBLIC."
    echo "      A plain overlay share is PRIVATE_OVERLAY. They are different"
    echo "      classifications — confirm which is in use."
  else
    echo "overlay CLI present but not queryable here -> UNKNOWN"
  fi
else
  echo "no overlay CLI found"
fi

section "CONTAINER PUBLISHED PORTS"
if have docker; then
  if docker info >/dev/null 2>&1; then
    docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || echo "none"
    echo
    echo "note: published ports can bypass host firewall rules depending on"
    echo "      runtime and network mode. Verify; do not assume coverage."
    echo "      Container environments are not inspected here by design."
  else
    echo "UNKNOWN — daemon not reachable by this user"
  fi
else
  echo "docker absent"
fi

section "HOW TO CLASSIFY"
cat <<'EOF'
For each listener, choose exactly one value for PORTS.md:

  LOCAL_ONLY       loopback bind AND no proxy/tunnel forwards to it
  LAN              reachable from the local network segment
  PRIVATE_OVERLAY  reachable only across a private overlay network
  PUBLIC_VIA_PROXY a reverse proxy or tunnel exposes it to the internet
  DIRECT_PUBLIC    bound to a public interface
  UNKNOWN          could not be determined

Rules of thumb:

  - A loopback bind alone does NOT justify LOCAL_ONLY.
  - If a proxy or tunnel is running and you cannot read its routing
    configuration, the honest answer is UNKNOWN.
  - UNKNOWN should be treated as potentially public until resolved.

This script never remediates. Changing exposure is a decision for a human or
for your own configuration management, made with the map in hand.
EOF
