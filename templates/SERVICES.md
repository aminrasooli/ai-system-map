# SERVICES.md — supervised services

> Canonical owner: what runs under a supervisor, and from which source.
> Port exposure lives in [PORTS.md](PORTS.md), not here.

Last verified: `<YYYY-MM-DD>`

## Services

| Service | Supervisor | Runs | Source tree | Local bind | Environment |
|---|---|---|---|---|---|
| `<example-web.service>` | `<systemd>` | `<command or entrypoint>` | `<path>` | `<127.0.0.1:PORT>` | `<dev / staging / prod>` |

Notes on the columns:

- **Runs** — the actual entrypoint, not a description. An agent should be able
  to identify the process from this.
- **Source tree** — where the code lives. If a service runs from a build
  artifact rather than a working tree, say so; it changes how a deploy works.
- **Local bind** — address and port as configured. Whether that is reachable
  from anywhere is a separate question, answered in `PORTS.md`.

## Restart and reload

| Service | Restart command | Safe to restart unattended? | Notes |
|---|---|---|---|
| `<example-web.service>` | `<sudo systemctl restart example-web>` | `<yes / no>` | `<downtime, dependencies, warmup>` |

## Deployment model

For each service, how does new code actually reach the running process?

| Service | Deploy method | Picks up changes on | Notes |
|---|---|---|---|
| `<example-web.service>` | `<pull + restart / rebuild image / rsync>` | `<restart / reload / automatically>` | `<>` |

> A long-running process keeps the code it started with. Committing a change
> does not deploy it. Record here what actually causes new code to be loaded,
> because this is a frequent source of "the fix is in but the bug is live".

## Dependencies

| Service | Depends on | Failure behaviour |
|---|---|---|
| `<example-api.service>` | `<database, message queue, external API>` | `<fails closed / degrades / retries>` |

## Scheduled work

| Timer or job | Runs | Schedule | Owner |
|---|---|---|---|
| `<example-backup.timer>` | `<what it does>` | `<when>` | `<service or script>` |

## Not supervised

Processes that matter but are not under a supervisor — started by hand, run
in a terminal multiplexer, or launched at login. These are the ones that
disappear after a reboot and surprise everyone.

| Process | Started by | Survives reboot? | Should it be supervised? |
|---|---|---|---|
| `<name>` | `<how>` | `<no>` | `<yes / no, and why>` |
