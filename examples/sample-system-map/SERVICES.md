# SERVICES.md — supervised services

> Canonical owner: what runs under a supervisor, and from which source.
> Port exposure lives in [PORTS.md](PORTS.md), not here.
>
> This is a FICTIONAL example. Every value here is invented.

Last verified: 2026-01-15

## Services

| Service | Supervisor | Runs | Source tree | Local bind | Environment |
|---|---|---|---|---|---|
| example-web.service | systemd | `gunicorn web.app:app` | `/home/developer/services/example-web` | 127.0.0.1:8080 | prod |
| example-api.service | systemd | `uvicorn api.main:app` | `/home/developer/services/example-api` | 127.0.0.1:8081 | prod |
| local-dashboard.service | systemd | `node server.js` | `/home/developer/services/local-dashboard` | 127.0.0.1:3000 | dev |

Notes on the columns:

- **Runs** — the actual entrypoint, not a description.
- **Source tree** — where the code lives.
- **Local bind** — address and port as configured. Reachability is a separate
  question, answered in `PORTS.md`.

## Restart and reload

| Service | Restart command | Safe to restart unattended? | Notes |
|---|---|---|---|
| example-web.service | `sudo systemctl restart example-web` | yes | Roughly two seconds of downtime |
| example-api.service | `sudo systemctl restart example-api` | no | example-web returns errors while it is down; restart it first |
| local-dashboard.service | `sudo systemctl restart local-dashboard` | yes | No dependants |

## Deployment model

| Service | Deploy method | Picks up changes on | Notes |
|---|---|---|---|
| example-web.service | git pull, then restart | restart | Templates are cached at startup |
| example-api.service | git pull, then restart | restart | No auto-reload in production |
| local-dashboard.service | git pull, then restart | restart | Runs a watcher in dev, not here |

> A long-running process keeps the code it started with. Committing a change
> does not deploy it. None of these services reload automatically, so a
> restart is always required for new code to take effect.

## Dependencies

| Service | Depends on | Failure behaviour |
|---|---|---|
| example-web.service | example-api.service | Returns a 503 page; does not crash |
| example-api.service | local SQLite database file | Fails closed at startup |
| local-dashboard.service | example-api.service | Shows stale cached data |

## Scheduled work

| Timer or job | Runs | Schedule | Owner |
|---|---|---|---|
| example-backup.timer | Encrypted backup upload | Daily, early morning | example-backup.service |
| example-cert-renew.timer | Certificate renewal check | Twice daily | example-cert-renew.service |

## Not supervised

| Process | Started by | Survives reboot? | Should it be supervised? |
|---|---|---|---|
| Ad-hoc data import script | Run by hand in a terminal multiplexer | no | No — it is intentionally manual and rare |
