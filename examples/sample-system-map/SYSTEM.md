# SYSTEM.md — canonical machine map

> Canonical owner: machine purpose, environment, layout, project index.
> Other documents may reference these facts; none may redefine them.
>
> This is a FICTIONAL example. Every value here is invented.

Last verified: 2026-01-15

## Purpose

`dev-box` is a single always-on Linux host used to develop and self-host a
small set of internal web applications. One application is published to the
internet; the rest are reachable only from the team's private overlay network
or from the machine itself. If it goes down, the public marketing site is
offline and internal tooling is unavailable, but no customer data is at risk
because none is stored here.

## Identity

| Field | Value |
|---|---|
| Host name | dev-box |
| Role | Mixed workstation and self-hosting server |
| Operating system | Debian-family Linux, current stable |
| Primary user | developer |
| Always on? | yes |
| Physical location | office |

## Environment

| Field | Value |
|---|---|
| Package manager | apt |
| Container runtime | docker |
| Service supervisor | systemd |
| Overlay network | private mesh VPN |
| Reverse proxy or tunnel | outbound tunnel client |

## Directory layout

| Path | Contains | Notes |
|---|---|---|
| `/home/developer/projects` | Active source trees | Canonical location for new work |
| `/home/developer/services` | Deployed application trees | One directory per deployed service |
| `/home/developer/backups` | Local backup staging | Cleared after each successful upload |

## Project index

| Project | Path | Status | Deployed as | Public? |
|---|---|---|---|---|
| example-web | `/home/developer/services/example-web` | active | example-web.service | yes |
| example-api | `/home/developer/services/example-api` | active | example-api.service | no |
| local-dashboard | `/home/developer/services/local-dashboard` | active | local-dashboard.service | no |
| scratch-notebook | `/home/developer/projects/scratch-notebook` | paused | not deployed | no |

## Operational ownership

| Actor | Scope | May change infrastructure? |
|---|---|---|
| developer | full machine | yes |
| coding agent | `/home/developer/projects`, `/home/developer/services` | with approval |
| backup timer | `/home/developer/backups` | no — writes backups only |

## Standing constraints

| Constraint | Reason | How to revert if ever needed |
|---|---|---|
| example-api binds to loopback only | It is consumed by example-web on the same host; nothing external needs it | Change its bind address and add an ingress route |
| local-dashboard has no authentication | It is unreachable off-host by design, so auth would add friction with no benefit | Add auth before ever exposing it |
| Container ports are never published with `-p` on a public interface | Published ports can bypass host firewall rules | Publish explicitly to `127.0.0.1` only |

## Pointers

- Services: [SERVICES.md](SERVICES.md)
- Ports and exposure: [PORTS.md](PORTS.md)
- Controls and credentials: [SECURITY.md](SECURITY.md)
- Backup coverage: [BACKUPS.md](BACKUPS.md)
- Recovery procedure: [RESTORE.md](RESTORE.md)
