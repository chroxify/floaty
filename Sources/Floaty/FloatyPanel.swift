import AppKit
import Carbon.HIToolbox

/// A borderless, chromeless floating panel. No title bar, no traffic lights.
/// Because Floaty runs as an accessory app there is no menu bar either, so every
/// keyboard shortcut — including the standard editing ones — is resolved here.
final class FloatyPanel: NSPanel {

    weak var controller: BrowserViewController?
    var onHide: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onOpacityChange: ((Double) -> Void)?
    var onEditURL: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onNewTabAnywhere: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onSelectTab: ((Int) -> Void)?
    var onCycleTab: ((Int) -> Void)?
    var onSwitcherStep: ((Int) -> Void)?
    var onCopyURL: (() -> Void)?
    var onToggleDock: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isMovableByWindowBackground = false // ⌘-drag handles moving instead
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        minSize = NSSize(width: 280, height: 200)

        // The window is its own rounded surface, so the frame must be transparent
        // and the shadow has to come from us.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var contentView: NSView? {
        didSet {
            guard let contentView else { return }
            contentView.wantsLayer = true
            contentView.layer?.applySuperellipse(Theme.Radius.card)
        }
    }

    /// Returns true when the switcher was open and swallowed the key.
    var onSwitcherCancel: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let cmd: NSEvent.ModifierFlags = .command
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]

        // No menu bar means no free ⌘C/⌘V/⌘X/⌘A/⌘Z — route them down the responder
        // chain. This runs before anything else so the editing shortcuts work
        // inside the setup field too, and so they can't be rebound out from under
        // a text field.
        if flags == cmd || flags == cmdShift {
            let editing: Selector? = {
                switch (flags, key) {
                case (cmd, "c"): return #selector(NSText.copy(_:))
                case (cmd, "v"): return #selector(NSText.paste(_:))
                case (cmd, "x"): return #selector(NSText.cut(_:))
                case (cmd, "a"): return #selector(NSText.selectAll(_:))
                case (cmd, "z"): return Selector(("undo:"))
                case (cmdShift, "z"): return Selector(("redo:"))
                default: return nil
                }
            }()
            if let editing, NSApp.sendAction(editing, to: nil, from: self) { return true }
        }

        // esc here rather than in cancelOperation: that only arrives if the
        // responder chain delivers it, so clicking a suggestion row or the page
        // left esc doing nothing. performKeyEquivalent always runs.
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty {
            if onSwitcherCancel?() == true { return true }
            if controller?.isShowingSetup == true {
                // Nothing behind the card means esc should put the whole window
                // away rather than strand you on an empty one.
                if controller?.dismissSetupIfPossible() == true { return true }
                onHide?()
                return true
            }
            onHide?()
            return true
        }

        // Quit isn't reboundable — it's the one escape hatch that always has to
        // be where you expect it.
        if flags == cmd, key == "q" {
            NSApp.terminate(nil)
            return true
        }

        // While setup is open the field owns the keyboard; only reopening it and
        // quitting get through.
        if controller?.isShowingSetup == true {
            if Shortcuts[.openPage].matches(event) {
                controller?.presentSetup(mode: .editURL)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        // ⌃⇥ holds open the preview switcher; releasing ⌃ commits. Fixed, because
        // it's a hold-and-release gesture rather than a one-shot press.
        if Int(event.keyCode) == kVK_Tab, flags.contains(.control) {
            onSwitcherStep?(flags.contains(.shift) ? -1 : 1)
            return true
        }

        // ⌘1…⌘9 jumps straight to a tab. Fixed, because it's nine bindings that
        // only make sense as a block.
        if flags == cmd, let digit = Int(key), digit >= 1, digit <= 9 {
            onSelectTab?(digit - 1)
            return true
        }

        if let action = Shortcuts.action(for: event) {
            perform(action)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        // Both global actions are handled by their Carbon registration, not here.
        case .toggleWindow, .swapFocus: break
        case .hide:                onHide?()
        case .newTab:              onNewTab?()
        case .newTabAnywhere:      onNewTabAnywhere?()
        case .closeTab:            onCloseTab?()
        case .openPage:            onEditURL?()
        case .copyLink:            onCopyURL?()
        case .reload:              controller?.reload()
        case .hardReload:          controller?.hardReload()
        case .back:                controller?.goBack()
        case .forward:             controller?.goForward()
        case .zoomIn:              controller?.zoomIn()
        case .zoomOut:             controller?.zoomOut()
        case .zoomReset:           controller?.zoomReset()
        case .togglePin:           onTogglePin?()
        case .toggleDock:          onToggleDock?()
        case .opacityUp:           onOpacityChange?(0.05)
        case .opacityDown:         onOpacityChange?(-0.05)
        case .nextTab:             onCycleTab?(1)
        case .previousTab:         onCycleTab?(-1)
        }
    }
}

/// Transparent view that only takes the pointer while ⌘ is held, turning a
/// ⌘-drag anywhere on the page into a window move. Without a title bar there is
/// nowhere else to grab.
final class WindowDragView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSEvent.modifierFlags.contains(.command) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Deliberately no cursor rect: the window manages those by geometry, not by
    // hitTest, so an open-hand rect here would override the page's cursor
    // everywhere, even when ⌘ isn't held.
}
