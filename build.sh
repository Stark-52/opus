#!/bin/zsh
# Build Opus.app from the Swift Package. Single command, produces a signed .app
# bundle with the Opus icon installed.
set -euo pipefail

cd "$(dirname "$0")"

echo "→ swift build (release)"
swift build -c release

BUILD_DIR="$(swift build -c release --show-bin-path)"
OPUS_BIN="$BUILD_DIR/Opus"
ATTACH_BIN="$BUILD_DIR/opus-attach"
test -f "$OPUS_BIN"   || { echo "✗ Opus binary not found at $OPUS_BIN"; exit 1; }
test -f "$ATTACH_BIN" || { echo "✗ opus-attach binary not found at $ATTACH_BIN"; exit 1; }

echo "→ assembling Opus.app bundle"
rm -rf Opus.app
mkdir -p Opus.app/Contents/MacOS
mkdir -p Opus.app/Contents/Resources
cp "$OPUS_BIN"   Opus.app/Contents/MacOS/Opus
cp "$ATTACH_BIN" Opus.app/Contents/MacOS/opus-attach

echo "→ installing opus-attach to ~/.local/bin"
mkdir -p "$HOME/.local/bin"
cp "$ATTACH_BIN" "$HOME/.local/bin/opus-attach"
chmod +x "$HOME/.local/bin/opus-attach"

cat > Opus.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Opus</string>
    <key>CFBundleIdentifier</key><string>com.stark52.opus</string>
    <key>CFBundleName</key><string>Opus</string>
    <key>CFBundleDisplayName</key><string>Opus</string>
    <key>CFBundleVersion</key><string>1.4.1</string>
    <key>CFBundleShortVersionString</key><string>1.4.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Opus</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Opus sends Apple Events to control terminal applications.</string>
</dict>
</plist>
PLIST

if [ -f "Opus.icns" ]; then
    cp Opus.icns Opus.app/Contents/Resources/Opus.icns
fi

# A stable signing identity keeps TCC grants (Documents access etc.) across
# rebuilds. Ad-hoc re-signing minted a NEW identity every build, so macOS
# re-prompted for permissions after each install. Fall back to ad-hoc when
# the certificate is unavailable.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "[redacted]"; then
    echo "→ signing with Apple Development identity"
    codesign --force --sign an Apple Development certificate --deep Opus.app
else
    echo "→ ad-hoc signing (no stable identity found)"
    codesign --force --sign - --deep Opus.app
fi

echo "✔ Opus.app ready ($(du -sh Opus.app | cut -f1))"
