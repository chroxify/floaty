#!/bin/bash
# Builds Floaty.app. Pass --install to also copy it into /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"

APP="Floaty.app"
BUILD_DIR=".build/release"

echo "→ Compiling…"
swift build -c release

echo "→ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/Floaty" "$APP/Contents/MacOS/Floaty"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/Floaty.icns "$APP/Contents/Resources/Floaty.icns"

# The icon is an Icon Composer bundle. actool compiles it into an Assets.car,
# which is what gives macOS 26 the real glass treatment; the committed .icns is
# the fallback when Xcode isn't installed.
#
# The path must be absolute: actool resolves the input by basename against its
# working directory, so a relative path silently reports "no such file".
if xcrun --find actool >/dev/null 2>&1; then
  ICONTMP=$(mktemp -d)
  if xcrun actool --compile "$ICONTMP" --app-icon Floaty --platform macosx \
       --minimum-deployment-target 26.0 \
       --output-partial-info-plist "$ICONTMP/partial.plist" \
       "$PWD/Resources/Floaty.icon" >/dev/null 2>&1 && [ -f "$ICONTMP/Assets.car" ]; then
    cp "$ICONTMP/Assets.car" "$APP/Contents/Resources/Assets.car"
    [ -f "$ICONTMP/Floaty.icns" ] && cp "$ICONTMP/Floaty.icns" "$APP/Contents/Resources/Floaty.icns"
    echo "  (compiled Floaty.icon)"
  else
    echo "  (actool failed; using the committed Floaty.icns)"
  fi
  rm -rf "$ICONTMP"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ Signing…"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "  (ad-hoc signing failed — the app will still run)"

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installing to /Applications…"
  osascript -e 'quit app "Floaty"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/$APP"
  cp -R "$APP" "/Applications/$APP"
  open "/Applications/$APP"
  echo "✓ Floaty is running. Press ⌃Space to toggle it."
else
  echo "✓ Built ./$APP  —  run ./build.sh --install to put it in /Applications"
fi
