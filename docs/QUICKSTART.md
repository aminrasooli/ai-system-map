# Quickstart

This walks through building a System Map for a host in about fifteen minutes.

## Requirements

- Linux
- `bash`, and the usual core utilities
- Optional, used when present: `ss` or `netstat`, `systemctl`, `docker`,
  `ufw`, an overlay-network CLI

Nothing here installs anything, and nothing runs as a daemon.

## 1. Collect evidence

Run the inventory scripts. All four are read-only.

```bash
bash scripts/inventory-host.sh
bash scripts/inventory-services.sh
bash scripts/inventory-ports.sh
bash scripts/check-public-exposure.sh
```

Each prints a plain-text report to stdout. Redirect them if you want to keep
the raw evidence:

```bash
mkdir -p ./evidence
bash scripts/inventory-ports.sh > ./evidence/ports.txt
```

Two things to know about the output:

- Where a script cannot read something without elevated privileges, it prints
  `UNKNOWN` and moves on. It will not escalate. `UNKNOWN` is a real answer and
  should be recorded as such.
- The scripts never print secret material. If you want a value that a script
  refused to show, retrieve it yourself, and still do not put it in the map.

## 2. Create your map

The templates are the skeleton. Copy them somewhere durable — a private
repository is a good choice.

```bash
mkdir -p ~/system-map
cp templates/*.md ~/system-map/
cd ~/system-map
```

You now have six documents. Fill them in from the evidence you collected,
in this order:

1. **`SYSTEM.md`** — what the machine is for. Start here; it gives the rest
   context.
2. **`SERVICES.md`** — one row per supervised service.
3. **`PORTS.md`** — one row per listener. This is where you assign an
   exposure classification to each one.
4. **`SECURITY.md`** — the controls that already exist, and where credentials
   live (names and paths only, never values).
5. **`BACKUPS.md`** — what is protected and what is deliberately not.
6. **`RESTORE.md`** — how to get back, and whether you have actually tried.

Replace every `<...>` placeholder. The validator will fail if you leave any.

## 3. Classify exposure honestly

This is the step that repays the effort. For each listener, pick one:

| Value | Use when |
|---|---|
| `LOCAL_ONLY` | Loopback bind, and no proxy or tunnel forwards to it |
| `LAN` | Reachable from the local network segment |
| `PRIVATE_OVERLAY` | Reachable only across a private overlay network |
| `PUBLIC_VIA_PROXY` | A reverse proxy or tunnel exposes it to the internet |
| `DIRECT_PUBLIC` | Bound to a public interface |
| `UNKNOWN` | You could not determine it |

A loopback bind is not sufficient evidence for `LOCAL_ONLY`. Check whether a
reverse proxy or tunnel forwards to that port — `check-public-exposure.sh`
looks for the common cases, but it cannot see every configuration. If you
cannot confirm, write `UNKNOWN`.

`UNKNOWN` is not a failure. It is an accurate statement that something needs
looking at, and it is far more useful to the next reader than a confident
guess.

## 4. Validate

```bash
bash scripts/validate-system-map.sh ~/system-map
```

The validator checks that:

- all six canonical documents exist
- required headings are present
- no `<placeholder>` markers remain
- every exposure classification is one of the supported values
- services referenced in `PORTS.md` appear in `SERVICES.md`
- `BACKUPS.md` and `RESTORE.md` state a tested/untested recovery status

It exits non-zero on failure and prints one line per finding. It never edits
your files.

## 5. Point your agent at it

Add an instruction to whatever file your agent reads for standing context:

> Before modifying infrastructure, deployment, networking, services, or
> recovery configuration, read the System Map at `~/system-map/` and verify
> the relevant facts against current machine state.

See [AGENT-INTEGRATION.md](AGENT-INTEGRATION.md) for more.

## 6. Keep it honest

A map is only worth what its accuracy is worth. Two habits:

- **Re-run the inventory periodically** and reconcile differences. A new
  listener you did not expect is exactly what you want to catch.
- **Update the map in the same change that alters the machine.** If it is a
  separate task, it will not happen.

If the map and the machine disagree, the machine is right, and the map is a
bug.
