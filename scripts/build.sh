#!/bin/zsh
# Builds the web extension and the macOS app (helper + Safari extension).
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
ROOT=${0:A:h:h}
CONFIG=${1:-Release}
cd "$ROOT/extension"
[ -d node_modules ] || npm ci
npm run --silent typecheck
node build.mjs
cd "$ROOT/native"
# Signing. With an Apple Development certificate (any Apple ID added in Xcode → Settings →
# Accounts, a free personal team is enough), the app is signed for your team and Safari keeps
# the extension enabled across restarts. Without one, it is signed ad hoc ("Sign to Run
# Locally"), which needs Safari's "Allow unsigned extensions" after every Safari launch.
# Override with TEAM_ID=XXXXXXXXXX or SIGN_IDENTITY="<identity>".
SIGN_ARGS=()
if [ -z "${TEAM_ID:-}" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
  CERT_SUBJECT=$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null || true)
  TEAM_ID=$(print -r -- "$CERT_SUBJECT" | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
fi
if [ -n "${TEAM_ID:-}" ]; then
  echo "Signing for team $TEAM_ID (Apple Development)"
  SIGN_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates)
elif [ -n "${SIGN_IDENTITY:-}" ]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY")
else
  echo "No Apple Development certificate found — signing ad hoc (Safari needs “Allow unsigned extensions”)."
fi
xcodebuild -project SafariAgent.xcodeproj -scheme SafariAgent -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" "${SIGN_ARGS[@]}" build -quiet 2>&1 | grep -vE "appintentsmetadataprocessor|^\s*$|warning:|^\s+\||SendableClosure|ImplicitStrong" || true
APP="$ROOT/build/DerivedData/Build/Products/$CONFIG/Safari Agent.app"
[ -d "$APP" ] || { echo "Build failed: $APP missing" >&2; exit 1; }
rm -rf "$ROOT/build/Safari Agent.app"
ditto --norsrc --noextattr --noacl "$APP" "$ROOT/build/Safari Agent.app"
# Keep exactly one registered copy so Safari never loads the extension from two places:
# the installed app if there is one (update it with scripts/install.sh), otherwise build/.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
if [ -d "$HOME/Applications/Safari Agent.app" ] || [ -d "/Applications/Safari Agent.app" ]; then
  "$LSREGISTER" -u "$ROOT/build/Safari Agent.app" >/dev/null 2>&1 || true
  echo "Note: an installed copy exists — run scripts/install.sh to update it."
else
  "$LSREGISTER" -f "$ROOT/build/Safari Agent.app" >/dev/null 2>&1 || true
fi
echo "Built: $ROOT/build/Safari Agent.app"
