# claudedock CLI

The CLI ships inside the app at `/Applications/ClaudeDock.app/Contents/MacOS/claudedock`. Link it once:

```bash
mkdir -p ~/.local/bin
ln -sf /Applications/ClaudeDock.app/Contents/MacOS/claudedock ~/.local/bin/claudedock
```

Account names with spaces need quotes. `--pin` detects your local proxy and locks the account to the exit it reports right now.

## Commands

```text
Usage:
  claudedock add <NAME> [--default] [--pin] [--proxy http://127.0.0.1:7897] [--pin-ip IP] [--region R] [--tz TZ]
                                           --pin: use the detected local proxy and lock to its current exit
  claudedock list [--json]
  claudedock open <NAME> [--force]         Verify Egress Guard & open/focus Claude Desktop window
  claudedock focus <NAME>                  Bring specific account window to foreground by PID
  claudedock freeze <NAME>                 Freeze process tree (SIGSTOP) to prevent leaks
  claudedock resume <NAME> [--force]       Re-verify egress & resume frozen window (SIGCONT)
  claudedock quit <NAME> | quit-all        Gracefully quit one or all Claude Desktop windows
  claudedock remove <NAME> [--delete-data] Remove launcher (and optionally data folder)

  claudedock egress probe [--proxy URL]    Probe real exit IP/region/timezone via proxy
  claudedock egress check <NAME>           Run Fail-Closed Egress Guard check for an account
  claudedock egress pin <NAME> [--exact-ip] Lock current proxy egress region/TZ (or exact IP)
  claudedock clash detect                  Inspect local Clash Verge ports & profiles
  claudedock clash merge [--node NAME]     Generate Clash Verge Multi-Listener Merge YAML

  claudedock quota [NAME] [--force]        Zero-token 5h/7d quota check via Claude CLI
  claudedock recommend [--group NAME]      Recommend best account by remaining headroom
  claudedock sync mcp                      Three-way merge Desktop MCP servers across accounts
  claudedock peers                         List live Claude Code sessions across accounts
  claudedock projects [--all]              Projects and sessions from every account (resume with any account)
  claudedock handoff <FROM> <TO> <TASK>    Generate structured cross-account handoff brief
  claudedock update-guard start|restore    Safe Claude.app update helper
```

## Per-account Claude Code commands

Every linked account gets a `claude-<account>` command in `~/.claudedock/bin` (also linked into `~/.local/bin`). It checks that account's exit rule, then starts Claude Code with that account's own login:

```bash
cd ~/code/my-project
claude-work --continue
```
