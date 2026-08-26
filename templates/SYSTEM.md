# SYSTEM.md — canonical machine map

> Canonical owner: machine purpose, environment, layout, project index.
> Other documents may reference these facts; none may redefine them.

Last verified: `<YYYY-MM-DD>`

## Purpose

`<One paragraph: what this machine is for. Who depends on it. What breaking
it would cost.>`

## Identity

| Field | Value |
|---|---|
| Host name | `<hostname>` |
| Role | `<workstation / server / build host / mixed>` |
| Operating system | `<distribution and version>` |
| Primary user | `<username>` |
| Always on? | `<yes / no>` |
| Physical location | `<office / rack / cloud region — coarse only>` |

## Environment

| Field | Value |
|---|---|
| Package manager | `<apt / dnf / pacman / ...>` |
| Container runtime | `<none / docker / podman>` |
| Service supervisor | `<systemd / other>` |
| Overlay network | `<none / name of mesh or VPN>` |
| Reverse proxy or tunnel | `<none / name>` |

## Directory layout

Only the directories an agent needs in order to act correctly.

| Path | Contains | Notes |
|---|---|---|
| `<~/projects>` | `<active work>` | `<canonical location for new work>` |
| `<~/services>` | `<deployed application trees>` | `<>` |
| `<~/backups>` | `<local backup staging>` | `<>` |

## Project index

| Project | Path | Status | Deployed as | Public? |
|---|---|---|---|---|
| `<name>` | `<path>` | `<active / paused / archived>` | `<service name or "not deployed">` | `<yes / no>` |

## Operational ownership

Who or what is allowed to change this machine.

| Actor | Scope | May change infrastructure? |
|---|---|---|
| `<human operator>` | `<full>` | `<yes>` |
| `<automation or agent>` | `<paths or concerns it owns>` | `<yes / no / with approval>` |

## Standing constraints

Decisions that are deliberate and must not be "helpfully" undone. Record the
reason, or the next reader will assume it was an accident.

| Constraint | Reason | How to revert if ever needed |
|---|---|---|
| `<e.g. service X is loopback-only>` | `<why>` | `<how>` |

## Pointers

- Services: [SERVICES.md](SERVICES.md)
- Ports and exposure: [PORTS.md](PORTS.md)
- Controls and credentials: [SECURITY.md](SECURITY.md)
- Backup coverage: [BACKUPS.md](BACKUPS.md)
- Recovery procedure: [RESTORE.md](RESTORE.md)
