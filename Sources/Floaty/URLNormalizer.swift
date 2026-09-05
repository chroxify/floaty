import Foundation

enum URLNormalizer {
    /// Turns whatever the user typed into something loadable.
    /// "github.com" → https://github.com, "swift docs" → a web search,
    /// "localhost:3000" → http://localhost:3000.
    static func url(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already has a scheme we can hand straight to WebKit.
        if let u = URL(string: text), let scheme = u.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme) {
            return u
        }

        let firstComponent = text.split(separator: "/").first.map(String.init) ?? text
        let host = firstComponent.split(separator: ":").first.map(String.init) ?? firstComponent

        let looksLocal = host == "localhost" || host.hasPrefix("127.0.0.") || host == "0.0.0.0"
        let looksLikeHost = !text.contains(" ") && (host.contains(".") || looksLocal)

        if looksLikeHost {
            let scheme = looksLocal ? "http" : "https"
            if let u = URL(string: "\(scheme)://\(text)") { return u }
        }

        var comps = URLComponents(string: "https://www.google.com/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps?.url
    }
}

/// What ⌘T opens. Floaty is mostly used for chat apps, where "new tab" should
/// mean "new chat", not "type a URL" — so a new tab lands on the current site's
/// fresh-start page. That's the site root for nearly everything; the table
/// covers the few that put a new chat somewhere else. Not a whitelist: the rule
/// is the same everywhere, so ⌘T on a docs site opens its home, and the card
/// for going somewhere *else* is ⇧⌘T.
enum NewTabTarget {

    /// Where a site starts fresh, when it isn't the root.
    private static let knownStarts: [String: String] = [
        "claude.ai": "https://claude.ai/new",
        "gemini.google.com": "https://gemini.google.com/app",
        "chat.mistral.ai": "https://chat.mistral.ai/chat",
        "chat.openai.com": "https://chatgpt.com/",
    ]

    /// The URL a new tab should open, given the page you pressed ⌘T on.
    static func url(from current: URL, rule: Prefs.NewTabRule) -> URL {
        switch rule {
        case .page:
            return current
        case .root:
            if let host = current.host?.lowercased(),
               let known = knownStarts[host.hasPrefix("www.") ? String(host.dropFirst(4)) : host],
               let url = URL(string: known) {
                return url
            }
            return root(of: current)
        }
    }

    /// scheme://host[:port]/ — everything that makes it the same site, nothing
    /// that makes it this page.
    static func root(of url: URL) -> URL {
        var comps = URLComponents()
        comps.scheme = url.scheme
        comps.host = url.host
        comps.port = url.port
        comps.path = "/"
        return comps.url ?? url
    }
}
