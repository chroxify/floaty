#!/bin/bash
# One-command install:
#
#   curl -fsSL https://raw.githubusercontent.com/chroxify/floaty/main/install.sh | bash
#
# Downloads the latest release, puts it in /Applications and launches it.
#
# It also strips the quarantine flag macOS attaches to anything that arrives
# over the network. Floaty is ad-hoc signed rather than notarized — there's no
# Apple Developer ID behind it — so without that step macOS refuses to open it
# and claims the app is "damaged", which it isn't. If you'd rather not take that
# on trust, build from source instead: the repo's README has the two lines, and a
# locally compiled app is never quarantined in the first place.
set -euo pipefail

REPO="chroxify/floaty"
NAME="Floaty"
# FLOATY_ZIP_URL lets release.sh test an archive before it's published.
ZIP_URL="${FLOATY_ZIP_URL:-https://github.com/$REPO/releases/latest/download/$NAME.zip}"

# Prefer /Applications, fall back to the user's own folder if it isn't writable.
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "→ /Applications isn't writable; installing to $DEST"
fi
APP="$DEST/$NAME.app"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading the latest release…"
if ! curl -fL --progress-bar "$ZIP_URL" -o "$TMP/$NAME.zip"; then
  echo "Couldn't download $ZIP_URL" >&2
  echo "Check https://github.com/$REPO/releases for a published release." >&2
  exit 1
fi

echo "→ Installing to ${DEST}…"
# Quit a running copy first, or the replace lands under a live process.
osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
sleep 1

# Replace the bundle whole rather than editing it in place: macOS's App
# Management protection can refuse writes inside an app that's been launched,
# but removing it outright is allowed.
if ! rm -rf "$APP" 2>/dev/null; then
  echo "Couldn't remove the existing $APP" >&2
  echo "Move it to the Trash yourself and run this again." >&2
  exit 1
fi
# ditto, not unzip: it restores the bundle's symlinks and extended attributes,
# which a plain unzip mangles enough to break the signature.
ditto -x -k "$TMP/$NAME.zip" "$DEST"

if [[ ! -d "$APP" ]]; then
  echo "The archive didn't contain $NAME.app" >&2
  exit 1
fi

# The reason this script exists rather than a download link.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "→ Launching…"
open "$APP"
echo "✓ Installed. Press ⌃Space to summon it."
