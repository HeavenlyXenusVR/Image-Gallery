#!/usr/bin/env bash
set -euo pipefail

# Mirrors Lumisound's ios/scripts/build-ipa.sh (same generate -> archive ->
# export flow) — see /home/xenus/Documents/Projects/Lumisound/ios/scripts/build-ipa.sh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="ImageGallery"
SCHEME="ImageGallery"
ARCHIVE_PATH="$ROOT_DIR/build/$PROJECT_NAME.xcarchive"
EXPORT_PATH="$ROOT_DIR/build/export"
EXPORT_OPTIONS="$ROOT_DIR/ExportOptions.plist"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it with: brew install xcodegen"
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Run this on macOS with Xcode installed."
  exit 1
fi

cd "$ROOT_DIR"
xcodegen generate
mkdir -p build

if [ ! -f "$EXPORT_OPTIONS" ]; then
  cat > "$EXPORT_OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>development</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
</dict>
</plist>
PLIST
fi

xcodebuild \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

echo "IPA export complete: $EXPORT_PATH"
