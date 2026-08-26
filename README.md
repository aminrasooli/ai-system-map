# AI System Map

AI coding agents are moving from writing code to operating real environments.

AI System Map gives agents a canonical view of a Linux host: what is running,
what is exposed, what is protected, how recovery works, and which operational
controls already exist.

The goal is simple: let autonomous agents understand and operate a machine
without guessing about its infrastructure or repeatedly reinventing its safety
controls.

```
AI Agent
   │
   ▼
AI System Map
   ├── Services
   ├── Ports
   ├── Exposure
   ├── Recovery
   └── Operational State
   │
   ▼
Real Linux Host
```

## Why this exists

An agent asked to "deploy the API" or "lock down that port" has to answer a
lot of questions first. Which service is that? Is it already public? Is
anything else using the port? Is there a backup if this goes wrong? Is there
already a firewall rule, a reverse proxy, or a health check doing this job?

Without a canonical source, agents answer these questions by inference. That
produces three recurring failure modes:

1. **Guessing.** The agent reads a systemd unit, assumes it reflects the
   running process, and acts on a stale picture.
2. **Reinvention.** The agent adds a new guard, alert, or wrapper because it
   could not tell that an existing control already covers the concern.
3. **Accidental exposure.** The agent binds a service to `0.0.0.0`, or
   publishes a container port, without realizing what that means on this
   particular host.

A System Map is a small set of documents, kept accurate, that an agent reads
before it acts.

## What problem it solves

The map answers, in one place:

- What is this machine for, and what lives on it?
- Which services run, under which supervisor, from which source tree?
- Which ports are listening, and who owns them?
- What is reachable from the public internet, and through what path?
- What is backed up, and has recovery actually been tested?
- Which operational controls already exist, so they are not duplicated?

## Quick start

```bash
git clone https://github.com/example/ai-system-map.git
cd ai-system-map

# 1. Collect read-only evidence about the current host.
bash scripts/inventory-host.sh
bash scripts/inventory-services.sh
bash scripts/inventory-ports.sh
bash scripts/check-public-exposure.sh

# 2. Copy the templates somewhere durable and fill them in.
mkdir -p ~/system-map
cp templates/*.md ~/system-map/

# 3. Validate what you wrote.
bash scripts/validate-system-map.sh ~/system-map
```

The inventory scripts print evidence to stdout. They do not write to your
System Map for you: a human or an agent reads the evidence and records the
parts that matter, with the context a raw dump cannot supply.

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for a walkthrough.

## Example

A filled-in map for a fictional host is in
[examples/sample-system-map/](examples/sample-system-map/). It shows three
services with deliberately different exposure levels:

| Service | Local bind | Exposure | Reachable from internet? |
|---|---|---|---|
| `example-web.service` | `127.0.0.1:8080` | `PUBLIC_VIA_PROXY` | Yes — through a reverse tunnel |
| `example-api.service` | `127.0.0.1:8081` | `PRIVATE_OVERLAY` | No — overlay network only |
| `local-dashboard.service` | `127.0.0.1:3000` | `LOCAL_ONLY` | No |

Two of those bind to `127.0.0.1`. Only one is on the internet. That
distinction is the point of the map.

## Agent workflow

Give your agent one instruction:

> Before modifying infrastructure, deployment, networking, services, or
> recovery configuration, read the canonical System Map and verify current
> machine state.

Then the loop is:

```
read map → verify against live state → act → update map
```

The "verify" step matters. A map that is trusted but stale is worse than no
map. See [docs/AGENT-INTEGRATION.md](docs/AGENT-INTEGRATION.md) for how to
wire this into an agent, vendor-neutrally.

## What it intentionally does NOT do

- **It does not change your machine.** Every script here is read-only by
  default. There is no remediation mode, no auto-fix, no "apply".
- **It is not a monitoring system.** It has no daemon, no time-series
  storage, no alerting.
- **It is not a policy engine.** The validator checks that your documents are
  complete and internally consistent, not that your infrastructure is
  compliant with a standard.
- **It is not a secrets manager.** It records that a credential exists and
  where it lives. It never records the value.
- **It does not provision anything.** No cloud APIs, no Terraform, no
  Kubernetes.

## Security model

The threat this project takes seriously is its own output. A file describing
your infrastructure is useful to an attacker, so:

- Scripts never print environment variable values, `.env` contents, tunnel
  credentials, container environments, tokens, or private keys.
- When privileged data is unreadable, scripts report `UNKNOWN` rather than
  escalating to read it.
- Templates ask for credential *names and locations*, never values.
- The validator flags placeholder values left unresolved in a map.

Treat your filled-in System Map as sensitive. It belongs in a private
repository, not a public one.

See [SECURITY.md](SECURITY.md) for reporting a vulnerability.

## Roadmap

Short, deliberately:

- More exposure detectors (additional proxy and tunnel families).
- A richer cross-document consistency check in the validator.
- Optional machine-readable (JSON) output from the inventory scripts.

## License

[Apache License 2.0](LICENSE).
