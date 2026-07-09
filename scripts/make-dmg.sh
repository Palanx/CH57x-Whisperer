#!/bin/zsh
# Build a release .app bundle and a drag-to-Applications DMG in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="CH57x Whisperer"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
swift build -c release
BIN=".build/release/ch57x-whisperer"

rm -rf dist && mkdir -p "dist/$APP.app/Contents/MacOS" "dist/$APP.app/Contents/Resources"

# Icon: the binary renders its own icon PNG; iconutil turns it into .icns.
ICONSET="dist/icon.iconset"
mkdir "$ICONSET"
ICON_PNG="$ICONSET/icon_512x512@2x.png" "$BIN" gui
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "dist/$APP.app/Contents/Resources/icon.icns"
rm -rf "$ICONSET"

cp "$BIN" "dist/$APP.app/Contents/MacOS/ch57x-whisperer"

# Same CFBundleIdentifier as the embedded Info.plist so the CLI binary and the
# app share one UserDefaults domain, and Login Items can show the app icon for
# the agent LaunchAgent (AssociatedBundleIdentifiers).
cat > "dist/$APP.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.palanx.ch57x-whisperer</string>
	<key>CFBundleName</key>
	<string>CH57x Whisperer</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleDisplayName</key>
	<string>CH57x Whisperer</string>
	<key>CFBundleExecutable</key>
	<string>ch57x-whisperer</string>
	<key>CFBundleIconFile</key>
	<string>icon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# Nested faceless helper app: the agent runs from here with its OWN bundle id
# and LSUIElement=true, so LaunchServices never confuses it with the GUI — no
# shared Dock icon, no cross-quit. Same binary and version, its own colored icon.
HELPER="dist/$APP.app/Contents/Helpers/Action Whisperer.app"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp "$BIN" "$HELPER/Contents/MacOS/action-whisperer"

AGENT_ICONSET="dist/agent-icon.iconset"
mkdir "$AGENT_ICONSET"
AGENT_ICON_PNG="$AGENT_ICONSET/icon_512x512@2x.png" "$BIN" gui
for s in 16 32 128 256 512; do
  sips -z $s $s "$AGENT_ICONSET/icon_512x512@2x.png" --out "$AGENT_ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$AGENT_ICONSET/icon_512x512@2x.png" --out "$AGENT_ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$AGENT_ICONSET" -o "$HELPER/Contents/Resources/agent-icon.icns"
rm -rf "$AGENT_ICONSET"

cat > "$HELPER/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.palanx.ch57x-whisperer.agent</string>
	<key>CFBundleName</key>
	<string>Action Whisperer</string>
	<key>CFBundleDisplayName</key>
	<string>Action Whisperer</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleExecutable</key>
	<string>action-whisperer</string>
	<key>CFBundleIconFile</key>
	<string>agent-icon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# NOTE: the agent login item is a plain plist in ~/Library/LaunchAgents
# (written by `agent --install`), NOT an SMAppService plist in the bundle:
# SMAppService pins the code signature and ad-hoc re-signs break it on
# every update. Needs a Developer ID to revisit.

# Ad-hoc signature, inside-out (codesign requires the nested helper signed
# first): enough to run on Apple Silicon; downloaders still right-click > Open
# once (no Developer ID / notarization).
codesign --force -s - "$HELPER"
codesign --force --deep -s - "dist/$APP.app"

STAGE="dist/dmg"
mkdir "$STAGE"
cp -R "dist/$APP.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "dist/$APP.dmg"
rm -rf "$STAGE"
echo "done: dist/$APP.dmg"
