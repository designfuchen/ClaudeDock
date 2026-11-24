#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${CLAUDEDOCK_VERSION:-0.2.1}"
# CFBundleVersion must be numeric (no "-beta" suffix); CI passes the run number.
BUILD_NUMBER="${CLAUDEDOCK_BUILD:-1}"
SHORT_VERSION="${VERSION%%-*}"
# Universal (Apple silicon + Intel) by default; set CLAUDEDOCK_ARCHS="arm64" for a quick local build.
ARCHS="${CLAUDEDOCK_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/ClaudeDock.app"

echo "==> Building release binaries (ClaudeDockApp + claudedock)..."
cd "$ROOT_DIR"
swift build -c release "${ARCH_FLAGS[@]}" --product ClaudeDockApp
swift build -c release "${ARCH_FLAGS[@]}" --product claudedock

BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
echo "==> Assembling $APP_BUNDLE ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_DIR/ClaudeDockApp" "$APP_BUNDLE/Contents/MacOS/ClaudeDockApp"
cp "$BIN_DIR/claudedock" "$APP_BUNDLE/Contents/MacOS/claudedock"
chmod 755 "$APP_BUNDLE/Contents/MacOS/ClaudeDockApp" "$APP_BUNDLE/Contents/MacOS/claudedock"

echo "==> Generating native macOS AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Declare Simplified Chinese so system-provided menus (File, Edit, Window…) match the app's own language.
mkdir -p "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj" "$APP_BUNDLE/Contents/Resources/en.lproj"
# Chinese is the source language (keys are the Chinese strings); English ships as a strings table.
for L in "$ROOT_DIR"/Localization/*.lproj; do
  [ -d "$L" ] && cp "$L"/*.strings "$APP_BUNDLE/Contents/Resources/$(basename "$L")/" 2>/dev/null || true
done
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeDock</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleDisplayName</key><string>ClaudeDock</string>
  <key>CFBundleIdentifier</key><string>io.claudedock.app</string>
  <key>CFBundleExecutable</key><string>ClaudeDockApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>io.claudedock.app</string>
    <key>CFBundleURLSchemes</key><array><string>claudedock</string></array>
  </dict></array>
</dict>
</plist>
EOF

# Sign inside-out (no deprecated --deep). With CLAUDEDOCK_SIGN_IDENTITY="Developer ID Application: …" the build is
# signed with the hardened runtime and a timestamp, ready for scripts/notarize.sh; otherwise it is ad-hoc signed.
IDENTITY="${CLAUDEDOCK_SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
echo "==> Code signing ($([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY"))..."
codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE/Contents/MacOS/claudedock"
codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE/Contents/MacOS/ClaudeDockApp"
codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
lipo -archs "$APP_BUNDLE/Contents/MacOS/ClaudeDockApp"

echo "==> Done! Bundle size:"
du -sh "$APP_BUNDLE"
