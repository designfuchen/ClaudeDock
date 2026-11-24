#!/usr/bin/env bash
# Notarizes and staples a DMG signed with a "Developer ID Application" certificate.
#
# Locally (recommended): store credentials once — you'll be asked for an app-specific password:
#   xcrun notarytool store-credentials claudedock-notary --apple-id <you@example.com> --team-id <TEAMID>
# then:  NOTARY_PROFILE=claudedock-notary bash scripts/notarize.sh dist/ClaudeDock-<ver>-universal.dmg
#
# In CI: set APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD instead.
set -euo pipefail
DMG="${1:?usage: notarize.sh <file.dmg>}"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${APPLE_ID:?set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"
  AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
echo "==> Submitting $DMG for notarization (usually 1–5 minutes)..."
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait
echo "==> Stapling ticket..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# A Gatekeeper rejection after notarization is a failed release, not a warning.
spctl -a -t open --context context:primary-signature -vv "$DMG"
