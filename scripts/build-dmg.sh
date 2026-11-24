#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${CLAUDEDOCK_VERSION:-0.2.0}"
# Name the DMG after what's actually inside (never call a single-architecture build "universal").
ARCH="${CLAUDEDOCK_DMG_ARCH:-}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/ClaudeDock.app"
STAGE_DIR="$DIST_DIR/dmg-stage"

# Always package a fresh build of this version (set CLAUDEDOCK_SKIP_BUILD=1 to reuse dist/ClaudeDock.app).
if [ "${CLAUDEDOCK_SKIP_BUILD:-0}" != "1" ] || [ ! -d "$APP_BUNDLE" ]; then
  bash "$ROOT_DIR/scripts/build-app.sh"
fi

if [ -z "$ARCH" ]; then
  ARCHS_IN_APP="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/ClaudeDockApp")"
  case "$ARCHS_IN_APP" in
    *x86_64*arm64*|*arm64*x86_64*) ARCH="universal" ;;
    *) ARCH="$(echo "$ARCHS_IN_APP" | tr ' ' '-')" ;;
  esac
fi
DMG_PATH="$DIST_DIR/ClaudeDock-${VERSION}-${ARCH}.dmg"
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
cp -R "$APP_BUNDLE" "$STAGE_DIR/ClaudeDock.app"
ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/Install CLI & Gatekeeper Help.txt" <<'EOF'
ClaudeDock — Native macOS Multi-Account Workbench for Claude Desktop
====================================================================

1. Drag ClaudeDock.app into the Applications folder.
2. If macOS says it can't verify the developer (builds without notarization):
   open System Settings -> Privacy & Security -> "Open Anyway" for ClaudeDock.
3. Optional: put the companion CLI on your PATH:
   mkdir -p ~/.local/bin && ln -sf /Applications/ClaudeDock.app/Contents/MacOS/claudedock ~/.local/bin/claudedock
EOF

echo "==> Creating compressed DMG: $DMG_PATH ..."
hdiutil create -volname "ClaudeDock ${VERSION}" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE_DIR"
if [ -n "${CLAUDEDOCK_SIGN_IDENTITY:-}" ] && [ "${CLAUDEDOCK_SIGN_IDENTITY}" != "-" ]; then
  echo "==> Signing DMG..."
  codesign --force --sign "$CLAUDEDOCK_SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo "==> SHA256:"
shasum -a 256 "$DMG_PATH"
ls -lh "$DMG_PATH"
