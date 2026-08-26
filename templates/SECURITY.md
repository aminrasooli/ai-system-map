# SECURITY.md — controls and boundaries

> Canonical owner: which controls exist, where credentials live, and what the
> trust boundaries are.
>
> **This document never contains a credential value.** Names, paths, and
> presence only. If you are tempted to paste a value here, the answer is no.

Last verified: `<YYYY-MM-DD>`

## Existing controls

The point of this table is so that an agent — or a person — can discover that
a concern is already handled, instead of adding a second mechanism beside the
first.

| Concern | Control | Where it lives | Covers | Does not cover |
|---|---|---|---|---|
| `<inbound network>` | `<host firewall>` | `<config path>` | `<what it protects>` | `<known gap>` |
| `<public ingress auth>` | `<identity proxy>` | `<where configured>` | `<which routes>` | `<which routes not>` |
| `<secret detection>` | `<pre-commit scan>` | `<hook path>` | `<staged content>` | `<already-committed history>` |

State the gaps honestly. A control described as covering more than it does is
worse than no control, because it stops people looking.

## Trust boundaries

| Boundary | What is inside | What is outside | Enforced by |
|---|---|---|---|
| `<host>` | `<local processes>` | `<internet>` | `<firewall + proxy>` |
| `<service account>` | `<its own data>` | `<other services' data>` | `<filesystem permissions>` |

## Credential inventory

Locations and variable names only. No values, no fragments, no hashes.

| What | Location | Form | Used by | Rotation |
|---|---|---|---|---|
| `<application API key>` | `<path to env file>` | `<environment variable NAME>` | `<service>` | `<manual / scheduled / never>` |
| `<SSH keys>` | `<~/.ssh/>` | `<key files>` | `<operator access>` | `<>` |

Directories that hold credential material and should not be read casually by
tooling or agents:

- `<path>` — `<what lives there>`

## Authentication surfaces

Anywhere a credential is accepted.

| Surface | Reachable from | Auth method | Rate limited? | Notes |
|---|---|---|---|---|
| `<app login>` | `<internet via proxy>` | `<password + session cookie>` | `<yes / no>` | `<>` |
| `<SSH>` | `<overlay network only>` | `<public key>` | `<n/a>` | `<>` |

## Logging and diagnostics

Diagnostic logging is a recurring source of accidental credential exposure —
a "safe" debug line that prints a key prefix or a token length is still
leaking material about a secret.

| Field | Value |
|---|---|
| Log destination | `<journal / files / remote>` | 
| Readable by | `<which users>` |
| Known sensitive logging | `<none / describe>` |

Policy: log credential **presence**, never any part of the value, and never
its length.

## Known accepted risks

Things that are deliberately not fixed, with the reasoning. Without this
section, someone will eventually "fix" them and break something.

| Risk | Why accepted | Revisit when |
|---|---|---|
| `<description>` | `<reason>` | `<condition>` |

## Out of scope

`<What this machine deliberately does not defend against, e.g. physical
access, a compromised upstream package.>`
