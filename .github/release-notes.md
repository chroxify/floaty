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
