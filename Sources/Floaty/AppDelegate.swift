import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: FloatyPanel!
    var browser: BrowserViewController!
    var statusItem: NSStatusItem!
    private var toggleHotKeyID: UInt32?
    private var doubleClickDrag: DoubleClickDrag?
    private let switcher = TabSwitcher()
    var dock: WindowDock!
    /// Set when you hide the window yourself, so the dock's focus gating doesn't
    /// pop it straight back up.
    private var userHidden = false

    static let sizePresets: [(name: String, size: NSSize)] = [
        ("Small", NSSize(width: 340, height: 460)),
        ("Medium", NSSize(width: 420, height: 560)),
        ("Large", NSSize(width: 560, height: 720)),
    ]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        Prefs.migrateLegacyTabsIfNeeded()
        buildPanel()
        buildStatusItem()
        registerToggleHotKey()

        showPanel()
        browser.restoreTabs()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveFrame()
        browser.persistTabs()
        HotKeyManager.shared.unregisterAll()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The panel can still be key from last time, so no windowDidBecomeKey.
        guard panel?.isKeyWindow == true else { return }
        focusMainInputIfWanted()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: - Panel

    private func buildPanel() {
        browser = BrowserViewController()
        panel = FloatyPanel()
        panel.contentViewController = browser
        panel.controller = browser
        panel.delegate = self

        // Sits above the page and only intercepts a ⌘-drag.
        if let content = panel.contentView {
            let dragView = WindowDragView()
            dragView.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(dragView)
            NSLayoutConstraint.activate([
                dragView.topAnchor.constraint(equalTo: content.topAnchor),
                dragView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                dragView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                dragView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }

        if let saved = Prefs.frame {
            panel.setFrame(saved, display: false)
        } else {
            panel.setContentSize(Self.sizePresets[1].size)
            panel.center()
        }

        panel.alphaValue = Prefs.opacity
        applyFocusMode()
        applyPinState()
        applySpacesState()

        panel.onHide = { [weak self] in self?.hidePanel() }
        panel.onTogglePin = { [weak self] in self?.togglePin() }
        panel.onOpacityChange = { [weak self] delta in self?.setOpacity(Prefs.opacity + delta) }
        panel.onEditURL = { [weak self] in self?.browser.presentSetup(mode: .editURL) }
        panel.onNewTab = { [weak self] in self?.browser.toggleSetup(mode: .newTab) }
        panel.onSelectTab = { [weak self] index in self?.browser.select(index) }
        panel.onCycleTab = { [weak self] offset in self?.browser.selectNext(by: offset) }
        // Closing the last tab leaves the new-tab card, not an empty window, so
        // ⌘W no longer needs to double as hide.
        panel.onCloseTab = { [weak self] in self?.browser.closeActiveTab() }

        panel.onSwitcherStep = { [weak self] offset in
            guard let self else { return }
            let ordered = self.browser.switcherOrder()
            let start = ordered.firstIndex { $0 === self.browser.activeTab } ?? 0
            self.switcher.advance(by: offset,
                                  tabs: ordered,
                                  activeIndex: start,
                                  over: self.panel)
        }
        panel.onSwitcherCancel = { [weak self] in
            guard self?.switcher.isVisible == true else { return false }
            self?.switcher.cancel()
            return true
        }
        panel.onCopyURL = { [weak self] in self?.copyCurrentURL() }
        panel.onToggleDock = { [weak self] in self?.toggleDock() }
        switcher.onCommit = { [weak self] tab in self?.browser.select(tab) }

        // Double-click, then keep dragging, to move the window.
        doubleClickDrag = DoubleClickDrag(
            panel: panel,
            isEnabled: { [weak self] in self?.browser.isShowingSetup == false },
            setPageFrozen: { [weak self] frozen in self?.browser.suppressInteraction(frozen) }
        )

        dock = WindowDock(panel: panel)
        dock.onStateChange = { [weak self] in self?.rebuildMenu() }
        dock.onVisibilityChange = { [weak self] visible in self?.setDockVisibility(visible) }
        dock.start()

        browser.onTabsChanged = { [weak self] in self?.rebuildMenu() }
    }

    private func showPanel() {
        userHidden = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        userHidden = true
        saveFrame()
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    /// Driven by the dock's focus gating, not by you. Shows without activating —
    /// you're working in the other app, and stealing focus to reveal a docked
    /// panel would be maddening. An explicit hide still wins until you bring it
    /// back yourself.
    private func setDockVisibility(_ visible: Bool) {
        guard panel != nil else { return }
        if visible {
            guard !userHidden else { return }
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    @objc func togglePanel() {
        if panel.isVisible && NSApp.isActive {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func saveFrame() {
        guard panel != nil else { return }
        // The dock moves the window on every tick; persisting each of those would
        // be a UserDefaults write per frame, and would overwrite the undocked
        // position you'd want back.
        guard dock?.isRepositioning != true else { return }
        Prefs.frame = panel.frame
    }

    // MARK: - Window behaviour

    /// A non-activating panel takes mouse input without making Floaty the active
    /// app, so the window you're docked to keeps keyboard focus. The cost is that
    /// you can't type into the page — only the active app receives keys — so
    /// ⌃Space still activates properly when you actually want to use it.
    private func applyFocusMode() {
        if Prefs.keepParentFocus {
            panel.styleMask.insert(.nonactivatingPanel)
        } else {
            panel.styleMask.remove(.nonactivatingPanel)
        }
    }

    @objc func toggleKeepParentFocus() {
        Prefs.keepParentFocus.toggle()
        applyFocusMode()
        rebuildMenu()
    }

    private func applyPinState() {
        panel.level = Prefs.pinned ? .floating : .normal
    }

    private func applySpacesState() {
        panel.collectionBehavior = Prefs.allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    @objc func togglePin() {
        Prefs.pinned.toggle()
        applyPinState()
        rebuildMenu()
    }

    @objc func toggleAutoFocusInput() {
        Prefs.autoFocusInput.toggle()
        rebuildMenu()
    }

    @objc func toggleAllSpaces() {
        Prefs.allSpaces.toggle()
        applySpacesState()
        rebuildMenu()
    }

    private func setOpacity(_ value: Double) {
        Prefs.opacity = value
        panel.alphaValue = Prefs.opacity
        rebuildMenu()
    }

    @objc func setOpacityFromMenu(_ sender: NSMenuItem) {
        setOpacity(Double(sender.tag) / 100.0)
    }

    @objc func setSizeFromMenu(_ sender: NSMenuItem) {
        let size = Self.sizePresets[sender.tag].size
        showPanel()
        panel.setContentSize(size)
        panel.center()
        saveFrame()
    }

    @objc func editURL() {
        showPanel()
        browser.presentSetup(mode: .editURL)
    }

    @objc func newTab() {
        showPanel()
        browser.toggleSetup(mode: .newTab)
    }

    @objc func selectTabFromMenu(_ sender: NSMenuItem) {
        showPanel()
        browser.select(sender.tag)
    }

    /// Off, or back to whatever you last docked to.
    @objc func toggleDock() {
        if Prefs.dockMode == .off {
            Prefs.dockMode = Prefs.preferredDockMode
            showPanel()
        } else {
            Prefs.dockMode = .off
        }
        dock.refresh()
    }

    @objc func setDockMode(_ sender: NSMenuItem) {
        let mode = DockMode(storage: sender.representedObject as? String ?? "off")
        Prefs.dockMode = mode
        Prefs.preferredDockMode = mode
        // A fresh target shouldn't inherit the last one's offset.
        if mode != .off { Prefs.dockVerticalOffset = Prefs.dockGap }
        showPanel()
        dock.refresh()
    }

    /// Whitelist entries toggle rather than replace, so you can follow several
    /// apps at once.
    @objc func toggleDockApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let wasOff = Prefs.dockMode == .off

        var ids = Prefs.dockMode.bundleIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }

        let mode: DockMode = ids.isEmpty ? .off : .apps(ids)
        Prefs.dockMode = mode
        Prefs.preferredDockMode = mode
        // Only reset the height when docking starts, not on every toggle.
        if wasOff, mode != .off { Prefs.dockVerticalOffset = Prefs.dockGap }
        if mode != .off { showPanel() }
        dock.refresh()
    }

    @objc func toggleDockOnlyWhileFocused() {
        Prefs.dockOnlyWhileFocused.toggle()
        dock.refresh()
    }

    @objc func setDockSide(_ sender: NSMenuItem) {
        Prefs.dockSide = DockSide(rawValue: sender.representedObject as? String ?? "auto") ?? .auto
        dock.refresh()
    }

    @objc func resetDockPosition() {
        dock.resetPosition()
        rebuildMenu()
    }

    @objc func setCycleOrder(_ sender: NSMenuItem) {
        Prefs.cycleByRecent = sender.tag == 1
        rebuildMenu()
    }

    @objc func copyCurrentURL() {
        let url = browser.currentURLString
        guard !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func closeTabFromMenu() {
        browser.closeActiveTab()
    }

    // MARK: - Hotkey

    private func registerToggleHotKey() {
        if let id = toggleHotKeyID { HotKeyManager.shared.unregister(id) }
        let binding = Shortcuts[.toggleWindow]
        toggleHotKeyID = HotKeyManager.shared.register(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers
        ) { [weak self] in
            self?.togglePanel()
        }

        guard toggleHotKeyID == nil else { return }
        let shortcut = binding.display
        let alert = NSAlert()
        alert.messageText = "Couldn’t register \(shortcut)"
        alert.informativeText = "Another app is already using that shortcut. "
            + "Pick a different one from the Floaty menu."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc func rebind(_ sender: NSMenuItem) {
        guard let action = ShortcutAction.allCases.first(where: { $0.rawValue == sender.representedObject as? String })
        else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Press a shortcut for “\(action.label)”"
        alert.informativeText = "Include at least one modifier. esc cancels, delete restores the default "
            + "(\(action.defaultShortcut.display))."
        alert.addButton(withTitle: "Cancel")

        var captured: Shortcut?
        var clear = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                NSApp.stopModal(withCode: .cancel)
                return nil
            case kVK_Delete, kVK_ForwardDelete:
                clear = true
                NSApp.stopModal(withCode: .OK)
                return nil
            default:
                break
            }
            let mods = KeyName.carbonModifiers(from: event.modifierFlags)
            // A bare key would swallow ordinary typing in the page.
            guard mods != 0 else { return nil }
            captured = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
            NSApp.stopModal(withCode: .OK)
            return nil
        }

        let response = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        guard response == .OK else { return }

        if clear {
            Shortcuts.reset(action)
        } else if let captured {
            // Two actions on one combination means the loser silently stops
            // working, so say so rather than letting it happen.
            if let clash = Shortcuts.conflict(for: captured, excluding: action) {
                let warning = NSAlert()
                warning.messageText = "\(captured.display) is already “\(clash.label)”"
                warning.informativeText = "Reassign it to “\(action.label)”? "
                    + "“\(clash.label)” will be left without a shortcut."
                warning.addButton(withTitle: "Reassign")
                warning.addButton(withTitle: "Cancel")
                guard warning.runModal() == .alertFirstButtonReturn else { return }
                Shortcuts.reset(clash)
            }
            Shortcuts[action] = captured
        }

        if action.isGlobal { registerToggleHotKey() }
        rebuildMenu()
    }

    @objc func resetAllShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Restore every shortcut to its default?"
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Shortcuts.resetAll()
        registerToggleHotKey()
        rebuildMenu()
    }

    // MARK: - Launch at login

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t change the login item"
            alert.runModal()
        }
        rebuildMenu()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.on.square.dashed",
                                          accessibilityDescription: "Floaty")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hidePanel()
        return false
    }

    /// Auto-focus fires whenever the window comes to the foreground, however it
    /// got there — the shortcut, the menu, the dock revealing it, or a click.
    func windowDidBecomeKey(_ notification: Notification) {
        focusMainInputIfWanted()
    }

    /// Twice, deliberately.
    ///
    /// The immediate pass keeps the shortcut path instant. But when focus comes
    /// from a *click*, the mouse event is dispatched after this notification, and
    /// clicking bare page area blurs whatever we just focused — so a second pass
    /// once the click has been processed puts the caret back.
    ///
    /// The repeat is safe because the script leaves an already-focused field
    /// alone: click into a different input and that one keeps focus.
    private func focusMainInputIfWanted() {
        guard Prefs.autoFocusInput, browser?.isShowingSetup == false else { return }
        browser.focusMainInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel.isKeyWindow,
                  self.browser?.isShowingSetup == false else { return }
            self.browser.focusMainInput()
        }
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
}
