import AppKit
import Carbon.HIToolbox

/// Everything Floaty remembers between launches.
enum Prefs {
    private static let d = UserDefaults.standard

    enum Key {
        static let lastURL = "lastURL"
        static let frame = "windowFrame"
        static let opacity = "opacity"
        static let pinned = "pinned"
        static let allSpaces = "allSpaces"
        static let tabs = "tabs"
        static let tabZooms = "tabZooms"
        static let activeTab = "activeTab"
        static let cycleByRecent = "cycleByRecent"
        static let dockMode = "dockMode"
        static let dockSide = "dockSide"
        static let dockVerticalOffset = "dockVerticalOffset"
        static let preferredDockMode = "preferredDockMode"
        static let dockOnlyWhileFocused = "dockOnlyWhileFocused"
        static let keepParentFocus = "keepParentFocus"
        static let autoFocusInput = "autoFocusInput"
        /// Superseded by `tabs`; still read once so old installs migrate.
        static let slots = "slots"
        static let didMigrateTabs = "didMigrateTabs"
    }

    static var lastURL: String {
        get { d.string(forKey: Key.lastURL) ?? "" }
        set { d.set(newValue, forKey: Key.lastURL) }
    }

    static var frame: NSRect? {
        get {
            guard let s = d.string(forKey: Key.frame) else { return nil }
            let r = NSRectFromString(s)
            return r.width > 100 && r.height > 100 ? r : nil
        }
        set {
            guard let newValue else { return }
            d.set(NSStringFromRect(newValue), forKey: Key.frame)
        }
    }

    static var opacity: Double {
        get {
            let v = d.object(forKey: Key.opacity) as? Double ?? 1.0
            return min(max(v, 0.2), 1.0)
        }
        set { d.set(min(max(newValue, 0.2), 1.0), forKey: Key.opacity) }
    }

    /// Always-on-top. Defaults to true — that's the whole point of the app.
    static var pinned: Bool {
        get { d.object(forKey: Key.pinned) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.pinned) }
    }

    /// Show the panel on every Space / over fullscreen apps.
    static var allSpaces: Bool {
        get { d.object(forKey: Key.allSpaces) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.allSpaces) }
    }

    /// The open tabs, in bar order. Restored on launch. No tabs is a real state
    /// — it's what shows the new-tab card — so this never invents one.
    static var tabs: [String] {
        get { d.stringArray(forKey: Key.tabs) ?? [] }
        set { d.set(newValue, forKey: Key.tabs) }
    }

    /// Each tab's page zoom, index-aligned with `tabs`. Written together with it
    /// so the two never drift; a tab with no entry (older saves) is at 1.0.
    static var tabZooms: [Double] {
        get { d.array(forKey: Key.tabZooms) as? [Double] ?? [] }
        set { d.set(newValue, forKey: Key.tabZooms) }
    }

    /// One-time move off the old quick-switch slots, run at launch.
    ///
    /// This used to live in the `tabs` getter, seeding from `lastURL` whenever
    /// the list came back empty. That meant closing every tab immediately
    /// resurrected one — the "why is there always a default tab" bug. Migration
    /// is a once-ever event, so it's recorded as one.
    static func migrateLegacyTabsIfNeeded() {
        guard !d.bool(forKey: Key.didMigrateTabs) else { return }
        d.set(true, forKey: Key.didMigrateTabs)
        guard (d.stringArray(forKey: Key.tabs) ?? []).isEmpty else { return }
        let legacy = (d.stringArray(forKey: Key.slots) ?? []).filter { !$0.isEmpty }
        let seed = legacy.isEmpty ? [lastURL].filter { !$0.isEmpty } : legacy
        if !seed.isEmpty { tabs = seed }
    }

    static var activeTab: Int {
        get { d.object(forKey: Key.activeTab) as? Int ?? 0 }
        set { d.set(newValue, forKey: Key.activeTab) }
    }

    // MARK: - Docking

    /// What the window is glued to, if anything.
    static var dockMode: DockMode {
        get { DockMode(storage: d.string(forKey: Key.dockMode) ?? "off") }
        set { d.set(newValue.storage, forKey: Key.dockMode) }
    }

    /// Which side of the parent to sit on. Auto picks whichever has room.
    static var dockSide: DockSide {
        get { DockSide(rawValue: d.string(forKey: Key.dockSide) ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: Key.dockSide) }
    }

    /// What the toggle turns docking back *on* to — the last mode you actually
    /// chose, so switching it off and on again doesn't lose which app you pinned.
    static var preferredDockMode: DockMode {
        get {
            let stored = DockMode(storage: d.string(forKey: Key.preferredDockMode) ?? "")
            return stored == .off ? .activeWindow : stored
        }
        set {
            guard newValue != .off else { return }
            d.set(newValue.storage, forKey: Key.preferredDockMode)
        }
    }

    /// In whitelist mode, hide Floaty unless one of the chosen apps is frontmost.
    /// On by default — a window docked to an app you're not looking at is clutter.
    static var dockOnlyWhileFocused: Bool {
        get { d.object(forKey: Key.dockOnlyWhileFocused) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.dockOnlyWhileFocused) }
    }

    /// Clicking Floaty doesn't take keyboard focus from the window it's docked
    /// to. Off by default, because it costs the ability to type into the page.
    static var keepParentFocus: Bool {
        get { d.object(forKey: Key.keepParentFocus) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.keepParentFocus) }
    }

    /// Put the caret in the page's main text field whenever Floaty comes to the
    /// foreground.
    /// On by default: the pages people float are overwhelmingly chats and search
    /// boxes, where you want to type the moment it appears. On a page you're
    /// only reading it hijacks space-to-scroll, so it can be switched off.
    static var autoFocusInput: Bool {
        get { d.object(forKey: Key.autoFocusInput) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autoFocusInput) }
    }

    /// The inset a docked window keeps from its parent, used on both axes.
    static let dockGap: CGFloat = 8

    /// Points from the parent window's top edge down to ours — measured from the
    /// top so the pairing holds when the parent resizes from the bottom. Defaults
    /// to the same gap used horizontally, so the window is inset evenly rather
    /// than flush against the parent's top edge.
    static var dockVerticalOffset: CGFloat {
        get { CGFloat(d.object(forKey: Key.dockVerticalOffset) as? Double ?? Double(dockGap)) }
        set { d.set(Double(newValue), forKey: Key.dockVerticalOffset) }
    }

    /// ⌃⇥ order: most-recently-used (the default, matching the system app
    /// switcher) or left-to-right bar order.
    static var cycleByRecent: Bool {
        get { d.object(forKey: Key.cycleByRecent) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.cycleByRecent) }
    }

}
