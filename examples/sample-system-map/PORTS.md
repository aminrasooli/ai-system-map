# PORTS.md — listeners and exposure

> Canonical owner: which ports are in use, who owns them, and how reachable
> they are.
>
> This is a FICTIONAL example. Every value here is invented.

Last verified: 2026-01-15

## Exposure classifications

| Value | Meaning |
|---|---|
| LOCAL_ONLY | Loopback bind, and nothing forwards to it |
| LAN | Reachable from the local network segment |
| PRIVATE_OVERLAY | Reachable only over a private overlay or mesh network |
| PUBLIC_VIA_PROXY | Reachable from the internet via a reverse proxy or tunnel |
| DIRECT_PUBLIC | Bound to a public interface, reachable directly |
| UNKNOWN | Not yet determined — treat as potentially public |

## Listeners

| Port | Proto | Bind address | Owner service | Exposure | Public route | Auth |
|---|---|---|---|---|---|---|
| 8080 | tcp | 127.0.0.1 | example-web.service | PUBLIC_VIA_PROXY | app.example.com | Session login, rate limited |
| 8081 | tcp | 127.0.0.1 | example-api.service | PRIVATE_OVERLAY | api.example.com | Token, overlay only |
| 3000 | tcp | 127.0.0.1 | local-dashboard.service | LOCAL_ONLY | n/a | none |
| 22 | tcp | overlay interface | openssh-server | PRIVATE_OVERLAY | n/a | Public key only |

Note how the first three all bind to `127.0.0.1` and yet have three different
classifications. The bind address did not determine the answer; the routing
in front of it did.

## A bind address is not a classification

> **A process bound to `127.0.0.1` may still be reachable from the internet.**

Port 8080 above is the worked example. The socket is loopback-only, so a
casual look at the listener list suggests it is private. It is not: the
tunnel client on this host accepts public traffic for `app.example.com` and
forwards it to `127.0.0.1:8080`. Host firewall rules do not intervene,
because the connection arrives locally from the tunnel process.

Before writing LOCAL_ONLY, confirm no proxy or tunnel forwards to that port.
If you cannot confirm it, write UNKNOWN.

## Public ingress

| Public route | Edge mechanism | Local destination | Edge auth | Notes |
|---|---|---|---|---|
| app.example.com | Outbound tunnel client | 127.0.0.1:8080 | none at edge | Application handles its own login |

Everything not listed above has no path in from the internet. There is
exactly one public ingress on this host.

## Firewall

| Field | Value |
|---|---|
| Firewall | ufw |
| Enabled | yes |
| Default incoming policy | deny |
| Rules readable without elevation? | no |

The rule list requires elevation. It was read once during setup, with
elevation, and confirmed to permit only overlay-interface traffic. If a
future check cannot read the rules, record UNKNOWN rather than copying this
line forward.

## Reserved and avoided ports

| Port | Reserved for | Notes |
|---|---|---|
| 8082 | Planned second API instance | Keep free for a blue/green rollout |
| 5432 | Not in use | Avoided so a future database is not mistaken for an existing one |
