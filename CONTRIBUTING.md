# Contributing

Thanks for wanting to help. A few things keep the project healthy:

## Ground rules

- **No third-party dependencies.** Apple frameworks only.
- **Never modify `Claude.app`.** Accounts are separated with `--user-data-dir`, nothing else.
- **Never delete user data.** Migrations back up and copy; tests should prove it.
- **Region-agnostic.** No hard-coded country, city or proxy node in defaults or docs.

## Getting started

```bash
swift build
swift test
bash scripts/security-check.sh
bash scripts/build-app.sh   # universal .app in dist/ (CLAUDEDOCK_ARCHS=arm64 for a faster local build)
```

## Pull requests

- Keep each PR to one change, with a short description of the why.
- Add or update tests for anything in `ClaudeDockCore`.
- UI changes: include before/after screenshots (light and dark if colors changed).
- `swift build` must stay warning-free under Swift 6 strict concurrency.
