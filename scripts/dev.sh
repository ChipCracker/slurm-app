#!/usr/bin/env bash
#
# Build & launch "Slurmy Dev" (Debug) for local development with live hot reloading.
#
#   scripts/dev.sh            # build Debug + launch; connects to the real cluster
#   scripts/dev.sh --mock     # same, but with mock data (SLURMIOS_UIMOCK=1), no SSH
#
# Debug == "Slurmy Dev" (de.cwitzl.slurmapp.dev, own Keychain, orange DEV icon),
# so this never disturbs the installed stable "Slurmy". The Debug config is linked
# with `-Xlinker -interposable` (project.yml) and built here with hardened runtime
# OFF so the InjectionIII helper can live-swap code into the running app.
#
# Unlike scripts/install.sh (which builds Release into /Applications and does NOT
# hot-reload), this runs the app straight from DerivedData — keep it there so the
# Debug `.debug.dylib` resolves, and so InjectionIII finds the build's compile
# flags (it scans the default DerivedData logs).
#
# ── HOT RELOAD ────────────────────────────────────────────────────────────────
#   1) Install InjectionIII  →  https://github.com/johnno1962/InjectionIII/releases
#                                (or the Mac App Store)
#   2) Launch it, menu-bar icon → "Open Project" → pick this repo's folder.
#   3) Run this script, leave the app running.
#   4) Edit a .swift file + ⌘S → the change appears live, no restart.
#      The console prints "💉 Injection connected" once it's hooked in.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MOCK=0
case "${1:-}" in
  --mock) MOCK=1 ;;
  "")     ;;
  *)      echo "usage: $(basename "$0") [--mock]" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

echo "▸ Regenerating project (xcodegen)…"
xcodegen generate >/dev/null

# Build args shared by `build` and `-showBuildSettings` so the resolved app path
# matches the build. No -derivedDataPath → default DerivedData (InjectionIII reads
# its build logs from there). Hardened runtime off so injection can load its bundle.
ARGS=(
  -project SlurmApp.xcodeproj -scheme SlurmApp
  -configuration Debug -destination 'platform=macOS,arch=arm64'
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
  ENABLE_HARDENED_RUNTIME=NO
)

echo "▸ Building Debug (Slurmy Dev)…"
xcodebuild "${ARGS[@]}" build >/dev/null

APP="$(xcodebuild "${ARGS[@]}" -showBuildSettings 2>/dev/null \
  | sed -n 's/.*CODESIGNING_FOLDER_PATH = //p' | head -1)"
[ -d "$APP" ] || { echo "✗ build product not found ($APP)" >&2; exit 1; }

# Sign so it launches. Prefer the stable "Slurmy Local" identity so saved
# credentials survive rebuilds; fall back to ad-hoc if it's missing.
SIGN_ARG="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Slurmy Local"; then
  SIGN_ARG="Slurmy Local"
fi
echo "▸ Signing ($SIGN_ARG)…"
codesign --force --deep --sign "$SIGN_ARG" "$APP" 2>/dev/null

# Start the InjectionIII hot-reload server (menu-bar agent) so the app can
# connect on launch. It's sandboxed, so it can only WATCH a folder the user
# granted via its open panel once — `open -a … <repo>` pre-points it at the repo,
# but the one-time grant (menu-bar icon → select this folder) is still required.
HOTRELOAD=0
if [ -d "/Applications/InjectionIII.app" ]; then
  open -g -a InjectionIII 2>/dev/null || true
  HOTRELOAD=1
fi

echo "▸ Launching Slurmy Dev…"
# Launch the binary directly (not `open`) so INJECTION_DIRECTORIES reaches the
# app — that's how the injection bundle knows which sources belong to it.
LOG=/tmp/slurmy-dev.log
ENV_ARGS=(INJECTION_DIRECTORIES="$REPO")
[ "$MOCK" = "1" ] && { echo "  (mock data, no SSH — SLURMIOS_UIMOCK=1)"; ENV_ARGS+=(SLURMIOS_UIMOCK=1); }
env "${ENV_ARGS[@]}" nohup "$APP/Contents/MacOS/SlurmApp" >"$LOG" 2>&1 &
disown

if [ "$HOTRELOAD" = "1" ]; then
  echo "▸ InjectionIII running. ONE-TIME setup (macOS sandbox requires it):"
  echo "    click the InjectionIII menu-bar icon → select this folder:"
  echo "      $REPO"
  echo "    (it remembers the grant afterwards — future runs are automatic)"
  echo "  Then edit a .swift file + ⌘S → live reload, no restart. Log: $LOG"
else
  echo "ℹ︎ InjectionIII not installed — hot reload OFF. Install it:"
  echo "    https://github.com/johnno1962/InjectionIII/releases   (or Mac App Store)"
fi

echo "✓ Slurmy Dev launched from $APP"
