# SECURITY.md — controls and boundaries

> Canonical owner: which controls exist, where credentials live, and what the
> trust boundaries are.
>
> **This document never contains a credential value.**
>
> This is a FICTIONAL example. Every value here is invented.

Last verified: 2026-01-15

## Existing controls

| Concern | Control | Where it lives | Covers | Does not cover |
|---|---|---|---|---|
| Inbound network | Host firewall, default deny | Firewall configuration | All direct inbound traffic | Traffic arriving via the tunnel, which is local |
| Public ingress | Application session login | example-web application | app.example.com | Nothing else is publicly routed |
| Brute force | Per-address rate limit on login | example-web application | Password guessing at the login route | Other routes |
| API access | Bearer token check | example-api application | All api.example.com routes | Nothing — the API is overlay-only anyway |
| Remote shell | Public-key-only SSH, overlay bound | SSH server configuration | Operator access | Physical console access |
| Secret detection | Pre-commit scan | Repository hook | Content being committed | Content already in history |

The last row is the kind of gap worth stating: the hook stops new mistakes,
it does not clean up old ones.

## Trust boundaries

| Boundary | What is inside | What is outside | Enforced by |
|---|---|---|---|
| Host | Local processes and loopback services | The internet | Firewall plus a single tunnel route |
| Overlay network | Team devices | Everything else | Mesh VPN membership |
| Service account | Each service's own data directory | Other services' data | Filesystem ownership |

## Credential inventory

Locations and variable names only. No values, no fragments, no hashes.

| What | Location | Form | Used by | Rotation |
|---|---|---|---|---|
| API bearer token | Service environment file | Environment variable name only | example-api | Manual, on demand |
| Backup repository password | Team password manager | Not stored on this host | example-backup.service | Manual |
| SSH authorised keys | `~/.ssh/` | Public key files | Operator access | On team change |
| Certificate private key | Certificate store directory | Key file, root-readable only | Tunnel client | Automatic renewal |

Directories that hold credential material and should not be read casually by
tooling or agents:

- `~/.ssh/` — operator private keys
- Service environment files — application credentials
- Certificate store directory — TLS private keys

## Authentication surfaces

| Surface | Reachable from | Auth method | Rate limited? | Notes |
|---|---|---|---|---|
| example-web login | Internet, via tunnel | Password plus session cookie | yes | The only internet-facing auth surface |
| example-api | Overlay network only | Bearer token | no | Not internet-reachable |
| SSH | Overlay network only | Public key | n/a | Password auth disabled |
| local-dashboard | Same host only | none | no | Deliberate; see standing constraints |

## Logging and diagnostics

| Field | Value |
|---|---|
| Log destination | System journal |
| Readable by | Operator and administrative group |
| Known sensitive logging | none |

Policy: log credential **presence**, never any part of the value, and never
its length. A startup line that prints a key's first characters or its length
is still leaking information about a secret, and is treated as a defect.

## Known accepted risks

| Risk | Why accepted | Revisit when |
|---|---|---|
| local-dashboard has no authentication | Unreachable off-host; adding auth would add friction with no gain | Before it is ever exposed beyond loopback |
| Single operator, no break-glass second account | One-person project; a second account is more attack surface than benefit | If a second operator joins |
| Pre-commit scan does not cover existing history | History was reviewed once at setup | If the repository is ever made public |

## Out of scope

This host does not defend against physical access to the machine, a
compromised upstream operating system package, or a malicious dependency
introduced through the normal package installation path.
