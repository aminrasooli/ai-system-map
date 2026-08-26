# Agent integration

This project is vendor-neutral. It works with any agent that can read files
and run shell commands. Nothing here depends on a particular model, provider,
or agent framework.

## The standing instruction

Put this where your agent reads persistent project context:

> Before modifying infrastructure, deployment, networking, services, or
> recovery configuration, read the canonical System Map and verify current
> machine state.

Most agent tools have a conventional file for this — a repository-level
instructions file, a global configuration file, a system prompt, or a rules
directory. Any of them work. The map is plain Markdown; the mechanism is
whatever your tool already uses.

## A fuller instruction block

If you want to be explicit, something like this:

```markdown
## Machine operations

The canonical System Map for this host lives at `~/system-map/`.

Before any change to infrastructure, services, ports, networking, exposure,
or recovery configuration:

1. Read the relevant System Map document.
2. Verify the facts you depend on against live machine state — the map can
   be stale, and where they disagree the machine is correct.
3. Check whether a control for this concern already exists before adding a
   new one.
4. After the change, update the map in the same unit of work.

Do not record credential values in the map. Names and locations only.
```

## Why "verify", not just "read"

A map that is trusted but stale is worse than no map, because it converts
uncertainty into false confidence. An agent that reads `PORTS.md` and acts
without checking is one drifted document away from a bad change.

The cheap version of verification is running the relevant inventory script
and comparing:

```bash
bash scripts/inventory-ports.sh
```

If the live listeners do not match `PORTS.md`, that discrepancy is the most
interesting thing the agent has learned, and it should surface it rather than
silently picking one.

## What this prevents

Four recurring agent failure modes:

**Guessing.** An agent reads a service definition and assumes it describes
the running process. It may not — a long-running process can predate the
current on-disk configuration. The map records how the service is actually
supervised; verification catches the rest.

**Reinvention.** An agent adds a health check, a firewall rule, or a wrapper
script because it could not tell that one already exists. `SECURITY.md`
enumerates existing controls precisely so an agent can find them and stop.

**Accidental exposure.** An agent changes a bind address or publishes a
container port without understanding what that means on this host. The
exposure classification in `PORTS.md` makes the consequence explicit.

**Recovery ambiguity.** An agent proposes a destructive change without
knowing whether the data is backed up. `BACKUPS.md` and `RESTORE.md` answer
that before the change, not after.

## Suggested agent workflow

```
1. read   — the relevant canonical document
2. verify — run the matching inventory script, compare
3. report — if map and machine disagree, say so; do not silently choose
4. act    — make the change, using existing controls where they exist
5. update — record the new state in the map, in the same change
```

Step 3 is the one most worth enforcing. An agent that quietly reconciles a
discrepancy has destroyed the signal that something drifted.

## Boundaries worth setting

The map is context, not authority to act. A few limits are worth making
explicit to your agent:

- The map is **read** before infrastructure work; it does not by itself
  authorize that work.
- Inventory scripts are read-only. An agent should not be adding mutation
  flags to them.
- Credential values never enter the map, regardless of how convenient it
  would be for the agent to have them there.
- If an exposure classification is `UNKNOWN`, an agent should treat the
  service as potentially public until proven otherwise.

## Multi-agent notes

If more than one agent — or more than one session of the same agent — can
work on the host:

- Treat the map as shared mutable state. Two agents updating it concurrently
  will conflict like any other file.
- Prefer one writer at a time for the map itself.
- An agent that finds the map inconsistent with the machine should report it
  rather than repair it unilaterally; the discrepancy may be another agent's
  in-flight work.
