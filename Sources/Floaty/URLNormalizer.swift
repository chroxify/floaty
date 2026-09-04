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
