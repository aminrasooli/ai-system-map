# PORTS.md — listeners and exposure

> Canonical owner: which ports are in use, who owns them, and how reachable
> they are.

Last verified: `<YYYY-MM-DD>`

## Exposure classifications

Every listener gets exactly one of these. They are the only permitted values.

| Value | Meaning |
|---|---|
| `LOCAL_ONLY` | Loopback bind, and nothing forwards to it |
| `LAN` | Reachable from the local network segment |
| `PRIVATE_OVERLAY` | Reachable only over a private overlay or mesh network |
| `PUBLIC_VIA_PROXY` | Reachable from the internet via a reverse proxy or tunnel |
| `DIRECT_PUBLIC` | Bound to a public interface, reachable directly |
| `UNKNOWN` | Not yet determined — treat as potentially public |

## Listeners

| Port | Proto | Bind address | Owner service | Exposure | Public route | Auth |
|---|---|---|---|---|---|---|
| `<8080>` | `<tcp>` | `<127.0.0.1>` | `<example-web.service>` | `<PUBLIC_VIA_PROXY>` | `<app.example.com>` | `<session login>` |

Columns:

- **Owner service** — must match a row in [SERVICES.md](SERVICES.md).
- **Exposure** — one of the values above, nothing else.
- **Public route** — the hostname or path traffic arrives on, if any.
  `n/a` when not publicly reachable.
- **Auth** — what stands between the internet and this service. `none` is a
  valid and important answer.

## A bind address is not a classification

> **A process bound to `127.0.0.1` may still be reachable from the internet.**

A reverse proxy or tunnel client on the same host can forward public traffic
to a loopback port. The socket looks private; the service is not. Host
firewall rules often do not help, because the connection arrives locally from
the proxy process.

Before writing `LOCAL_ONLY`, confirm that no proxy or tunnel forwards to that
port. If you cannot confirm it, write `UNKNOWN`.

The same applies to published container ports, which on some configurations
insert forwarding rules that bypass the host firewall.

## Public ingress

Every path from the internet into this machine, regardless of which port it
lands on.

| Public route | Edge mechanism | Local destination | Edge auth | Notes |
|---|---|---|---|---|
| `<app.example.com>` | `<reverse proxy / tunnel>` | `<127.0.0.1:8080>` | `<none / identity proxy>` | `<>` |

If this table is empty, say so explicitly rather than leaving it blank:
"No public ingress." An empty table is ambiguous; a statement is not.

## Firewall

| Field | Value |
|---|---|
| Firewall | `<ufw / nftables / none>` |
| Enabled | `<yes / no / UNKNOWN>` |
| Default incoming policy | `<deny / allow / UNKNOWN>` |
| Rules readable without elevation? | `<yes / no>` |

> If the rule list needs elevation and you did not read it, record `UNKNOWN`.
> Do not infer the policy from the absence of evidence.

## Reserved and avoided ports

Ports deliberately left alone, so nothing claims them by accident.

| Port | Reserved for | Notes |
|---|---|---|
| `<port>` | `<purpose>` | `<>` |
