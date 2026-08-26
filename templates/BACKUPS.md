# BACKUPS.md — coverage

> Canonical owner: what is protected, by what, on what schedule, and what is
> deliberately not protected.
>
> Recovery *procedure* lives in [RESTORE.md](RESTORE.md).

Last verified: `<YYYY-MM-DD>`

## Summary

| Field | Value |
|---|---|
| Backup tool | `<name>` |
| Destination type | `<object storage / external disk / remote host>` |
| Encrypted before leaving the machine? | `<yes / no>` |
| Schedule | `<how often>` |
| Triggered by | `<timer / cron / manual>` |
| Last verified restore | `<YYYY-MM-DD, or NEVER>` |

> Credentials for the backup destination are recorded in
> [SECURITY.md](SECURITY.md) by name and location only. Never here, never
> anywhere, as a value.

## What is covered

| Path | Contains | Frequency | Notes |
|---|---|---|---|
| `<~/projects>` | `<source trees and working state>` | `<schedule>` | `<>` |
| `<~/services>` | `<deployed application data>` | `<schedule>` | `<>` |
| `</etc>` | `<system configuration>` | `<schedule>` | `<>` |

## What is NOT covered

This is the more important table. Anything not listed above is unprotected,
but listing it explicitly is what makes that a decision rather than an
oversight.

| Path or data | Why not covered | Recoverable another way? |
|---|---|---|
| `<container images>` | `<rebuildable from definition>` | `<yes — rebuild>` |
| `<package caches>` | `<reproducible>` | `<yes — reinstall>` |
| `<path>` | `<reason>` | `<no — accepted loss>` |

Anything answered "no" is accepted data loss. Make sure that is intentional.

## Recovery objectives

| Objective | Target | Actual | Notes |
|---|---|---|---|
| Recovery point (how much data may be lost) | `<e.g. 24h>` | `<measured>` | `<>` |
| Recovery time (how long to get back) | `<e.g. 4h>` | `<measured or UNTESTED>` | `<>` |

## Work in progress

Uncommitted or unpushed work is the most commonly lost category, because it
falls between "in version control" and "in the backup window".

| Location | Protected by | Exposure window |
|---|---|---|
| `<uncommitted working trees>` | `<filesystem backup>` | `<time since last run>` |
| `<committed but unpushed>` | `<filesystem backup>` | `<time since last run>` |

## Dependencies

What the backup itself relies on. If recovery requires something that only
exists on the machine being recovered, recovery will fail when it matters.

| Dependency | Where it lives | Available during a bare-metal recovery? |
|---|---|---|
| `<backup repository credential>` | `<password manager>` | `<yes>` |
| `<encryption passphrase>` | `<password manager>` | `<yes>` |
| `<the restore procedure itself>` | `<this repository>` | `<yes / no>` |

> If any dependency is stored **only** on this machine, recovery is not
> proven. Move it somewhere independent.

## Verification history

| Date | What was restored | Result | Notes |
|---|---|---|---|
| `<YYYY-MM-DD>` | `<scope>` | `<success / failure>` | `<>` |

A backup that has never been restored is a hypothesis, not a backup.
