# Architecture

## Philosophy

Documentation should represent actual machine truth, not aspirational
architecture.

Most infrastructure documentation describes what someone intended to build.
It is written once, at the moment of highest optimism, and then drifts. An
agent that trusts such a document will act on a fiction.

AI System Map is built around the opposite assumption: the document is only
useful if it is continuously reconciled against what the machine is actually
doing. Where the two disagree, the machine is right.

## Four concepts

**CANONICAL MAP** — the single agreed source for a given concern. Exactly one
document owns "which ports are in use". Others may reference it; none may
redefine it. When an agent needs the answer, it reads the owner, and it reads
it rather than recalling it.

**OBSERVED STATE** — what the host reports right now: listening sockets,
running units, published container ports, firewall status. Collected by the
inventory scripts. Always evidence, never assumption.

**DECLARED INTENT** — what a human decided should be true, and why. "This port
is loopback-only on purpose." "This service is deliberately not backed up
because it is reproducible from source." Intent cannot be inferred from
observation; it has to be written down, or the next agent will 'helpfully'
undo it.

**VALIDATION** — the cheap, automatable subset of "is this map still honest?"
Not a compliance engine. It catches structural rot: a missing document, an
unresolved placeholder, an exposure value that is not one of the supported
classifications.

## The loop

```
Observed machine state
        │
        ▼
    Inventory            (read-only scripts; evidence, not conclusions)
        │
        ▼
  Canonical System Map   (human/agent-authored; observation + intent)
        │
        ▼
    Validation           (structural checks; fails loudly, fixes nothing)
        │
        ▼
Agent reads before acting
        │
        └──────────────► (action changes the machine, so loop again)
```

The arrow back matters. An agent that changes the machine and does not update
the map has degraded the map for every future agent, including itself.

## Sensor, not controller

**AI System Map does not mutate the host.**

This is a deliberate architectural boundary, not a temporary limitation.

A tool that both *describes* infrastructure and *changes* it has an obvious
failure mode: a bug in the describing half becomes a destructive action in
the changing half. Worse, an agent driving such a tool can be induced —
through a bad inference, an ambiguous instruction, or a prompt injection in
some file it read — to use the mutation path.

So the layers are separated:

| Layer | Responsibility | May write to host? |
|---|---|---|
| Inventory scripts | Collect observable evidence | No |
| System Map documents | Record observation + intent | No (they are files) |
| Validator | Check structural honesty | No |
| **Your existing tooling** | Actually change the machine | Yes |

AI System Map is the **sensor and context layer**. It makes your existing
tooling better informed. It does not replace it, and it does not become an
autonomous infrastructure controller.

If you want automated remediation, drive it from your own configuration
management system, using the map as input.

## Exposure classification

The most valuable thing the map records is how reachable something is,
because that is the property most often guessed wrong.

Supported values:

| Value | Meaning |
|---|---|
| `LOCAL_ONLY` | Bound to loopback, no external path in |
| `LAN` | Reachable from the local network segment |
| `PRIVATE_OVERLAY` | Reachable only over a private overlay/mesh network |
| `PUBLIC_VIA_PROXY` | Reachable from the internet through a reverse proxy or tunnel |
| `DIRECT_PUBLIC` | Bound to a public interface, reachable directly |
| `UNKNOWN` | Not yet determined — treat as potentially public |

### The loopback trap

The single most important lesson this model encodes:

> **A process bound to `127.0.0.1` may still be reachable from the internet.**

A reverse proxy or an outbound tunnel client running on the same host can
forward public traffic to a loopback port. The socket looks private. The
service is not. Firewall rules frequently do not help, because the traffic
arrives as a local connection from the proxy process.

Consequently:

- A bind address is **evidence**, not a classification.
- Classification requires also checking proxy and tunnel configuration.
- When a tunnel or proxy config cannot be read, the correct answer is
  `UNKNOWN`, not `LOCAL_ONLY`.

The same trap applies to container port publishing, which on some setups
inserts forwarding rules that bypass the host firewall entirely.

## Document ownership

Each canonical document owns one concern:

| Document | Owns |
|---|---|
| `SYSTEM.md` | Machine purpose, environment, layout, project index |
| `SERVICES.md` | Supervised services and what they run |
| `PORTS.md` | Listeners, owners, exposure classification |
| `SECURITY.md` | Controls that exist, credential locations, boundaries |
| `BACKUPS.md` | What is protected, by what, on what schedule |
| `RESTORE.md` | How to recover, and whether that was tested |

One concern, one owner. When a fact appears in two documents, one of them is
going to go stale, and no reader will know which.

## Non-goals

- No daemon or agent process.
- No state database.
- No network calls to any third-party service.
- No dependency on a specific AI vendor, model, or agent framework.
- No dependency heavier than a POSIX shell and standard Linux utilities.
