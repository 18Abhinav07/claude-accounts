#!/bin/bash
# Builds "Claude Accounts.app" and installs it plus the claude-account CLI.
set -euo pipefail
cd "$(dirname "$0")"

CLAUDE_APP="/Applications/Claude.app"
STORE="$HOME/Library/Application Support/Claude-Accounts"
DEST="/Applications/Claude Accounts.app"
BUILD="build/Claude Accounts.app"

[ -d "$CLAUDE_APP" ] || { echo "Claude desktop app not found at $CLAUDE_APP"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found. Install the tools with: xcode-select --install"; exit 1; }

echo "→ Installing CLI to $STORE/bin/claude-account"
mkdir -p "$STORE/bin"
install -m 755 bin/claude-account "$STORE/bin/claude-account"

echo "→ Building app"
rm -rf build; mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14" app/main.swift \
  -o "$BUILD/Contents/MacOS/ClaudeAccounts"
cp app/Info.plist "$BUILD/Contents/Info.plist"
# Reuse the icon from your own Claude install (not redistributed in this repo).
[ -f "$CLAUDE_APP/Contents/Resources/electron.icns" ] && \
  cp "$CLAUDE_APP/Contents/Resources/electron.icns" "$BUILD/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$BUILD" 2>/dev/null

echo "→ Installing to $DEST"
if [ -d "$DEST" ]; then mv "$DEST" "$STORE/previous-app-$(date +%s).app"; fi
ditto "$BUILD" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true

echo "✓ Done. Open \"Claude Accounts\" from Applications or Spotlight."
