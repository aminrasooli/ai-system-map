# RESTORE.md — recovery procedure

> Canonical owner: how to get this machine, or its data, back.
>
> This is a FICTIONAL example. Every value here is invented.

Last verified: 2026-01-15

## Status

| Field | Value |
|---|---|
| Procedure status | TESTED |
| Last successful test | 2026-01-12 |
| Tested from | An independent spare machine |
| Tested by | developer |

> A procedure tested only on the machine it is meant to recover has not been
> tested. This one was run from a separate machine, using only credentials
> from the password manager.

## Before you start

| Requirement | Where it comes from | Held independently? |
|---|---|---|
| Backup repository location | BACKUPS.md | yes |
| Repository password | Team password manager | yes |
| Encryption passphrase | Team password manager | yes |
| This runbook | Private repository, plus a printed copy | yes |

## Scenario 1 — single file or directory

Restore one path from the most recent snapshot into a scratch location,
then copy what you need.

```bash
# Restore into a scratch directory rather than over live data.
# "snapshot-tool" is the backup tool named in BACKUPS.md.
snapshot-tool restore latest --target /tmp/restore-scratch \
  --include /home/developer/projects/example
```

Verify: compare the restored file against expectations before copying it into
place. Never restore directly over live data on the first attempt.

## Scenario 2 — a service and its data

1. Stop the service: `sudo systemctl stop example-api`
2. Restore its data directory into a scratch location.
3. Check ownership and permissions match the service account.
4. Move the restored data into place.
5. Start the service: `sudo systemctl start example-api`
6. Confirm it is healthy.

Verify: the API answers its health route, and example-web stops returning
503 pages.

## Scenario 3 — full machine rebuild

Order matters. It is not obvious under pressure.

1. Install the base operating system.
2. Install the backup tool.
3. Provide the repository password from the password manager.
4. Restore `/etc` to recover service unit definitions.
5. Restore `/home/developer/services` and `/home/developer/projects`.
6. Reinstall packages the applications depend on.
7. Reload the service supervisor and enable the units.
8. Re-issue the credentials listed below — these cannot be restored.
9. Verify every service against SERVICES.md and every listener against
   PORTS.md.

## Must be re-issued, not restored

| Item | Why | How to re-issue |
|---|---|---|
| SSH host keys | Machine identity, not data | Regenerate on first boot |
| Overlay network node identity | Bound to the old machine | Re-enrol the node |
| TLS certificates | Tied to the previous host identity | Request new ones after the tunnel is up |
| API bearer token | Rotated on any rebuild as a precaution | Generate and update the environment file |

## Post-recovery checklist

- [ ] Every service in SERVICES.md is running
- [ ] Every listener matches PORTS.md, including exposure classification
- [ ] No listener is exposed more broadly than intended
- [ ] Only one public ingress exists, as documented
- [ ] Controls in SECURITY.md are back in place
- [ ] A fresh backup has been taken and verified
- [ ] The overlay node appears in the mesh with the expected name

## Known gaps

| Gap | Impact | Mitigation |
|---|---|---|
| Journal history is not backed up | Past operational logs are lost on rebuild | Accepted; business data is unaffected |
| Up to 24 hours of work may be lost | Bounded by the daily schedule | Run a backup by hand before risky work |

## Test log

| Date | Scenario | Result | Notes |
|---|---|---|---|
| 2026-01-12 | Full machine rebuild, on a spare machine | success | About two hours; found that the API token had to be re-issued, now documented above |
| 2025-11-30 | Single directory restore | success | Routine spot check |
