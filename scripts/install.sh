#!/usr/bin/env bash
#
# Build, sign and install Slurmy into /Applications so the latest build is
# always one click away in the Dock / Launchpad.
#
#   scripts/install.sh prod   → "Slurmy"     (de.cwitzl.slurmapp)      production icon
#   scripts/install.sh dev    → "Slurmy Dev" (de.cwitzl.slurmapp.dev)  orange DEV-ribbon icon
#
# Both flavours coexist (distinct bundle ids → distinct Dock entries and
# distinct Keychain credentials), so a dev build never disturbs your daily
# driver. Day-to-day development from Xcode uses the Debug config, which already
# carries the dev identity (see project.yml `configs.Debug`).
#
# Why always Release: a Debug build wraps a separate SlurmApp.debug.dylib loaded
# via @rpath that fails to load once installed standalone. Release is one
# self-contained binary that installs and signs cleanly.
# (see memory/build-run-workflow.md)
#
# Why sign with "Slurmy Local": saved credentials are a Keychain item bound to
# the code-signing identity. A *stable* identity keeps them across rebuilds;
# ad-hoc signing would force a password re-entry on every launch.
#
set -euo pipefail

FLAVOR="${1:-}"
case "$FLAVOR" in
  prod) BUNDLE_ID="de.cwitzl.slurmapp";     DISPLAY="Slurmy";     ICON="AppIcon";    APP_NAME="Slurmy" ;;
  dev)  BUNDLE_ID="de.cwitzl.slurmapp.dev"; DISPLAY="Slurmy Dev"; ICON="AppIconDev"; APP_NAME="Slurmy Dev" ;;
  *)    echo "usage: $(basename "$0") {dev|prod}" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_ID="Slurmy Local"
DEST="/Applications/${APP_NAME}.app"

cd "$REPO"

# Fall back to ad-hoc signing if the stable identity is missing (credentials
# then won't persist across rebuilds, but the app still launches locally).
SIGN_ARG="$SIGN_ID"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "⚠︎  Code-signing identity '$SIGN_ID' not found — falling back to ad-hoc (-)."
  echo "    Saved credentials will not survive rebuilds. See memory/build-run-workflow.md to recreate it."
  SIGN_ARG="-"
fi

echo "▸ Regenerating project (xcodegen)…"
xcodegen generate >/dev/null

# Keep the dev icon set in sync with the production master on every dev install.
if [ "$FLAVOR" = "dev" ]; then
  echo "▸ Refreshing dev icon (make-dev-icon.py)…"
  python3 "$REPO/scripts/make-dev-icon.py" >/dev/null
fi

COMMON_ARGS=(
  -project SlurmApp.xcodeproj -scheme SlurmApp
  -configuration Release -destination 'platform=macOS'
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  INFOPLIST_KEY_CFBundleDisplayName="$DISPLAY"
  ASSETCATALOG_COMPILER_APPICON_NAME="$ICON"
)

echo "▸ Building Release ($FLAVOR)…"
xcodebuild "${COMMON_ARGS[@]}" build >/dev/null

APP_PATH="$(xcodebuild "${COMMON_ARGS[@]}" -showBuildSettings 2>/dev/null \
  | sed -n 's/.*CODESIGNING_FOLDER_PATH = //p' | head -1)"
[ -d "$APP_PATH" ] || { echo "✗ build product not found ($APP_PATH)" >&2; exit 1; }

echo "▸ Installing → $DEST"
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"

echo "▸ Signing with '$SIGN_ARG'…"
codesign --force --deep --options runtime --sign "$SIGN_ARG" "$DEST"

echo "▸ Refreshing icon cache…"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" || true
rm -rf ~/Library/Caches/com.apple.iconservices.store 2>/dev/null || true
killall Dock 2>/dev/null || true

echo "✓ Installed $APP_NAME  ($BUNDLE_ID)"
echo "  open \"$DEST\""
