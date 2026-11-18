#!/bin/zsh
# Installs the built app into ~/Applications (or /Applications with --system),
# makes it the only registered copy, and starts it in the background.
# Orbit was called "Safari Agent" before 1.0 (and briefly "Bearing"); an old copy is replaced (same
# bundle identifier, so Safari keeps the extension, its settings and history).
set -euo pipefail
ROOT=${0:A:h:h}
DEST="$HOME/Applications"
[[ "${1:-}" == "--system" ]] && DEST="/Applications"
SRC="$ROOT/build/Orbit.app"
[ -d "$SRC" ] || { echo "Build first: scripts/build.sh" >&2; exit 1; }
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Quit the running app and wait until it is really gone; otherwise `open` below
# would just re-activate the old process and keep running the old code.
PATTERN='(Orbit|Bearing|Safari Agent)\.app/Contents/MacOS/'
pkill -f "$PATTERN" 2>/dev/null || true
for _ in {1..50}; do pgrep -f "$PATTERN" >/dev/null || break; sleep 0.1; done
pkill -9 -f "$PATTERN" 2>/dev/null || true
mkdir -p "$DEST"
for old in "$DEST/Safari Agent.app" "$DEST/Bearing.app" "$ROOT/build/Safari Agent.app" "$ROOT/build/Bearing.app"; do
  if [ -d "$old" ]; then "$LSREGISTER" -u "$old" >/dev/null 2>&1 || true; rm -rf "$old"; fi
done
rm -rf "$DEST/Orbit.app"
ditto --norsrc --noextattr --noacl "$SRC" "$DEST/Orbit.app"
"$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
for c in Debug Release; do
  "$LSREGISTER" -u "$ROOT/build/DerivedData/Build/Products/$c/Orbit.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$ROOT/build/DerivedData/Build/Products/$c/Safari Agent.app" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f "$DEST/Orbit.app"
open "$DEST/Orbit.app" --args --background
echo "Installed: $DEST/Orbit.app"
