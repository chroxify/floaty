# Floaty

A menubar-only macOS app that keeps one web page floating above everything else.

No Dock icon, no app switcher entry, no title bar, no traffic lights, no toolbar,
no URL bar, no scrollbars. Just a tab strip and the page. Everything else is a
keystroke or a menu item.

## Install

```bash
./build.sh --install
```

Builds `Floaty.app`, copies it to `/Applications` and launches it. Leave off
`--install` to build in place. The app is ad-hoc signed, so the first launch may
need a right-click → **Open**.

## Use

On first launch it asks for a link, once. After that, **⌃Space** from anywhere
summons the page and **⌃Space** (or **esc**) sends it away.

**⌘T** opens another tab, **⌘L** points the current one somewhere else, and
**⌘1**…**⌘9** jumps between them. Everything else — always-on-top, Spaces,
size, opacity, tabs, launch at login, rebinding the global shortcut —
lives behind the menubar icon.

## Shortcuts

| | |
|---|---|
| Show / hide (global) | `⌃Space` |
| Swap focus with the window behind | `⌥⇥` |
| Hide | `esc` |
| Open a page | `⌘L` |
| Copy page link | `⇧⌘C` |
| Move the window | drag the tab strip, double-click-drag, or `⌘` + drag |
| Reload / hard reload | `⌘R` / `⇧⌘R` |
| Back / forward | `⌘[` / `⌘]` |
| Zoom in / out / reset | `⌘+` / `⌘-` / `⌘0` |
| Always on top | `⌥⌘P` |
| Dock to window on / off | `⌥⌘D` |
| Opacity up / down | `⌥⌘↑` / `⌥⌘↓` |
| New tab | `⌘T` |
| Close tab | `⌘W` |
| Jump to tab | `⌘1`…`⌘9` |
| Tab switcher (hold, preview) | `⌃⇥` / `⌃⇧⇥` |
| Next / previous tab, no preview | `⇧⌘]` / `⇧⌘[` |
| Quit | `⌘Q` |

The field takes searches too — anything that isn't host-shaped goes to Google.
`localhost:3000` resolves over http, everything else over https.

## Notes

- **Moving the window**: drag the tab strip, the way you would a title bar —
  anywhere on it, tabs included. Tabs stretch to fill the strip, so if only the
  gaps between them dragged there would be almost nothing to grab; dragging a tab
  moves the window instead, which is free because there's no tab reordering to
  conflict with. Selection lands on mouse *up*, so starting a drag from a tab
  never switches to it on the way past; a 3pt threshold keeps click jitter from
  reading as a drag.

  Two fallbacks for when the strip isn't reachable: double-click and keep
  dragging, or `⌘`-drag. Double-click-drag costs word-by-word selection
  extension; `⌘`-drag costs `⌘`-click on a link.

  A double-click drag **freezes the page** for its duration — the selection the
  double-click made is cleared, and `user-select` and `pointer-events` are
  suppressed until you let go. The double-click has already selected a word by
  the time the drag begins, so without this the page keeps that selection and
  goes on reacting to the pointer while the window slides out from under it.

  A gesture-detecting version was tried and removed: drag empty page area
  immediately, drag elsewhere only on a hard flick. Even with DOM hit-testing
  behind it, it occasionally grabbed the window mid-selection, and a modifier
  that always means one thing beats a heuristic that is usually right.
- **Swap focus** (`⌥⇥`) moves between Floaty and the window behind it — the
  docked window if there is one, otherwise the app you were last in — leaving both
  on screen. It's deliberately a *separate* key from show/hide rather than ⌃Space
  changing meaning when docked: merging them made hiding a docked window
  impossible, and a shortcut that does two different things depending on state is
  one you have to stop and think about.

  It acts only when Floaty or that one window is frontmost. And rather than
  registering it everywhere and declining to act, it's registered *only* while one
  of the two is frontmost — a Carbon hotkey swallows its key system-wide, so an
  inert binding would still eat `⌥⇥` in every other app.
- **The global shortcuts** use Carbon's `RegisterEventHotKey`, so they need no
  Accessibility permission. If another app already owns a combo, Floaty names the
  action that won't work and you can rebind it from the menu.
- **No menu bar** (accessory apps don't get one), so every shortcut — including
  `⌘C` / `⌘V` — is resolved in `FloatyPanel.performKeyEquivalent`.
- **Scrollbars** are hidden by a user script injected at document start. The page
  still scrolls.
- **Cursors** are forced to the native pair — arrow everywhere, I-beam over text.
  The web's pointing hand has no equivalent in AppKit and is the clearest tell
  that a window is a browser. Same script also strips the browser items (Reload,
  Back, Forward, open-in-new-window) out of the right-click menu.
- **The switcher walks most-recently-used order by default**, so the tab you came
  from is one step away — the system app switcher's behaviour. Left-to-right bar
  order is the other option, under "⌃⇥ Cycles By" in the menu. Recency has to be
  tracked as you go; it can't be reconstructed afterwards.
- **The switcher ignores hover until the pointer moves.** AppKit sends
  `mouseEntered` for a tracking area created underneath a stationary cursor, so a
  panel opening beneath the pointer would pin the selection to whatever it
  happened to be over — and ⌃⇥ would appear not to work at all. The hover handler
  latches on once the pointer has genuinely moved more than 2pt.
- **The switcher** closes on blur. Switching apps mid-hold means the ⌃ release
  never arrives, so it would otherwise sit there forever.
- **The switcher is `⌃⇥`, not `⌘⇥`.** The WindowServer claims `⌘⇥` before any app
  sees it; taking it would need a CGEventTap behind an Accessibility prompt and
  would break the real app switcher.
- **Docking** glues the window to another app's, 8pt off one side, following it
  as it moves and resizes. Under "Dock to Window": *Active Window* retargets as
  you switch apps, or tick a **whitelist** of apps and it follows whichever of
  those is frontmost.

  With a whitelist, **Only While Focused** (on by default) hides Floaty whenever
  you're not in one of those apps — a window docked to something you're not
  looking at is just clutter. Floaty itself counts as focused, or clicking it
  would dismiss it. Auto-showing uses `orderFront`, never activation: you're
  working in the other app, and stealing focus to reveal a panel would be
  maddening. Hiding it yourself still wins until you bring it back.

  Whitelisted apps stay listed even after they quit, so closing an app doesn't
  silently drop it from the set.

  Tracking polls `CGWindowListCopyWindowInfo`, which reads other apps' window
  frames with **no Accessibility permission** — the same reason the hotkey uses
  Carbon. An `AXObserver` would deliver moves as events instead of samples, but it
  puts a permission prompt in front of a feature you haven't tried yet. A poll
  costs ~0.3ms; the loop runs at 60Hz — one poll per display frame — while the
  parent is moving, and drops to 10Hz once it's still. Polling faster than the
  screen redraws only produces samples nobody sees.

  It follows **live**, during the drag. The trick is not confusing whose window
  is being dragged: `NSEvent.pressedMouseButtons` is system-wide, so holding the
  button anywhere looked like dragging Floaty, which froze the dock for the whole
  of the parent's drag and made it snap only on release. The real test is whether
  *our* frame moved without us moving it.

  Velocity projection was tried on top of that — predict a frame ahead to cancel
  the sampling lag — and removed. It measured as noise and read as wobble, because
  every prediction gets corrected on the next sample. Trailing cleanly by one
  frame looks better than being right on average.

  `⌥⌘D` toggles docking without opening the menu, returning to whichever target
  you last picked rather than resetting to a default.

  Left and right only. Docking above or below would fight the menu bar and the
  Dock, and a window is usually taller than it is wide, so the sides are where
  the room is.

  **Drag it up or down to set its height** along the parent, and that offset
  sticks. It defaults to the same 8pt used horizontally, so a docked window is
  inset evenly rather than flush against the parent's top edge. The offset is
  measured from the parent's *top* edge, so the pairing holds when the parent is
  resized from the bottom. Drop it on the other side and
  it re-docks there (in Auto; a manual Left/Right stays put). "Align to Top"
  resets the offset.

  It follows the app's **main window**, not whatever it happens to put in front.
  Alerts, sheets, save dialogs and popovers are all layer 0 as well, and they
  arrive frontmost, so simply taking the front window meant an alert stole the
  dock and Floaty jumped to it. They're small next to the document window they
  interrupt, so anything under 60% of the biggest window's area is discarded and
  the frontmost of what remains wins — which keeps retargeting working for apps
  with several real windows of differing sizes.

  If the target has no window right now — minimised, or between windows — Floaty
  stays where it is rather than flinging itself somewhere.
- **Focus Inputs on Foreground** (off by default) puts the caret in the page's
  main text field whenever Floaty comes to the front, however it got there —
  shortcut, menu, dock, or a click. Right for a chat or search page, wrong for one
  you're only reading, where it would hijack space-to-scroll. "Main" is the
  largest text field actually visible, which skips honeypots, collapsed search
  boxes and off-screen fields.

  It runs twice: once immediately, and again 150ms later. When focus arrives from
  a click, the mouse event is dispatched *after* the window becomes key, and
  clicking bare page area blurs whatever was just focused — the second pass puts
  the caret back. The repeat is harmless because the script leaves an
  already-focused field alone, so clicking into a different input keeps that one.
- **Clicks act immediately.** AppKit swallows the first click into an inactive
  window — it only brings the window forward — so hopping between Floaty and the
  window it's docked to would cost two clicks every time. `acceptsFirstMouse`
  returns true on the page, the tab strip and the tabs, so the click that focuses
  also does the thing.

  Coming back the other way is up to the other app: whether *its* first click
  acts is its own `acceptsFirstMouse`, and nothing here can change that. **Never
  Take Focus** in the Dock menu sidesteps it by making Floaty a non-activating
  panel — click and scroll it without the other app ever losing focus, so there's
  no round trip to pay for. Only the active app receives keystrokes, so that mode
  costs typing into the page; ⌃Space still activates properly when you want it.
- Window position, size, opacity, pin state and last URL persist across launches.

## Icon

`Resources/Floaty.icon` is an Icon Composer bundle. `build.sh` compiles it with
`actool` into an `Assets.car`, which is what gives macOS 26 the glass treatment;
`Resources/Floaty.icns` is the committed fallback for machines without Xcode.

`actool` resolves its input by basename against the working directory, so the
path passed to it has to be absolute or it reports "no such file" and silently
falls back.

**On tinted and dark variants:** shipping a `.icon` means `actool` also emits
`ISAppearanceTintable` and `NSAppearanceNameDarkAqua` assets, derived from the
layers. There is no opt-out. Which one macOS shows is a *system-wide user
setting* (System Settings → Appearance → icon style), not an app choice — pick
Tinted and every icon on the machine is tinted.

Hand-editing `icon.json` to pin those variants doesn't work: `dark` and `tinted`
appear in the format's vocabulary, but adding them at the top level or inside a
layer both produced byte-identical tinted assets, so the overrides have to be
authored in Icon Composer itself. The only way to ship no variants at all is a
plain `.icns` with no asset catalog, which forfeits the glass.

## Design

Nested radii are concentric — `outer = inner + padding` — and the switcher is
where that chain is load-bearing: panel `24` over `8` padding, cell `16` over `8`
inset, preview `8`. Changing the padding means changing two radii with it.

Follows the buzzkit design system (`buzzkit/docs/design.md`), translated to
AppKit in `Theme.swift`: Open Runde at one weight, hierarchy from size and the
`fg` ramp, superellipse corners, hairline rings instead of borders, semantic
colors so both themes and Increase Contrast follow the system, and motion only on
state changes — nothing animates on arrival.

## Layout

```
Sources/Floaty/
  main.swift                  entry point, .accessory activation policy
  AppDelegate.swift           hotkey wiring, window state, app lifecycle
  StatusMenu.swift            everything the menubar item shows
  FloatyPanel.swift           borderless floating panel, key handling, ⌘-drag
  BrowserViewController.swift hosts the tab strip and the active page
  Tab.swift                   one page: its web view, title and favicon
  TabBarView.swift            the tab strip, and the window's grab handle
  TabSwitcher.swift           the ⌃⇥ preview switcher
  WindowDock.swift            glues the window to another app's window
  DoubleClickDrag.swift       double-click-then-drag to move the window
  SetupView.swift             the "enter a link" card — the only UI Floaty draws
  Theme.swift                 design tokens
  HotKeyManager.swift         Carbon global hotkey registration
  URLNormalizer.swift         typed text -> URL
  Prefs.swift                 UserDefaults-backed settings
```
