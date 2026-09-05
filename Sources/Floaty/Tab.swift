import AppKit
import WebKit

/// Page titles are written for a browser, where the tab bar is the only place
/// the site's name appears: "[2] Kanna : Floaty : Fix the dock jump",
/// "Release 1.0.3 · chroxify/floaty · GitHub". Next to a favicon the site name
/// is noise, and at ten tabs it's the only thing you can read. This keeps the
/// part that's about *this* page — "Fix the dock jump" — and hands the middle
/// ("Floaty") to whoever has room for it.
enum TabTitle {
    struct Cleaned {
        let title: String
        let context: String?
    }

    static func clean(_ raw: String, url: URL?) -> Cleaned {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteKey = Prefs.siteKey(for: url)

        // Unread counters: "[2] Kanna", "(3) Slack", "3 • Inbox".
        text = text.replacing(counter, with: "")

        let brands = brandSet(url: url, siteKey: siteKey)
        func isBrand(_ s: String) -> Bool { brands.contains(normalize(s)) }

        // "ChatGPT: Chat, Work, Create" — a brand prefix with no space before the
        // colon, so the segment split below wouldn't catch it. (With a space
        // before the colon it's an ordinary separator and the split handles it.)
        var brandFirst = false
        if let m = brandColon.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let head = Range(m.range(at: 1), in: text), let tail = Range(m.range(at: 2), in: text),
           isBrand(String(text[head])) {
            text = String(text[tail])
            brandFirst = true
        }

        // A dangling separator — "Kanna : Floaty :" when there's no chat yet —
        // has nothing after it for the split to see.
        text = text.replacing(edgeSeparator, with: "")

        let segments = text
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !segments.isEmpty else {
            return Cleaned(title: url?.host ?? raw, context: nil)
        }

        if isBrand(segments[0]) { brandFirst = true }
        let kept = segments.filter { !isBrand($0) }

        // Nothing but the site's name: that *is* the title, keep it as written.
        guard !kept.isEmpty else { return Cleaned(title: segments[0], context: nil) }
        guard kept.count > 1 else { return Cleaned(title: kept[0], context: nil) }

        // Sites that lead with their name nest general → specific ("Kanna :
        // Project : Chat"); sites that end with it go specific → general
        // ("Release · repo · GitHub"). Either way the page's own part is at the
        // far end from the brand.
        let title = brandFirst ? kept.last! : kept.first!
        let rest = brandFirst ? kept.dropLast() : kept.dropFirst()
        return Cleaned(title: title, context: rest.joined(separator: " › "))
    }

    /// The names a site goes by: its host labels, the name it gave its own root
    /// page (learned — that's how localhost:3210 knows it's "Kanna"), and a few
    /// that don't match their host.
    private static func brandSet(url: URL?, siteKey: String?) -> Set<String> {
        var brands: Set<String> = [
            "kanna", "chatgpt", "openai", "claude", "anthropic", "gemini", "google", "googlesearch",
            "googledocs", "perplexity", "grok", "mistral", "copilot", "deepseek",
            "notion", "github", "slack", "linear", "figma", "youtube", "reddit", "discord",
        ]
        if let host = url?.host?.lowercased() {
            for label in host.split(separator: ".") where label != "www" && label.count > 2 {
                brands.insert(normalize(String(label)))
            }
        }
        if let learned = Prefs.siteBrand(forSite: siteKey) { brands.insert(normalize(learned)) }
        return brands
    }

    /// A root page's title is usually just the site's name. Remember it, so the
    /// name can be recognised on every other page of that site.
    static func learnBrand(title: String, url: URL?) {
        guard let url, url.path.isEmpty || url.path == "/" else { return }
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines).replacing(counter, with: "")
        guard !text.isEmpty, text.count <= 24,
              text.components(separatedBy: separator).count == 1,
              text.split(separator: " ").count <= 3 else { return }
        Prefs.rememberSiteBrand(text, forSite: Prefs.siteKey(for: url))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let counter = try! NSRegularExpression(
        pattern: #"^\s*(?:[\[\(]\d+[\]\)]|\d+\s*[•·|\-–—])\s*"#)
    private static let brandColon = try! NSRegularExpression(pattern: #"^(\S[^:]{0,28}\S):\s+(.+)$"#)
    private static let separator = try! NSRegularExpression(pattern: #"\s+(?:::|:|\||·|•|-|–|—|»|›)\s+"#)
    private static let edgeSeparator = try! NSRegularExpression(pattern: #"^\s*[:|·•\-–—»›]+\s*|\s*[:|·•\-–—»›]+\s*$"#)
}

private extension String {
    func replacing(_ regex: NSRegularExpression, with template: String) -> String {
        regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }

    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var parts: [String] = []
        var last = startIndex
        for m in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let r = Range(m.range, in: self) else { continue }
            parts.append(String(self[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(self[last...]))
        return parts
    }
}

/// What a page says it's doing, for apps that have something to say — an agent
/// chat is working, or stopped to ask you something, or finished while you were
/// elsewhere. Read from `<meta name="floaty:status">`; see the README.
enum PageStatus: String {
    case idle, working, waiting, done, failed

    /// Kanna's own colours, so a chat looks the same in Floaty's strip as in
    /// Kanna's sidebar: the logo colour for a running chat's spinner
    /// (`--logo: oklch(71.2% 0.194 13.428)`), Tailwind blue-400 for waiting
    /// and emerald-400 for done. Fixed values on purpose — they're Kanna's, not
    /// the system's, and they're the same in both appearances there too.
    var color: NSColor? {
        switch self {
        case .idle: return nil
        case .working: return NSColor(srgbRed: 1.00, green: 0.39, blue: 0.49, alpha: 1)   // #ff637e
        case .waiting: return NSColor(srgbRed: 0.38, green: 0.65, blue: 0.98, alpha: 1)   // #60a5fa
        case .done: return NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)      // #34d399
        case .failed: return .systemRed
        }
    }

    var label: String {
        switch self {
        case .idle: return ""
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

/// Hands script messages to the tab without the content controller retaining
/// it — WebKit holds handlers strongly, so a tab as its own handler never dies.
private final class StatusRelay: NSObject, WKScriptMessageHandler {
    weak var tab: Tab?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        tab?.receiveStatus(message.body)
    }
}

/// One page. Each tab keeps its own live web view, so switching is instant and
/// scroll position, forms and playback survive.
final class Tab: NSObject {

    let id = UUID()
    /// Lazy so it can take the relay: handlers have to be in the configuration
    /// *before* the web view is made, which copies it.
    private(set) lazy var webView = Tab.makeWebView(statusHandler: statusRelay)
    private(set) var favicon: NSImage?
    /// What the page reports it's doing. Idle for pages that don't say.
    private(set) var status: PageStatus = .idle
    /// A count the page wants shown — unread chats, say. Zero when it doesn't.
    private(set) var badge = 0
    private let statusRelay = StatusRelay()
    /// Last frame of the page, for the switcher. Captured on the way out of a
    /// tab, while the view is still on screen and has something to give.
    private(set) var snapshot: NSImage?

    /// Fires whenever anything the tab bar draws changes.
    var onChange: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var faviconTask: URLSessionDataTask?
    private var faviconHost: String?

    /// What the bar shows: the page title with the site's own name and any unread
    /// counter stripped (see `TabTitle`), falling back to the host, so a tab is
    /// never blank while it loads.
    var displayTitle: String { cleanedTitle.title }

    /// The middle of a nested title — the project a chat belongs to, the repo a
    /// release is in — for places with room for a second line.
    var displayContext: String? { cleanedTitle.context }

    /// What the site calls itself: the name learned from its root page, else the
    /// host. "Kanna" for localhost:3210, "github.com" for GitHub.
    var siteName: String {
        if let brand = Prefs.siteBrand(forSite: siteKey) { return brand }
        return webView.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "New Tab"
    }

    /// Tabs with the same key belong together: same site, and the same context
    /// within it when the title gives one — every chat in one Kanna project,
    /// every page of one GitHub repo.
    var groupKey: String {
        (siteKey ?? "") + "|" + (displayContext ?? "")
    }

    /// The group, named: "Kanna › Floaty", or just "Kanna".
    var groupLabel: String {
        displayContext.map { "\(siteName) › \($0)" } ?? siteName
    }

    private var cleanedTitle: TabTitle.Cleaned {
        if let title = webView.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return TabTitle.clean(title, url: webView.url)
        }
        if let host = webView.url?.host {
            return .init(title: host.replacingOccurrences(of: "www.", with: ""), context: nil)
        }
        return .init(title: "New Tab", context: nil)
    }

    var urlString: String { webView.url?.absoluteString ?? "" }

    static let zoomRange: ClosedRange<Double> = 0.4...3.0
    static let zoomStep = 0.1

    /// The site this tab is on, for zoom purposes. Tracked separately from the
    /// URL so a cross-site navigation is detectable as a change of key.
    private(set) var siteKey: String?

    /// Page zoom. The tab applies it; the site owns it (see `Prefs.siteZooms`).
    /// Setting this only changes the view — the controller saves it per site
    /// and pushes it to other tabs on the same site.
    var zoom: Double {
        didSet {
            zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            webView.pageZoom = zoom
        }
    }

    init(url: String?) {
        zoom = 1.0
        super.init()
        statusRelay.tab = self
        webView.navigationDelegate = self
        observe()
        if let url { load(url) }
    }

    /// Ask the page to report its status again now — on coming into view, so
    /// whatever happened while the tab was in the background is caught up
    /// before you can notice it wasn't.
    func refreshStatus() {
        webView.evaluateJavaScript("window.__floatyStatus && window.__floatyStatus(true)") { _, _ in }
    }

    /// `{status, badge}` from the page's meta tags, or nulls when it has none.
    fileprivate func receiveStatus(_ body: Any) {
        let dict = body as? [String: Any] ?? [:]
        let newStatus = (dict["status"] as? String).flatMap(PageStatus.init(rawValue:)) ?? .idle
        let newBadge = (dict["badge"] as? String).flatMap(Int.init) ?? (dict["badge"] as? Int) ?? 0
        guard newStatus != status || newBadge != badge else { return }
        status = newStatus
        badge = newBadge
        onChange?()
    }

    /// Adopt the zoom for wherever the tab is now. Called before a load starts
    /// so the page never flashes at 1.0 first, and again whenever the URL moves
    /// to a different site.
    private func adoptSiteZoom(for url: URL?) {
        let key = Prefs.siteKey(for: url)
        guard key != siteKey else { return }
        siteKey = key
        zoom = Prefs.zoom(forSite: key)
    }

    deinit {
        faviconTask?.cancel()
    }

    // MARK: - Loading

    func load(_ string: String) {
        guard let url = URLNormalizer.url(from: string) else { return }
        adoptSiteZoom(for: url)
        webView.load(URLRequest(url: url))
    }

    func reload() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    private func observe() {
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                if let title = wv.title { TabTitle.learnBrand(title: title, url: wv.url) }
                self?.onChange?()
            },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.onChange?() },
            webView.observe(\.url) { [weak self] wv, _ in
                guard let self else { return }
                // Drop a stale mark when moving to a different site, so the old
                // one doesn't sit there through the next load.
                if wv.url?.host != self.faviconHost {
                    self.favicon = nil
                    self.faviconHost = nil
                }
                // A link to another site means that site's zoom, not this one's.
                self.adoptSiteZoom(for: wv.url)
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

    /// Scores every usable field and takes the best, rather than the biggest.
    ///
    /// Size alone picks wrong constantly: a header search box outweighs a chat
    /// composer, and a page with several inputs is a coin toss. So candidates are
    /// scored on what they appear to be *for* — name, id, placeholder, aria-label
    /// — plus where they sit, since composers live at the bottom of the viewport
    /// and search boxes live in the chrome at the top.
    private static let focusInputScript = """
    (function () {
      var active = document.activeElement;
      if (active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA'
                     || active.isContentEditable)) {
        return false;
      }

      var CHAT = /(message|chat|prompt|compose|reply|comment|ask|send|post|tweet|caption)/i;
      var SEARCH = /(search|filter|find|query|lookup|command|palette|omnibox)/i;
      // Types that are never the thing you meant to type into.
      var SKIP_TYPES = /^(password|hidden|submit|button|reset|checkbox|radio|file|color|range|image|date|time|month|week|datetime-local)$/;

      function describe(el) {
        var className = typeof el.className === 'string' ? el.className : '';
        return [el.getAttribute('name'), el.id, el.getAttribute('placeholder'),
                el.getAttribute('aria-label'), el.getAttribute('aria-placeholder'),
                el.getAttribute('data-testid'), className].filter(Boolean).join(' ');
      }

      function boxOf(el) {
        var r = el.getBoundingClientRect();
        // Too small to be a real field, or scrolled out of sight. This is also
        // what rules out hidden fallback textareas that frameworks leave behind.
        if (r.width < 40 || r.height < 12) return null;
        if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) return null;
        var s = getComputedStyle(el);
        if (s.visibility === 'hidden' || s.display === 'none' || s.opacity === '0') return null;
        return r;
      }

      var nodes = document.querySelectorAll(
        "textarea, input, [contenteditable]:not([contenteditable='false'])");
      var best = null, bestScore = -Infinity, bestArea = 0;

      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        if (el.disabled || el.readOnly) continue;

        var type = (el.getAttribute('type') || '').toLowerCase();
        if (el.tagName === 'INPUT' && SKIP_TYPES.test(type)) continue;

        var box = boxOf(el);
        if (!box) continue;

        var label = describe(el);
        var score = 0;

        // What it says it's for, which beats every other signal.
        if (CHAT.test(label)) score += 50;
        if (SEARCH.test(label)) score -= 45;

        // A composer is multi-line; a search box rarely is.
        if (el.tagName === 'TEXTAREA' || el.isContentEditable) score += 30;
        if (el.hasAttribute('autofocus')) score += 25;

        if (type === 'search') score -= 35;
        if (type === 'email' || type === 'url' || type === 'tel') score -= 30;

        // Composers sit at the bottom, search and login sit at the top.
        score += (box.top / Math.max(innerHeight, 1)) * 25;
        // Wide fields are more likely to be the main one.
        score += Math.min(box.width / Math.max(innerWidth, 1), 1) * 15;

        // Page chrome is where search lives.
        if (el.closest && el.closest('header, nav, [role=navigation], [role=search]')) {
          score -= 30;
        }
        // Something to submit it with reads as a real composer.
        if (el.closest && el.closest('form')) {
          var form = el.closest('form');
          if (form.querySelector("button[type=submit], [aria-label*='send' i], [data-testid*='send' i]")) {
            score += 20;
          }
        }

        var area = box.width * box.height;
        if (score > bestScore || (score === bestScore && area > bestArea)) {
          bestScore = score;
          bestArea = area;
          best = el;
        }
      }

      if (!best) return false;
      best.focus();
      if (typeof best.setSelectionRange === 'function' && typeof best.value === 'string') {
        try { best.setSelectionRange(best.value.length, best.value.length); } catch (e) {}
      }
      // Put the caret at the end of a contenteditable too.
      if (best.isContentEditable && window.getSelection && document.createRange) {
        try {
          var range = document.createRange();
          range.selectNodeContents(best);
          range.collapse(false);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        } catch (e) {}
      }
      return best.id || best.getAttribute('name') || best.tagName;
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

    private static func makeWebView(statusHandler: WKScriptMessageHandler) -> PageWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(pageChromeScript)
        config.userContentController.addUserScript(statusScript)
        config.userContentController.add(statusHandler, name: "floatyStatus")

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
    /// Reports `<meta name="floaty:status">` and `floaty:badge` to the tab —
    /// once on load, whenever the head changes, and every few seconds anyway.
    /// The poll is the safety net: a background web view can be throttled, and
    /// a dot that's a few seconds stale is fine where one that's stuck is not.
    /// Posts nulls for a page that has neither, so navigating away from a page
    /// that had them clears the dot. `__floatyStatus(true)` re-posts on demand,
    /// which the tab calls when it comes into view.
    private static let statusScript = WKUserScript(
        source: """
        (function () {
          var last = '';
          function read(name) {
            var m = document.head && document.head.querySelector('meta[name="' + name + '"]');
            return m ? m.getAttribute('content') : null;
          }
          function post(force) {
            var s = read('floaty:status'), b = read('floaty:badge');
            var key = s + '|' + b;
            if (!force && key === last) return;
            last = key;
            try { window.webkit.messageHandlers.floatyStatus.postMessage({ status: s, badge: b }); } catch (e) {}
          }
          window.__floatyStatus = post;
          post();
          if (document.head) {
            new MutationObserver(function () { post(); }).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['content'] });
          }
          setInterval(function () { post(); }, 3000);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

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
