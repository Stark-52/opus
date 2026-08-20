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
SECRETS_BIN="$BUILD_DIR/opus-secrets"
test -f "$OPUS_BIN"   || { echo "✗ Opus binary not found at $OPUS_BIN"; exit 1; }
test -f "$ATTACH_BIN" || { echo "✗ opus-attach binary not found at $ATTACH_BIN"; exit 1; }
test -f "$SECRETS_BIN" || { echo "✗ opus-secrets binary not found at $SECRETS_BIN"; exit 1; }

echo "→ assembling Opus.app bundle"
rm -rf Opus.app
mkdir -p Opus.app/Contents/MacOS
mkdir -p Opus.app/Contents/Resources
cp "$OPUS_BIN"   Opus.app/Contents/MacOS/Opus
cp "$ATTACH_BIN" Opus.app/Contents/MacOS/opus-attach
cp "$SECRETS_BIN" Opus.app/Contents/MacOS/opus-secrets

echo "→ installing opus-attach to ~/.local/bin"
mkdir -p "$HOME/.local/bin"
cp "$ATTACH_BIN" "$HOME/.local/bin/opus-attach"
chmod +x "$HOME/.local/bin/opus-attach"

echo "→ installing opus-secrets to ~/.local/bin"
cp "$SECRETS_BIN" "$HOME/.local/bin/opus-secrets"
chmod +x "$HOME/.local/bin/opus-secrets"

# CFBundleIdentifier is not a cosmetic string, and changing it is not free.
# TCC keys its grants on the DESIGNATED REQUIREMENT, which is the identifier
# plus the certificate leaf (see the signing block at the bottom), so a new
# identifier is a new app as far as macOS is concerned: Accessibility and the
# rest have to be granted again, and the stale entry has to be removed by hand
# or two rows named Opus sit in the list with one of them dead. Preferences
# move with it too, since the standard UserDefaults domain IS the identifier —
# migrate an existing install with `defaults export <old> -` piped through
# `defaults import <new> -` before first launch.
cat > Opus.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Opus</string>
    <key>CFBundleIdentifier</key><string>com.stark52.opus</string>
    <key>CFBundleName</key><string>Opus</string>
    <key>CFBundleDisplayName</key><string>Opus</string>
    <key>CFBundleVersion</key><string>1.6</string>
    <key>CFBundleShortVersionString</key><string>1.6</string>
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
# rebuilds. Ad-hoc re-signing mints a NEW identity every build, so macOS
# re-prompts for permissions after each install.
#
# This used to point at an Apple Development certificate, which EXPIRED on
# 13 Aug 2026 (issued 13 Aug 2025, one year, as they all are). Its silent
# expiry is what put every rebuild back on the ad-hoc path and started the
# permission prompts again.
#
# It is replaced by a self-signed code-signing certificate created 14 Aug 2026
# and valid to 2036. Opus is never distributed, so a certificate from Apple
# buys nothing here: TCC keys on the DESIGNATED REQUIREMENT, and this one is
# byte-identical across builds — verified as
#   identifier "com.stark52.opus" and certificate leaf = H"66694a07…"
# on two independent builds. No yearly renewal, no dependency on a team.
#
# The lookup deliberately omits -v: that flag lists only chain-trusted
# identities, and a self-signed certificate is not one. codesign accepts it
# regardless, which was verified before this change was made.
if security find-identity -p codesigning 2>/dev/null | grep -q "Opus Local Signing"; then
    echo "→ signing with the local Opus identity"
    codesign --force --sign "Opus Local Signing" --deep Opus.app
else
    echo "→ ad-hoc signing (no local identity — macOS will re-prompt for permissions)"
    codesign --force --sign - --deep Opus.app
fi

SIZE="$(du -sh Opus.app | cut -f1)"

# Installed, not left in the repo. The script already installs opus-attach to
# ~/.local/bin; leaving the .app behind was the odd one out, and the cost was
# real: a bundle in the repo AND one in ~/Applications share
# com.stark52.opus at two paths, so macOS lists Opus twice and "which one did
# I just launch" becomes a question you have to ask. One bundle, one answer.
#
# OPUS_NO_INSTALL=1 keeps the bundle in the repo instead — for inspecting what
# was built without touching the installed copy.
if [[ "${OPUS_NO_INSTALL:-0}" == "1" ]]; then
    echo "✔ Opus.app ready ($SIZE) — not installed (OPUS_NO_INSTALL=1)"
    exit 0
fi

APP_DEST="$HOME/Applications/Opus.app"
if pgrep -f "Opus.app/Contents/MacOS/Opus" >/dev/null 2>&1; then
    WAS_RUNNING=1
else
    WAS_RUNNING=0
fi

echo "→ installing Opus.app to $APP_DEST"
mkdir -p "$HOME/Applications"
# Delete first: ditto MERGES into an existing bundle, which would leave files
# from the previous build sitting inside this one.
rm -rf "$APP_DEST"
# ditto rather than cp -R: it carries extended attributes and the code
# signature across intact, so TCC still recognizes the app and does not
# re-prompt for every permission it was already granted.
ditto Opus.app "$APP_DEST"
codesign --verify --deep --strict "$APP_DEST"
rm -rf Opus.app

echo "✔ Opus installed at $APP_DEST ($SIZE)"
if (( WAS_RUNNING )); then
    echo "  ⚠ Opus is running the PREVIOUS build — quit and relaunch to pick this one up."
fi
