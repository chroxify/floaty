import AppKit
import WebKit

/// Hosts the tab strip and whichever tab's page is showing. Below the strip
/// there is still no chrome at all — no URL bar, no scrollbars.
final class BrowserViewController: NSViewController {

    private(set) var tabs: [Tab] = []
    private(set) var activeIndex = 0

    private let tabBar = TabBarView()
    private let content = NSView()
    private var setup: SetupView?
    /// Collapses to zero while there are no tabs, so first run is just the card.
    private var tabBarHeight: NSLayoutConstraint!

    /// Fires when the tab set or the active tab changes, so the menu can follow.
    var onTabsChanged: (() -> Void)?

    /// Most-recently-used first. Drives ⌃⇥ when that's the chosen order, and it
    /// has to be tracked continuously — you can't reconstruct it after the fact.
    private var recentlyUsed: [Tab] = []

    var activeTab: Tab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    var currentURLString: String { activeTab?.urlString ?? "" }
    var isShowingSetup: Bool { setup != nil }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        view.addSubview(tabBar)

        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarHeight,

            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Nothing here has an intrinsic size, so without these the window would
        // collapse when it adopts this controller.
        let width = view.widthAnchor.constraint(equalToConstant: 420)
        let height = view.heightAnchor.constraint(equalToConstant: 560)
        width.priority = .defaultLow
        height.priority = .defaultLow
        NSLayoutConstraint.activate([width, height])

        tabBar.onSelect = { [weak self] index in self?.select(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.presentSetup(mode: .newTab) }
    }

    // MARK: - Restoring

    func restoreTabs() {
        // Pair each URL with its zoom *before* dropping empties, so the two lists
        // stay aligned. Zooms may be shorter than tabs (saves from before zoom
        // was remembered); anything missing is 1.0.
        let zooms = Prefs.tabZooms
        let saved = Prefs.tabs.enumerated()
            .map { (url: $0.element, zoom: $0.offset < zooms.count ? zooms[$0.offset] : 1.0) }
            .filter { !$0.url.isEmpty }
        guard !saved.isEmpty else {
            presentSetup(mode: .firstRun)
            return
        }
        tabs = saved.map { makeTab(url: $0.url, zoom: $0.zoom) }
        activeIndex = min(max(Prefs.activeTab, 0), tabs.count - 1)
        // Nothing has been used yet this session, so seed recency with the
        // restored tab up front and bar order behind it.
        recentlyUsed = tabs
        if let tab = activeTab { touch(tab) }
        showActiveTab()
        refresh()
    }

    private func makeTab(url: String?, zoom: Double = 1.0) -> Tab {
        let tab = Tab(url: url, zoom: zoom)
        tab.onChange = { [weak self] in self?.refresh() }
        tab.webView.uiDelegate = self
        return tab
    }

    // MARK: - Tabs

    func newTab(url: String) {
        let tab = makeTab(url: url)
        tabs.append(tab)
        touch(tab)
        activeIndex = tabs.count - 1
        showActiveTab()
        persist()
        refresh()
    }

    func select(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        select(index)
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        // Capture the outgoing page now — once it leaves the hierarchy it has
        // nothing left to snapshot.
        activeTab?.captureSnapshot()
        activeIndex = index
        if let tab = activeTab { touch(tab) }
        showActiveTab()
        persist()
        refresh()
    }

    func selectNext(by offset: Int) {
        guard !tabs.isEmpty else { return }
        let next = (activeIndex + offset + tabs.count) % tabs.count
        select(next)
    }

    /// Returns false when there was nothing left to close, so the caller can
    /// decide what that means (we hide the window rather than leave it empty).
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        let tab = tabs.remove(at: index)
        recentlyUsed.removeAll { $0 === tab }
        tab.webView.removeFromSuperview()
        if activeIndex >= tabs.count { activeIndex = max(tabs.count - 1, 0) }
        else if index < activeIndex { activeIndex -= 1 }
        showActiveTab()
        persist()
        refresh()
        // Nothing left to show, so the new-tab card takes over rather than
        // leaving an empty window.
        if tabs.isEmpty { presentSetup(mode: .firstRun) }
        return true
    }

    @discardableResult
    func closeActiveTab() -> Bool { closeTab(at: activeIndex) }

    private func touch(_ tab: Tab) {
        recentlyUsed.removeAll { $0 === tab }
        recentlyUsed.insert(tab, at: 0)
    }

    /// The order ⌃⇥ walks. Most-recently-used puts the tab you came from one
    /// step away, the way the system app switcher does.
    func switcherOrder() -> [Tab] {
        guard Prefs.cycleByRecent else { return tabs }
        var ordered = recentlyUsed.filter { tab in tabs.contains { $0 === tab } }
        for tab in tabs where !ordered.contains(where: { $0 === tab }) {
            ordered.append(tab)
        }
        return ordered
    }

    private func showActiveTab() {
        content.subviews.forEach { $0.removeFromSuperview() }
        guard let tab = activeTab else { return }
        let webView = tab.webView
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        view.window?.makeFirstResponder(webView)

        if Prefs.autoFocusInput { tab.focusMainInput() }
    }

    private func refresh() {
        tabBar.isHidden = tabs.isEmpty
        tabBarHeight.constant = tabs.isEmpty ? 0 : TabBarView.height
        tabBar.reload(tabs: tabs, activeIndex: activeIndex)
        onTabsChanged?()
    }

    private func persist() {
        // Filter as pairs so a tab with no URL yet drops out of both lists.
        let live = tabs.filter { !$0.urlString.isEmpty }
        Prefs.tabs = live.map(\.urlString)
        Prefs.tabZooms = live.map(\.zoom)
        Prefs.activeTab = activeIndex
        Prefs.lastURL = currentURLString
    }

    /// Tabs report their URL only once the load starts, so save again on the way out.
    func persistTabs() { persist() }

    // MARK: - Page actions

    func load(_ string: String) { activeTab?.load(string) }
    func focusMainInput() { activeTab?.focusMainInput() }
    func suppressInteraction(_ on: Bool) { activeTab?.suppressInteraction(on) }
    func reload() { activeTab?.reload() }
    func hardReload() { activeTab?.webView.reloadFromOrigin() }
    func goBack() { activeTab?.webView.goBack() }
    func goForward() { activeTab?.webView.goForward() }

    // Zoom belongs to the tab and is saved as soon as it changes, so a relaunch
    // brings every tab back at the size you left it.
    func zoomIn() { adjustZoom(by: Tab.zoomStep) }
    func zoomOut() { adjustZoom(by: -Tab.zoomStep) }
    func zoomReset() { setZoom(1.0) }

    private func adjustZoom(by delta: Double) {
        guard let tab = activeTab else { return }
        // Snap to the step grid, or repeated ⌘- accumulates float error and
        // saves 0.30000000000000004 instead of 0.3.
        setZoom(((tab.zoom + delta) * 10).rounded() / 10)
    }

    private func setZoom(_ value: Double) {
        guard let tab = activeTab else { return }
        tab.zoom = value
        persist()
    }

    // MARK: - Setup overlay

    enum SetupMode {
        case firstRun   // nothing open yet
        case newTab     // ⌘T
        case editURL    // ⌘L, retargets the current tab
    }

    /// ⌘T twice should put you back where you were, not just re-focus the field.
    /// With no tabs there's nothing behind the card, so it stays.
    func toggleSetup(mode: SetupMode) {
        if setup != nil {
            if tabs.isEmpty { setup?.focus() } else { dismissSetup() }
            return
        }
        presentSetup(mode: mode)
    }

    /// esc from anywhere in the card, not just the field. Falls through to hiding
    /// the window when there's no page to go back to.
    @discardableResult
    func dismissSetupIfPossible() -> Bool {
        guard setup != nil else { return false }
        guard !tabs.isEmpty else { return false }
        dismissSetup()
        return true
    }

    func presentSetup(mode: SetupMode) {
        guard setup == nil else { setup?.focus(); return }

        // ⌘T and ⌘L open the same field but do different things, so the card has
        // to say which — otherwise they're indistinguishable at the moment you
        // use them.
        let title: String
        let description: String
        switch mode {
        case .firstRun:
            title = "Floaty"
            description = "Enter a link to keep it floating above everything."
        case .newTab:
            title = "New tab"
            description = "Enter a link, or a few words to search for."
        case .editURL:
            title = "Open in this tab"
            description = "Replaces the page you're on."
        }

        let overlay = SetupView(
            title: title,
            description: description,
            placeholder: "example.com"
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onSubmit = { [weak self] text in
            guard let self else { return }
            switch mode {
            case .firstRun, .newTab: self.newTab(url: text)
            case .editURL: self.load(text)
            }
            self.dismissSetup()
        }
        overlay.onCancel = { [weak self] in self?.dismissSetup() }

        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            // Sits over the page, never over the strip — you keep your tabs in
            // view while you type the next one.
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        // From the cache rather than the live tabs: it also covers pages that
        // aren't open, and it survives a restart.
        overlay.faviconProvider = { url in FaviconCache.image(for: url) }
        // Everything, including pages already open — picking one opens a second
        // tab on it, which is a reasonable thing to want.
        overlay.setSuggestions(History.entries)

        if mode == .editURL { overlay.prefill(currentURLString) }
        setup = overlay
        view.layoutSubtreeIfNeeded()
        overlay.focus()
    }

    func dismissSetup() {
        guard let overlay = setup else { return }
        setup = nil
        overlay.dismiss { [weak self] in
            guard let self, let webView = self.activeTab?.webView else { return }
            self.view.window?.makeFirstResponder(webView)
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {
    /// A link that wants a new window gets a new tab — which is what it meant.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
            newTab(url: url.absoluteString)
        }
        return nil
    }
}
