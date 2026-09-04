#!/bin/bash
# Cuts a release:
#
#   ./release.sh v1.0.0
#
# Tags the current commit and pushes it. GitHub Actions does the rest
# (.github/workflows/release.yml): stamps the version from the tag, builds a
# universal binary, packages it, and publishes the release with install notes.
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

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree isn't clean — commit first so the tag matches the source." >&2
  git status --short >&2
  exit 1
fi
if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Release from main, not $(git branch --show-current)." >&2
  exit 1
fi
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "$VERSION already exists." >&2
  exit 1
fi

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

echo "→ Tagging ${VERSION}…"
git tag -a "$VERSION" -m "Floaty ${VERSION#v}"
# Two pushes, not one: a tag that arrives in the same push as the commit it
# points at can fail to start its workflow.
git push origin main
git push origin "$VERSION"

echo "→ Waiting for the build…"
RUN=""
for _ in $(seq 1 12); do
  sleep 5
  RUN=$(gh run list --workflow=release.yml --branch "$VERSION" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  [[ -n "$RUN" ]] && break
done
if [[ -n "$RUN" ]]; then
  gh run watch "$RUN" --exit-status
  echo "✓ https://github.com/$REPO/releases/tag/$VERSION"
else
  echo "  No run started within a minute: https://github.com/$REPO/actions" >&2
  exit 1
fi
