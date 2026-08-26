# Contributing

Contributions are welcome. This is a small project and intends to stay small.

## Ground rules

**No secrets in examples.** Never commit anything resembling a real
credential — not a token, not a key, not a fragment, not a hash. Examples must
use values that could not possibly be real.

**Use fictitious identifiers.** Hostnames, domains, IP addresses, account
names, and repository names in documentation and examples must be invented.
Use `example.com` and its subdomains, RFC 5737 addresses
(`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`), and names like
`dev-box`, `developer`, or `example-api`. Never sanitize a real capture —
hand-author the example instead. Sanitizing is lossy and fails quietly.

**Scripts are read-only unless clearly documented otherwise.** Every script
currently in `scripts/` observes and reports. If you have a genuine reason to
propose one that writes, say so explicitly in the pull request, name it
unambiguously, and expect the bar to be high.

**Never print secret material.** A script must not emit environment variable
values, `.env` contents, tunnel or proxy credentials, container environments,
tokens, or private keys. When something needs privileges you do not have,
report `UNKNOWN`. Do not escalate.

**Security-impacting changes need tests.** If you touch the validator, the
exposure classification logic, or anything that could affect what a script
prints, add a case to `tests/test-basic.sh`.

## Before opening a pull request

```bash
bash tests/test-basic.sh
bash scripts/validate-system-map.sh examples/sample-system-map
```

Both must pass. If you have `shellcheck` installed, please also run:

```bash
shellcheck scripts/*.sh tests/*.sh
```

## Style

- POSIX-friendly `bash`. Avoid dependencies beyond standard Linux utilities.
- Prefer clarity over cleverness; these scripts are read by people trying to
  understand their own machine, often under stress.
- Fail safely. A script that cannot determine something should say so, not
  guess.
- Keep comments about *why*, not *what*.

## Scope

Things that fit:

- Additional exposure detection for other proxy or tunnel families
- Better cross-document consistency checks
- Portability fixes across Linux distributions
- Documentation improvements

Things that do not fit in this project:

- Autonomous mutation of host state
- Cloud provisioning, orchestration, or configuration management
- A daemon, database, web UI, or hosted service
- Integration tied to one specific AI vendor or agent framework
- A general-purpose policy engine

If you are unsure whether an idea fits, open an issue before building it.

## Licence

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
