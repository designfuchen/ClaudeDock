# Changelog

## 0.2.1 — 2026-11-24

### Fixed
- On a Chinese system the app showed its English interface. Both languages now ship their own strings table, so the app always matches your system language.
- In English, the account name in the menu bar switcher could collapse to "…" next to the Recommended badge.
- Shorter English countdowns (`in 2h 14m`, `in 3d`) and sign-in hint, so nothing is cut off.

## 0.2.0 — 2026-11-24

### Added
- **English interface.** The app now speaks English and Simplified Chinese and follows your system language.
- Menu bar label shows the account in front and what it has left, e.g. `Work · 82% left`.
- Reset times read as a countdown plus local clock time (`in 29 min · 16:00 local`), and every quota shows when it was last read.
- A usage window that has passed its reset shows *Pending refresh* and is re-read within a minute; *Reset* only appears once a fresh reading confirms it.
- **Continue** on a project or session brings you back to that account's Claude Desktop window; continuing in Terminal is one click away.
- New app icon, redesigned main window and menu bar switcher, full email and exit details on account cards, and a visible sign-in button for accounts whose Claude Code is signed out.
- **Projects**: every Claude Code project and session on this Mac, continued or resumed with any account in one click.
- **Shared session history** across accounts (transcripts, checkpoints, plans, todos); credentials stay per account. Migration backs up and copies, never deletes.
- **Quick switcher** (⌃⌥Space): Spotlight-style panel for accounts and projects, with pinyin search.
- Remaining quota shown as what's left, with reset times; read automatically, no tokens used.
- Signed-in name and email read locally from Claude Desktop.
- One-click Claude Code sign-in when quota can't be read yet.

### Changed
- Redesigned workbench, menu bar switcher, account editor and add-account flow.
- Egress status now shows the measured result (verified, stale, mismatch, unreachable) instead of the configured policy.
- Incidents stay on screen until handled; paused accounts only resume after a passing re-check.
- CLI: `claudedock add --ny` is replaced by the region-agnostic `--pin` (lock to whatever exit the local proxy reports now). Unsupported proxy schemes, a missing flag value, or an unquoted two-word name are now errors instead of silent fallbacks.

### Fixed
- Resuming a paused account (app and `claudedock resume`) and `cli-run` re-check that the proxy and egress rule they verified are still the saved ones.
- Each account's Claude Code login now lives in `~/.claudedock/cli-profiles/<account id>`, so renaming never moves or splits it. Existing name-based folders migrate automatically on the first launch of the app or CLI (an account in use is migrated later). Don't run an older ClaudeDock after upgrading: it would look in the old folder and show the account as signed out.
- "Quit all" now also kills paused helpers (MCP servers, Claude Code) instead of leaving them stopped.
- A quota window whose reset time has passed now counts as rolled over instead of showing the old usage.
- Quota and identity probes can no longer hang when a helper process keeps the output pipe open.
- An ungrouped account is never recommended to hand off to a grouped one.
- Clash multi-port config keeps every explicitly configured port and skips the real mixed port.
- Update guard keeps windows still waiting to be restored when run twice or cancelled.

## 0.1.0
- First release: isolated multi-account Claude Desktop, egress guard, Clash Verge integration, MCP sync, CLI.
