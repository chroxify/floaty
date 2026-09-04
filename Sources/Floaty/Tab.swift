import AppKit
import WebKit

/// One page. Each tab keeps its own live web view, so switching is instant and
/// scroll position, forms and playback survive.
final class Tab: NSObject {

    let id = UUID()
    private(set) var webView = Tab.makeWebView()
    private(set) var favicon: NSImage?
    /// Last frame of the page, for the switcher. Captured on the way out of a
    /// tab, while the view is still on screen and has something to give.
    private(set) var snapshot: NSImage?

    /// Fires whenever anything the tab bar draws changes.
    var onChange: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var faviconTask: URLSessionDataTask?
    private var faviconHost: String?

    /// What the bar shows: the page title, falling back to the host, so a tab is
    /// never blank while it loads.
    var displayTitle: String {
        if let title = webView.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let host = webView.url?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return "New Tab"
    }

    var urlString: String { webView.url?.absoluteString ?? "" }

    init(url: String?) {
        super.init()
        webView.navigationDelegate = self
        observe()
        if let url { load(url) }
    }

    deinit {
        faviconTask?.cancel()
    }

    // MARK: - Loading

    func load(_ string: String) {
        guard let url = URLNormalizer.url(from: string) else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    private func observe() {
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.onChange?() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.onChange?() },
            webView.observe(\.url) { [weak self] wv, _ in
                guard let self else { return }
                // Drop a stale mark when moving to a different site, so the old
                // one doesn't sit there through the next load.
                if wv.url?.host != self.faviconHost {
                    self.favicon = nil
                    self.faviconHost = nil
                }
                self.onChange?()
            },
        ]
    }

    // MARK: - Focus

    /// Puts the caret in the page's main text field — the largest one actually
    /// visible, which on a chat or search page is the composer.
    ///
    /// Does nothing if a field already has focus, so summoning the window twice
    /// can't yank you out of what you were typing.
    func focusMainInput() {
        webView.evaluateJavaScript(Self.focusInputScript, completionHandler: nil)
    }

    private static let focusInputScript = """
    (function () {
      var active = document.activeElement;
      if (active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA'
                     || active.isContentEditable)) {
        return false;
      }
      var fields = document.querySelectorAll(
        "textarea, input[type=text], input[type=search], input[type=email],"
        + "input[type=url], input[type=tel], input:not([type]), [contenteditable=true]");
      var best = null, bestArea = 0;
      for (var i = 0; i < fields.length; i++) {
        var el = fields[i];
        if (el.disabled || el.readOnly) continue;
        var r = el.getBoundingClientRect();
        // Skip the off-screen and the hairline — search boxes hidden behind a
        // toggle, honeypots, and the like.
        if (r.width < 40 || r.height < 12) continue;
        if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) continue;
        var style = getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none' || style.opacity === '0') continue;
        var area = r.width * r.height;
        if (area > bestArea) { bestArea = area; best = el; }
      }
      if (!best) return false;
      best.focus();
      // Land the caret at the end rather than selecting what's already there.
      if (typeof best.setSelectionRange === 'function' && typeof best.value === 'string') {
        try { best.setSelectionRange(best.value.length, best.value.length); } catch (e) {}
      }
      return true;
    })();
    """

    /// Freezes the page while the window is being dragged from it.
    ///
    /// A double-click has already selected a word by the time the drag starts, and
    /// without this the page keeps that selection — and keeps reacting to the
    /// pointer — while the window moves under it.
    func suppressInteraction(_ suppressed: Bool) {
        webView.evaluateJavaScript(suppressed ? Self.freezeScript : Self.thawScript,
                                   completionHandler: nil)
    }

    private static let guardElementID = "__floaty-drag-guard"

    private static let freezeScript = """
    (function () {
      var id = '\(guardElementID)';
      if (!document.getElementById(id)) {
        var style = document.createElement('style');
        style.id = id;
        style.textContent = '*,*::before,*::after{user-select:none!important;'
          + '-webkit-user-select:none!important;pointer-events:none!important}';
        (document.head || document.documentElement).appendChild(style);
      }
      // Drop the word the double-click selected on the way in.
      if (window.getSelection) { window.getSelection().removeAllRanges(); }
    })();
    """

    private static let thawScript = """
    (function () {
      var el = document.getElementById('\(guardElementID)');
      if (el) { el.remove(); }
    })();
    """

    // MARK: - Snapshot

    /// Only works while the view is in a window and drawn, so call it before
    /// switching away, never after.
    func captureSnapshot(completion: (() -> Void)? = nil) {
        guard webView.window != nil, webView.bounds.width > 1 else {
            completion?()
            return
        }
        let config = WKSnapshotConfiguration()
        // The backing store as it already stands — no forced re-render, so this
        // stays cheap enough to run on every tab switch.
        config.afterScreenUpdates = false
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            if let image { self?.snapshot = image }
            completion?()
        }
    }

    // MARK: - Favicon

    /// Asks the document what its icon is, and only guesses /favicon.ico if that
    /// turns up nothing. Runs on navigation finish — on URL change the new
    /// document hasn't been parsed yet, so the lookup found nothing every time
    /// and every site silently fell through to the guess.
    fileprivate func loadFavicon() {
        guard let pageURL = webView.url, pageURL.host != nil else { return }

        // Relative to the page, so scheme, host and port all come along. A
        // hardcoded https:// misses every http site and every localhost port.
        let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL

        webView.evaluateJavaScript(Self.faviconLookup) { [weak self] result, _ in
            guard let self else { return }
            let declared = (result as? String).flatMap(URL.init(string:))
            self.fetchFavicon(declared ?? fallback, host: pageURL.host) { worked in
                guard !worked, declared != nil, let fallback else { return }
                // The page named an icon we couldn't fetch; the conventional
                // path is still worth a try.
                self.fetchFavicon(fallback, host: pageURL.host) { _ in }
            }
        }
    }

    private static let faviconLookup = """
    (function () {
      var links = document.querySelectorAll(
        "link[rel~='icon'], link[rel='shortcut icon'], link[rel='apple-touch-icon']");
      var best = null, bestSize = -1;
      for (var i = 0; i < links.length; i++) {
        var sizes = links[i].getAttribute('sizes') || '';
        var size = parseInt(sizes, 10);
        if (isNaN(size)) size = links[i].rel.indexOf('apple') >= 0 ? 180 : 0;
        if (size > bestSize) { bestSize = size; best = links[i].href; }
      }
      return best;
    })();
    """

    private func fetchFavicon(_ url: URL?, host: String?, completion: @escaping (Bool) -> Void) {
        guard let url else { completion(false); return }
        faviconTask?.cancel()
        faviconTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            // A single-page app answers unknown paths with its own document, so
            // /favicon.ico often comes back 200 with HTML in it. Decoding that as
            // an image fails quietly and looks like "no favicon".
            let mime = response?.mimeType?.lowercased() ?? ""
            let isDocument = mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json")

            guard !isDocument,
                  let data,
                  let image = NSImage(data: data),
                  image.isValid,
                  image.size.width > 0 else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let mark = FaviconCache.circular(image)
            DispatchQueue.main.async {
                self?.favicon = mark
                self?.faviconHost = host
                // Cache it so the new-tab suggestions can show a mark for pages
                // that aren't open — which is all of them, by definition.
                if let host { FaviconCache.store(mark, host: host) }
                self?.onChange?()
                completion(true)
            }
        }
        faviconTask?.resume()
    }

    // MARK: - Web view

    private static func makeWebView() -> PageWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(pageChromeScript)

        let webView = PageWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        // Present as a desktop browser so sites don't fall back to mobile layouts.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        return webView
    }

    /// Two bits of de-webbing, injected before the page paints:
    ///
    /// Scrollbars are chrome, and this window has none — the page still scrolls.
    ///
    /// Cursors get the native treatment: the arrow everywhere, the I-beam over
    /// text. The web's pointing hand doesn't exist in AppKit, and it's the single
    /// biggest tell that a window is a browser rather than an app.
    private static let pageChromeScript = WKUserScript(
        source: """
        (function () {
          var css = [
            '::-webkit-scrollbar{width:0!important;height:0!important;display:none!important}',
            'html,body,*{scrollbar-width:none!important;-ms-overflow-style:none!important}',

            '*,*::before,*::after{cursor:default!important}',

            'p,h1,h2,h3,h4,h5,h6,li,dd,dt,blockquote,figcaption,pre,code,td,th',
            '{cursor:text!important}',

            'input:not([type=button]):not([type=submit]):not([type=reset])',
            ':not([type=checkbox]):not([type=radio]):not([type=file]):not([type=color])',
            ':not([type=range]),textarea,[contenteditable=true]{cursor:text!important}',

            'a,button,select,summary,label,[role=button],[role=link],[role=tab],',
            '[role=menuitem],[role=checkbox],[role=radio],[role=switch],[onclick]',
            '{cursor:default!important}'
          ].join('');
          var style = document.createElement('style');
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}

/// A web view without the browser's context menu. Reload, Back, Forward and the
/// open-in-new-window items describe a browser; this is a window with a page in
/// it. What's left is what you'd get from text in any native app — copy, look up,
/// translate, share.
final class PageWebView: WKWebView {

    private static let hidden: Set<NSUserInterfaceItemIdentifier> = [
        .init("WKMenuItemIdentifierReload"),
        .init("WKMenuItemIdentifierGoBack"),
        .init("WKMenuItemIdentifierGoForward"),
        .init("WKMenuItemIdentifierOpenLinkInNewWindow"),
        .init("WKMenuItemIdentifierOpenImageInNewWindow"),
        .init("WKMenuItemIdentifierOpenMediaInNewWindow"),
        .init("WKMenuItemIdentifierOpenFrameInNewWindow"),
        .init("WKMenuItemIdentifierDownloadImage"),
        .init("WKMenuItemIdentifierDownloadLinkedFile"),
        .init("WKMenuItemIdentifierDownloadMedia"),
        .init("WKMenuItemIdentifierToggleEnhancedFullScreen"),
        .init("WKMenuItemIdentifierToggleFullScreen"),
    ]

    /// Act on the click that focuses the window, rather than swallowing it.
    ///
    /// By default AppKit eats the first click into an inactive window — it only
    /// brings the window forward. That means every hop back from the window
    /// you're docked to costs two clicks: one to focus, one to do the thing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The side buttons on a mouse. macOS numbers them 3 and 4, after left,
    /// right and middle. Together with `allowsBackForwardNavigationGestures`
    /// (two-finger swipe) and ⌘[ / ⌘], that's every route a native browser gives
    /// you — without putting a button in the window.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: goBack()
        case 4: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        for item in menu.items where item.identifier.map(Self.hidden.contains) == true {
            menu.removeItem(item)
        }

        // Removing items can strand a separator at the top or bottom, or leave two
        // in a row.
        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(first)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
        var index = menu.items.count - 1
        while index > 0 {
            if menu.items[index].isSeparatorItem, menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
            index -= 1
        }
    }
}


// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFavicon()
        // Record once the page has settled, so the entry carries a real title
        // rather than the URL it started from.
        if let url = webView.url?.absoluteString {
            History.record(url: url, title: webView.title ?? "")
        }
    }
}
