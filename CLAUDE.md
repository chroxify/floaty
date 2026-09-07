# Floaty — development notes

Floaty is a menubar-only macOS app (SwiftPM + `build.sh`, no Xcode project) that
floats web pages, mostly agent chats. The README is the design record; read its
Notes section before changing behaviour it describes.

## Commands

- `./build.sh --install` builds, installs to `/Applications`, relaunches.
- `./release.sh vX.Y.Z` tags and pushes; GitHub Actions builds and publishes.
  It refuses a dirty tree, a branch other than `main`, or a `main` that has
  diverged from `origin/main`.
- Scripts run under macOS `/bin/bash` 3.2: no empty-array `"${A[@]}"` under
  `set -u`, no heredoc inside `$()`, and write `${VAR}…` — a bare `$VAR…`
  swallows the ellipsis into the variable name.

## Kanna (the main thing Floaty floats)

Kanna lives at `~/Developer/Projects/kanna`, the user's fork of jakemor/kanna.
Floaty's page-status tags (`<meta name="floaty:status">`, see README) are set
by Kanna on the branch `feat/floaty-page-status`.

- **The Kanna checkout stays on `local`. Never check out another branch
  there, for any reason.** `kn` (`~/.local/bin/kn`) rebuilds `local` on every
  launch: reset to upstream `main`, merge every `fork/*` branch that isn't
  upstream yet, carry uncommitted work across via stash, rebuild `dist/`.
  Switching the tree to a feature branch drops every other feature from the
  running app.
- **Never commit on `local`** — it's regenerated each launch and the commit
  vanishes. Land a Kanna change on a `feat/*` branch *without leaving
  `local`*: use a worktree (`git worktree add /tmp/wt-x -b feat/x
  origin/main`, copy the change in, commit, `git push fork feat/x`, `git
  worktree remove /tmp/wt-x`). `kn` folds it in on the next launch. Don't
  merge into `local` by hand and don't restart the server — it serves
  `dist/client` from disk, and the running Kanna is the one the conversation
  happens in.
- Kanna uses zustand v5: a store selector that returns a new object every call
  loops React (error #185). Wrap it in `useShallow` from
  `zustand/react/shallow`.
