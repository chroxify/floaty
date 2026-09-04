#!/bin/bash
# Cuts a GitHub release:
#
#   ./release.sh v1.0.0
#
# Builds the app, packages it, and publishes it with install instructions.
# The version is written into the bundle so About/Finder agree with the tag.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: ./release.sh v1.0.0" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version should look like v1.0.0" >&2
  exit 1
fi
SHORT="${VERSION#v}"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree isn't clean — commit first so the tag matches the source." >&2
  git status --short >&2
  exit 1
fi

echo "→ Stamping $SHORT into the bundle…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SHORT" Resources/Info.plist

echo "→ Building…"
./build.sh >/dev/null

echo "→ Packaging…"
rm -f "Floaty.zip"
# ditto, not zip: it preserves the bundle's symlinks and extended attributes,
# which a plain zip mangles enough to break the signature.
ditto -c -k --sequesterRsrc --keepParent Floaty.app Floaty.zip

# Written to a file rather than a variable: bash 3.2, which macOS still ships,
# mis-parses apostrophes in a heredoc nested inside $(). Quoted delimiter means
# nothing expands, so backticks stay literal; $REPO is filled in after.
NOTES_FILE="$TMP/notes.md"
cat > "$NOTES_FILE" <<'EOF'
### Install

```bash
curl -fsSL https://raw.githubusercontent.com/{{REPO}}/main/install.sh | bash
```

That downloads this release, puts it in `/Applications`, and launches it.

It also removes the quarantine flag macOS attaches to anything downloaded.
Floaty is ad-hoc signed rather than notarized — there's no Apple Developer ID
behind it — so without that, macOS refuses to open it and says the app is
"damaged", which it isn't.

Prefer not to take that on trust? Build it yourself. A locally compiled app is
never quarantined, so there's nothing to strip:

```bash
git clone https://github.com/{{REPO}}.git
cd floaty && ./build.sh --install
```

Then press `⌃Space`.
EOF
sed -i '' "s|{{REPO}}|$REPO|g" "$NOTES_FILE"

echo "→ Releasing $VERSION…"
git add Resources/Info.plist
git commit -m "Release $VERSION" >/dev/null
git tag "$VERSION"
git push && git push --tags

gh release create "$VERSION" Floaty.zip --title "Floaty $SHORT" --notes-file "$NOTES_FILE"

rm -f Floaty.zip
echo "✓ https://github.com/$REPO/releases/tag/$VERSION"
