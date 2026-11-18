#!/bin/zsh
# Installs the built app into ~/Applications (or /Applications with --system),
# makes it the only registered copy, and starts the helper.
set -euo pipefail
ROOT=${0:A:h:h}
DEST="$HOME/Applications"
[[ "${1:-}" == "--system" ]] && DEST="/Applications"
SRC="$ROOT/build/Safari Agent.app"
[ -d "$SRC" ] || { echo "Build first: scripts/build.sh" >&2; exit 1; }
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pkill -f "Safari Agent.app/Contents/MacOS/Safari Agent" 2>/dev/null || true
sleep 1
mkdir -p "$DEST"
rm -rf "$DEST/Safari Agent.app"
ditto --norsrc --noextattr --noacl "$SRC" "$DEST/Safari Agent.app"
"$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$ROOT/build/DerivedData/Build/Products/Debug/Safari Agent.app" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$ROOT/build/DerivedData/Build/Products/Release/Safari Agent.app" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST/Safari Agent.app"
open "$DEST/Safari Agent.app" --args --background
echo "Installed: $DEST/Safari Agent.app"
