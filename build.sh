#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product PNGMeta
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="PNGMeta.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/PNGMeta" "$APP/Contents/MacOS/PNGMeta"
chmod +x "$APP/Contents/MacOS/PNGMeta"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleExecutable</key>
  <string>PNGMeta</string>
  <key>CFBundleIdentifier</key>
  <string>local.pngmeta</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PNG Meta</string>
  <key>CFBundleDisplayName</key>
  <string>PNG Meta</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>PNG image</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.png</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>png</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP"
fi
echo "built $(pwd)/$APP"
