import AppKit

/// Everything the status item shows.
///
/// Split out of `AppDelegate` because it was over half that file: the delegate's
/// job is wiring the window, the hotkey and the dock together, and menu
/// construction is a different concern that happens to need the same actions.
extension AppDelegate {

    func rebuildMenu() {
        let menu = NSMenu()
        // We decide what's enabled — auto-enabling would re-enable the captions
        // and "Save Current Page" once all nine slots are taken.
        menu.autoenablesItems = false

        let toggle = item("Show / Hide", #selector(togglePanel))
        // Display only: a status item's menu is not the main menu, so its key
        // equivalents never fire globally — the panel still owns every shortcut.
        if let key = KeyName.keyEquivalent(for: Shortcuts[.toggleWindow].keyCode) {
            toggle.keyEquivalent = key
            toggle.keyEquivalentModifierMask = KeyName.appKitModifiers(from: Shortcuts[.toggleWindow].modifiers)
        }
        menu.addItem(toggle)
        menu.addItem(item("Open a Page…", #selector(editURL), key: "l"))
        menu.addItem(item("Copy Page Link", #selector(copyCurrentURL),
                          key: "c", modifiers: [.command, .shift]))

        menu.addItem(.separator())

        // One row per open tab, checked on the active one.
        let tabsItem = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu()
        tabsMenu.autoenablesItems = false
        if browser.tabs.isEmpty {
            tabsMenu.addItem(.caption("No tabs open"))
        } else {
            for (i, tab) in browser.tabs.enumerated() {
                // Room for the middle of the title here — "Fix the dock › Floaty"
                // tells two Kanna chats apart where the strip can't.
                let label = tab.displayContext.map { "\(tab.displayTitle) › \($0)" } ?? tab.displayTitle
                let entry = item(label,
                                 #selector(selectTabFromMenu(_:)),
                                 key: i < 9 ? "\(i + 1)" : nil)
                entry.tag = i
                entry.state = i == browser.activeIndex ? .on : .off
                if let color = tab.status.color {
                    entry.image = Self.dotImage(color)
                    entry.toolTip = tab.status.label
                }
                tabsMenu.addItem(entry)
            }
        }
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(item("New Tab", #selector(newTab), key: "t"))
        tabsMenu.addItem(item("Open in New Tab…", #selector(newTabAnywhere),
                              key: "t", modifiers: [.command, .shift]))
        let closeTab = item("Close Tab", #selector(closeTabFromMenu), key: "w")
        closeTab.isEnabled = browser.tabs.count > 1
        tabsMenu.addItem(closeTab)

        // Per site: ⌘T lands on the site's fresh-start page by default, which is
        // a new chat on a chat app. For a site where you'd rather clone the page
        // you're on, flip it here; it's remembered for that site only.
        if let tab = browser.activeTab, let key = tab.siteKey {
            tabsMenu.addItem(.separator())
            let ruleItem = NSMenuItem(title: "New Tab Opens", action: nil, keyEquivalent: "")
            let ruleMenu = NSMenu()
            ruleMenu.autoenablesItems = false
            let current = Prefs.newTabRule(forSite: key)
            for (label, rule) in [("Site Home", Prefs.NewTabRule.root), ("This Page", .page)] {
                let entry = item(label, #selector(setNewTabRule(_:)))
                entry.representedObject = rule.rawValue
                entry.state = current == rule ? .on : .off
                ruleMenu.addItem(entry)
            }
            ruleMenu.addItem(.separator())
            ruleMenu.addItem(.caption("For \(key)"))
            ruleItem.submenu = ruleMenu
            tabsMenu.addItem(ruleItem)
        }
        tabsItem.submenu = tabsMenu
        menu.addItem(tabsItem)

        menu.addItem(.separator())

        let pin = item("Always on Top", #selector(togglePin), key: "p", modifiers: [.command, .option])
        pin.state = Prefs.pinned ? .on : .off
        menu.addItem(pin)

        let autoFocus = item("Focus Inputs on Foreground", #selector(toggleAutoFocusInput))
        autoFocus.state = Prefs.autoFocusInput ? .on : .off
        menu.addItem(autoFocus)

        let spaces = item("Show on All Spaces", #selector(toggleAllSpaces))
        spaces.state = Prefs.allSpaces ? .on : .off
        menu.addItem(spaces)

        let dockItem = NSMenuItem(title: "Dock to Window", action: nil, keyEquivalent: "")
        // Display only; the panel owns the real binding.
        let dockBinding = Shortcuts[.toggleDock]
        if let key = KeyName.keyEquivalent(for: dockBinding.keyCode) {
            dockItem.keyEquivalent = key
            dockItem.keyEquivalentModifierMask = KeyName.appKitModifiers(from: dockBinding.modifiers)
        }
        dockItem.submenu = dockMenu()
        menu.addItem(dockItem)

        let orderItem = NSMenuItem(title: "⌃⇥ Cycles By", action: nil, keyEquivalent: "")
        let orderMenu = NSMenu()
        orderMenu.autoenablesItems = false
        let recent = item("Recently Used", #selector(setCycleOrder(_:)))
        recent.tag = 1
        recent.state = Prefs.cycleByRecent ? .on : .off
        let ordered = item("Tab Order", #selector(setCycleOrder(_:)))
        ordered.tag = 0
        ordered.state = Prefs.cycleByRecent ? .off : .on
        orderMenu.addItem(recent)
        orderMenu.addItem(ordered)
        orderItem.submenu = orderMenu
        menu.addItem(orderItem)

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for (i, preset) in Self.sizePresets.enumerated() {
            let entry = item(preset.name, #selector(setSizeFromMenu(_:)))
            entry.tag = i
            sizeMenu.addItem(entry)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        opacityMenu.autoenablesItems = false
        for value in [100, 95, 90, 85, 80, 70, 60, 50] {
            let entry = item("\(value)%", #selector(setOpacityFromMenu(_:)))
            entry.tag = value
            entry.state = Int((Prefs.opacity * 100).rounded()) == value ? .on : .off
            opacityMenu.addItem(entry)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())

        let shortcuts = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        shortcuts.submenu = shortcutsMenu()
        menu.addItem(shortcuts)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Floaty", #selector(NSApplication.terminate(_:)), key: "q"))

        statusItem.menu = menu
    }

    /// Off, follow-whatever-is-frontmost, or a whitelist of apps. The app list is
    /// built fresh each time the menu opens, so it reflects what's running now.
    private func dockMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let current = Prefs.dockMode
        let chosen = current.bundleIDs

        let off = item("Off", #selector(setDockMode(_:)))
        off.representedObject = DockMode.off.storage
        off.state = current == .off ? .on : .off
        m.addItem(off)

        let active = item("Active Window", #selector(setDockMode(_:)))
        active.representedObject = DockMode.activeWindow.storage
        active.state = current == .activeWindow ? .on : .off
        m.addItem(active)

        m.addItem(.separator())
        m.addItem(.caption("Or follow only these apps"))

        let ours = Bundle.main.bundleIdentifier
        // Anything already whitelisted stays listed even if it isn't running, so
        // quitting an app doesn't silently drop it from the set.
        var listed = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != ours }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (name, id)
            }
        for id in chosen where !listed.contains(where: { $0.1 == id }) {
            listed.append((id, id))
        }
        listed.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        if listed.isEmpty {
            m.addItem(.caption("No other apps running"))
        } else {
            for (name, id) in listed {
                let entry = item(name, #selector(toggleDockApp(_:)))
                entry.representedObject = id
                entry.state = chosen.contains(id) ? .on : .off
                if let icon = NSRunningApplication
                    .runningApplications(withBundleIdentifier: id).first?.icon {
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
                m.addItem(entry)
            }
        }

        m.addItem(.separator())

        let onlyFocused = item("Only While Focused", #selector(toggleDockOnlyWhileFocused))
        onlyFocused.state = Prefs.dockOnlyWhileFocused ? .on : .off
        onlyFocused.isEnabled = !chosen.isEmpty
        m.addItem(onlyFocused)
        m.addItem(.caption("Hides Floaty when you leave those apps"))

        let keepFocus = item("Never Take Focus", #selector(toggleKeepParentFocus))
        keepFocus.state = Prefs.keepParentFocus ? .on : .off
        m.addItem(keepFocus)
        m.addItem(.caption("Click and scroll without leaving the other app;"))
        m.addItem(.caption("typing goes there too, so ⌃Space to type here"))

        m.addItem(.separator())

        let sideItem = NSMenuItem(title: "Side", action: nil, keyEquivalent: "")
        let sideMenu = NSMenu()
        sideMenu.autoenablesItems = false
        for (label, side) in [("Auto", DockSide.auto), ("Left", .left), ("Right", .right)] {
            let entry = item(label, #selector(setDockSide(_:)))
            entry.representedObject = side.rawValue
            entry.state = Prefs.dockSide == side ? .on : .off
            sideMenu.addItem(entry)
        }
        sideItem.submenu = sideMenu
        sideItem.isEnabled = current != .off
        m.addItem(sideItem)

        let reset = item("Align to Top", #selector(resetDockPosition))
        reset.isEnabled = current != .off
        m.addItem(reset)
        m.addItem(.caption("Drag it up or down to set its height"))

        return m
    }

    /// Every rebindable action, showing its current binding. Clicking one records
    /// a new key. Kept in the menubar rather than a settings window — one surface
    /// for everything is the point of the app.
    private func shortcutsMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        for action in ShortcutAction.allCases {
            let binding = Shortcuts[action]
            let entry = NSMenuItem(title: action.label, action: #selector(rebind(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = action.rawValue
            if let key = KeyName.keyEquivalent(for: binding.keyCode) {
                entry.keyEquivalent = key
                entry.keyEquivalentModifierMask = KeyName.appKitModifiers(from: binding.modifiers)
            }
            // A dot marks the ones you've changed, so defaults are recognisable.
            entry.state = Shortcuts.isCustomised(action) ? .mixed : .off
            m.addItem(entry)
        }

        m.addItem(.separator())
        m.addItem(.caption("Click an action to record a new shortcut"))

        // The ones that aren't rebindable, so the list isn't a lie by omission.
        m.addItem(.separator())
        for (label, keys) in [("Tab switcher", "⌃⇥"), ("Jump to tab", "⌘1…⌘9"),
                              ("Hide", "esc"), ("Quit", "⌘Q")] {
            m.addItem(.caption("\(label)   \(keys)"))
        }

        m.addItem(.separator())
        let reset = item("Restore Defaults", #selector(resetAllShortcuts))
        m.addItem(reset)
        return m
    }

    /// Every menu item goes through here, so they all share the native menu font.
    /// `key` is display only — see the note in `rebuildMenu`.
    private func item(_ title: String,
                      _ action: Selector,
                      key: String? = nil,
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
        entry.target = action == #selector(NSApplication.terminate(_:)) ? nil : self
        if key != nil { entry.keyEquivalentModifierMask = modifiers }
        return entry
    }

    /// The tab's status dot, as a menu image.
    private static func dotImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func displayName(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        let path = url.path.count > 1 ? url.path : ""
        return host.replacingOccurrences(of: "www.", with: "") + path
    }
}

// MARK: - Helpers

private extension NSMenuItem {
    /// A quiet, non-interactive line. Disabled is the whole treatment — macOS
    /// dims it, and it keeps the native menu font like every other row.
    static func caption(_ text: String) -> NSMenuItem {
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }
}
