# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository: open the **Security** tab and choose **Report a
vulnerability**.

Please do not open a public issue for a security problem before it has been
addressed.

When reporting, it helps to include:

- what the issue is, and which file or script it affects
- how to reproduce it
- what an attacker could achieve

There is no bounty programme. This is a small open-source project maintained
on a best-effort basis, and response times will vary.

## What is in scope

This project ships shell scripts that inspect a host, document templates, and
a validator. Security issues that matter here include:

- **Information disclosure** — a script printing credential material,
  environment variable values, tunnel or proxy credentials, container
  environments, private keys, or tokens. This is the primary concern.
- **Unintended writes** — any script modifying host state. All scripts are
  intended to be read-only.
- **Command injection** — a crafted filename, hostname, or file content
  causing a script to execute something unintended.
- **Privilege escalation** — a script escalating rather than reporting
  `UNKNOWN` when data is unreadable.
- **Validator false confidence** — the validator reporting a map as valid
  when it contains an obvious pasted credential.

## What is out of scope

- The security of *your* infrastructure. This project documents a machine; it
  does not defend one.
- Your filled-in System Map leaking because you committed it to a public
  repository. Treat a completed map as sensitive — see below.
- Findings that require an attacker to already have the privileges the script
  runs with.

## Design commitments

These are properties the project intends to maintain. A deviation is a bug
worth reporting:

- Scripts are **read-only**. There is no remediation, apply, or fix mode.
- Scripts **never print secret values**: no environment variable values, no
  `.env` contents, no tunnel or proxy credentials, no container environments,
  no tokens, no private keys.
- Scripts **report `UNKNOWN` rather than escalating** when data requires
  privileges they do not have.
- Templates ask for credential **names and locations only**, never values.
- Examples use fictional hosts, domains, and identifiers, and contain nothing
  that resembles a real credential.

## Handling your own System Map

The output of this project — a completed System Map — is a description of your
infrastructure, and that is useful to an attacker.

- Keep a filled-in map in a **private** repository.
- Never record credential values in it, even temporarily.
- Review it before sharing it, including with an AI agent that may transmit
  it off the machine.
