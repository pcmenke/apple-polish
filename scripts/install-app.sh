#!/usr/bin/env bash
# Build Apple Polish, install it to ~/Applications, and launch it.
# Signing identity comes from .bazelrc.user (see README), so the Full Disk Access grant
# survives rebuilds. Usage: ./scripts/install-app.sh [--no-launch]
set -euo pipefail
cd "$(dirname "$0")/.."

bazelisk build //:ApplePolish
workspace="$(bazelisk info workspace)"
zip="$workspace/$(bazelisk cquery --output=files //:ApplePolish 2>/dev/null)"

dest="$HOME/Applications"
mkdir -p "$dest"
osascript -e 'tell application "Apple Polish" to quit' 2>/dev/null || true
rm -rf "$dest/Apple Polish.app"
ditto -xk "$zip" "$dest"
codesign -dv "$dest/Apple Polish.app" 2>&1 | grep -E "Identifier|Authority=Apple Development|Signature|TeamIdentifier" || true
echo "Installed $dest/Apple Polish.app"
[[ "${1:-}" == "--no-launch" ]] || launchctl asuser "$(id -u)" open "$dest/Apple Polish.app"
