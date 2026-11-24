# Security Policy

ClaudeDock runs locally and touches things that matter: per-account data folders, proxy settings, and Claude Code's session files. I take reports seriously.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private
[security advisory](../../security/advisories/new) form instead, with steps to reproduce and the version (`claudedock --version`).

I'll acknowledge within a few days and keep you posted until it's fixed and released.

## Scope

In scope: anything that could leak credentials or session data between accounts, run commands you didn't ask for, write outside ClaudeDock's own folders, or let a launch bypass the egress check.

Out of scope: issues in Claude Desktop, Claude Code, or your proxy software themselves.
