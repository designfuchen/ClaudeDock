---
name: handoff
description: Inspect running Claude Code sessions across ClaudeDock accounts on this Mac and perform clean, structured cross-account handoffs or peer messaging.
argument-hint: "[target account or session] [task summary]"
---

# ClaudeDock Cross-Account Session Handoff

ClaudeDock runs multiple native macOS Claude Desktop and Claude Code CLI profiles while sharing user-level skills, instructions (`CLAUDE.md`), and peer discovery (`claudedock peers`).

User request: `$ARGUMENTS`

## Workflow

1. **Discover live peers.**
   - Call `ListAgents` (if available) and optionally run `claudedock peers` to map running Claude Code sessions to their account names.
   - If the target account or session is ambiguous, ask the user before sending anything.

2. **Check explicit handoff boundaries.**
   - Respect account boundaries (e.g., do not send confidential company code into a personal account unless the user explicitly requested it).
   - Never include raw API keys, cookies, credentials, or secrets in handoff summaries.

3. **Create a self-contained handoff brief.**
   - Run `claudedock handoff <FROM> <TO> "<SUMMARY>" --cwd "<WORKSPACE>"` or compose a concise brief with:
     - Exact workspace path and relevant files
     - What is already completed (so nothing is repeated)
     - What remains to be done and acceptance criteria
     - Verification instructions before acting

4. **Send or present cleanly.**
   - If `SendMessage` is available and the target session is running, send the brief directly and relay the reply when it arrives.
   - Otherwise, present the generated brief clearly so the user can paste it into the target ClaudeDock window (accessible via `⌘⌥1`–`⌘⌥9`).
