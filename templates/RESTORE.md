# RESTORE.md — recovery procedure

> Canonical owner: how to get this machine, or its data, back.
>
> Coverage lives in [BACKUPS.md](BACKUPS.md). This document is the runbook.

Last verified: `<YYYY-MM-DD>`

## Status

| Field | Value |
|---|---|
| Procedure status | `<TESTED / DESIGNED-NOT-TESTED>` |
| Last successful test | `<YYYY-MM-DD, or NEVER>` |
| Tested from | `<this machine / an independent machine>` |
| Tested by | `<role>` |

> A procedure tested only on the machine it is meant to recover has not been
> tested. The interesting failure is the one where the machine is gone.

## Before you start

What you need in hand. If any of these live only on the machine being
recovered, the procedure is broken.

| Requirement | Where it comes from | Held independently? |
|---|---|---|
| `<backup repository location>` | `<documented here>` | `<yes>` |
| `<repository credential>` | `<password manager>` | `<yes>` |
| `<encryption passphrase>` | `<password manager>` | `<yes>` |
| `<this runbook>` | `<private repository>` | `<yes / no>` |

## Scenario 1 — single file or directory

`<Steps to restore a specific path from the most recent backup.>`

```bash
# <example command, using the tool named in BACKUPS.md>
```

Verify: `<how to confirm the restored data is correct>`

## Scenario 2 — a service and its data

1. `<Stop the service.>`
2. `<Restore its data directory.>`
3. `<Check ownership and permissions.>`
4. `<Start the service.>`
5. `<Verify it is healthy.>`

Verify: `<a concrete check, not "looks fine">`

## Scenario 3 — full machine rebuild

Order matters. Record it, because it is not obvious under pressure.

1. `<Install the base operating system.>`
2. `<Install the backup tool.>`
3. `<Provide the repository credential from the password manager.>`
4. `<Restore system configuration.>`
5. `<Restore user data.>`
6. `<Reinstall packages.>`
7. `<Re-establish the service supervisor units.>`
8. `<Restore or re-issue credentials — list which must be re-issued rather
   than restored.>`
9. `<Verify each service against SERVICES.md and PORTS.md.>`

## Must be re-issued, not restored

Some things cannot be recovered from a backup and must be created again.
Knowing this in advance prevents a stalled recovery.

| Item | Why | How to re-issue |
|---|---|---|
| `<host keys>` | `<identity, not data>` | `<regenerate>` |
| `<tokens bound to the old host>` | `<>` | `<reissue from provider>` |

## Post-recovery checklist

- [ ] Every service in `SERVICES.md` is running
- [ ] Every listener matches `PORTS.md`, including exposure classification
- [ ] No listener is exposed more broadly than intended
- [ ] Controls in `SECURITY.md` are back in place
- [ ] A fresh backup has been taken and verified
- [ ] `<any machine-specific check>`

## Known gaps

| Gap | Impact | Mitigation |
|---|---|---|
| `<what this procedure does not cover>` | `<consequence>` | `<workaround>` |

## Test log

| Date | Scenario | Result | Notes |
|---|---|---|---|
| `<YYYY-MM-DD>` | `<which scenario>` | `<success / failure>` | `<what was learned>` |
