#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/SourceTempo.app"
INSTALL=false

case "${1:-}" in
  "") ;;
  --install) INSTALL=true ;;
  *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

swift build --package-path "$ROOT/macos" -c release --arch arm64
BIN_DIR="$(swift build --package-path "$ROOT/macos" -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN_DIR/SourceTempo" "$APP/Contents/MacOS/SourceTempo"
ditto "$ROOT/macos/Assets/SourceTempo.icns" "$APP/Contents/Resources/SourceTempo.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>SourceTempo</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.endario.SourceTempo</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>SourceTempo.icns</string>
  <key>CFBundleName</key>
  <string>SourceTempo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"

if $INSTALL; then
  rm -rf /Applications/SourceTempo.app
  ditto "$APP" /Applications/SourceTempo.app
  echo "Installed /Applications/SourceTempo.app"
else
  echo "Built $APP"
fi
