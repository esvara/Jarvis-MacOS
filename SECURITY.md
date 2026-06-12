# Security Policy

## Reporting A Vulnerability

Do not open public issues for security-sensitive bugs.

If the canonical repository has private vulnerability reporting enabled, use that. Otherwise contact the maintainers privately before disclosing details publicly.

When reporting a vulnerability, include:

- the affected area
- reproduction steps
- impact
- any known mitigations or workarounds

## Scope

Security-sensitive areas in this project include:

- local HTTP services on `127.0.0.1`
- native keyboard and mouse synthesis
- settings and memory persistence
- voice runtime messaging between Swift, WebKit, and the sidecar
- anything that could expose API keys, user transcripts, screenshots, or local files
