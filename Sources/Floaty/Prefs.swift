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
        static let siteZooms = "siteZooms"
        static let newTabRules = "newTabRules"
        static let siteBrands = "siteBrands"
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

    // MARK: - Zoom

    /// Page zoom is per site, not per tab — the way Safari does it. Two tabs on
    /// the same site share a level, and a tab that navigates to another site
    /// picks up that site's level. Keyed by `siteKey`; only non-default levels
    /// are stored, so resetting a site removes its entry.
    private static var siteZooms: [String: Double] {
        get { d.dictionary(forKey: Key.siteZooms) as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: Key.siteZooms) }
    }

    /// What a URL is "the same site" as: host plus port, lowercased, without
    /// a leading www. The port matters here more than in a browser — half of
    /// what gets floated is localhost, and :3000 and :3210 are different apps.
    static func siteKey(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = url?.port { return "\(bare):\(port)" }
        return bare
    }

    static func zoom(forSite key: String?) -> Double {
        guard let key else { return 1.0 }
        return siteZooms[key] ?? 1.0
    }

    static func setZoom(_ zoom: Double, forSite key: String?) {
        guard let key else { return }
        var all = siteZooms
        if abs(zoom - 1.0) < 0.001 { all.removeValue(forKey: key) } else { all[key] = zoom }
        siteZooms = all
    }

    // MARK: - Site names

    /// What a site calls itself, learned from its root page's title. Lets the
    /// title cleaner strip "Kanna" from "Kanna : Project : Chat" when the host
    /// is just localhost and says nothing.
    private static var siteBrands: [String: String] {
        get { d.dictionary(forKey: Key.siteBrands) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.siteBrands) }
    }

    static func siteBrand(forSite key: String?) -> String? {
        guard let key else { return nil }
        return siteBrands[key]
    }

    static func rememberSiteBrand(_ brand: String, forSite key: String?) {
        guard let key, siteBrands[key] != brand else { return }
        var all = siteBrands
        all[key] = brand
        siteBrands = all
    }

    // MARK: - New tab

    /// What ⌘T opens on a site: its fresh-start page (the default — a new chat
    /// on a chat app) or a copy of the page you're on.
    enum NewTabRule: String {
        case root, page
    }

    private static var newTabRules: [String: String] {
        get { d.dictionary(forKey: Key.newTabRules) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.newTabRules) }
    }

    static func newTabRule(forSite key: String?) -> NewTabRule {
        guard let key, let raw = newTabRules[key] else { return .root }
        return NewTabRule(rawValue: raw) ?? .root
    }

    /// Only overrides are stored, so the default can change for everyone who
    /// never touched it.
    static func setNewTabRule(_ rule: NewTabRule, forSite key: String?) {
        guard let key else { return }
        var all = newTabRules
        if rule == .root { all.removeValue(forKey: key) } else { all[key] = rule.rawValue }
        newTabRules = all
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
