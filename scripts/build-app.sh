#!/bin/sh
# Builds an unsigned (ad-hoc signed) PaperVeil.app and a zip into the given output dir.
# Usage: scripts/build-app.sh [outdir]   (default: ./build)
set -eu
OUT="${1:-build}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product PaperVeil
BIN="$(swift build -c release --show-bin-path)/PaperVeil"
APP="$OUT/PaperVeil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaperVeil"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App-Icon: Icon-Composer-Datei → Assets.car (+ .icns-Fallback) per actool
xcrun actool "$ROOT/Resources/PaperVeil.icon" --compile "$(cd "$APP/Contents/Resources" && pwd)" --platform macosx \
  --minimum-deployment-target 27.0 --app-icon PaperVeil \
  --output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null
# Ad-hoc signature only: no Developer ID, not notarized (see README "Signierung").
codesign --force --sign - --timestamp=none "$APP"
(cd "$OUT" && rm -f PaperVeil.zip && ditto -c -k --keepParent PaperVeil.app PaperVeil.zip)
echo "Built $APP and $OUT/PaperVeil.zip"
