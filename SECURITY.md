# Security Policy

## Reporting a vulnerability

If you believe you've found a security-relevant bug in Séance, please **do not open a public issue**. Instead, report it privately via GitHub's private vulnerability reporting on this repository:

https://github.com/no1msd/seance/security/advisories/new

I aim to acknowledge reports within 72 hours. For anything that could be a remote-exploit vector (for example, content fetched into a pane that could escape the terminal's rendering), please include a proof-of-concept and the affected version.

## Supported versions

Séance is pre-1.0 and only the latest released version is supported with security fixes.

## Scope

Things that qualify:

- Escape sequences or content rendered in a terminal that can escape the pane (e.g. trigger arbitrary actions on the host).
- Socket or CLI issues that let unprivileged local processes control a running Séance instance they shouldn't have access to.
- Hook-injection or env leakage that exposes secrets across panes or sessions.

Things that are out of scope:

- Bugs that require an attacker to already have local shell access as the Séance user.
- Denial of service via rapid input or resource exhaustion.
- Vulnerabilities in upstream dependencies (GTK, libghostty, Zig); please report those upstream.
