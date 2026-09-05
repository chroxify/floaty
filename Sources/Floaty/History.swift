import AppKit

/// A page you've had open before, offered back on the new-tab card.
struct HistoryEntry: Equatable {
    var url: String
    var title: String

    var host: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    /// What the row shows as its heading — the page title with the site's name
    /// stripped (the row shows the host on its own line), or the host when the
    /// page never gave one.
    var displayTitle: String {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return host }
        let cleaned = TabTitle.clean(title, url: URL(string: url))
        return cleaned.context.map { "\(cleaned.title) › \($0)" } ?? cleaned.title
    }
}

/// Recently visited pages, most recent first.
///
/// Deliberately not a full browsing history: one entry per URL, capped, and only
/// pages that finished loading with a title. It exists to answer "the thing I had
/// open yesterday", not to be a record of everywhere you've been.
enum History {
    private static let limit = 60
    private static let key = "history"
    private static let d = UserDefaults.standard

    static var entries: [HistoryEntry] {
        get {
            (d.stringArray(forKey: key) ?? []).compactMap { line in
                // url<TAB>title — a tab can't appear in either half.
                let parts = line.components(separatedBy: "\t")
                guard let url = parts.first, !url.isEmpty else { return nil }
                return HistoryEntry(url: url, title: parts.count > 1 ? parts[1] : "")
            }
        }
        set {
            d.set(newValue.prefix(limit).map { "\($0.url)\t\($0.title)" }, forKey: key)
        }
    }

    /// Newest wins: re-visiting a page moves it up rather than duplicating it.
    static func record(url: String, title: String) {
        guard let parsed = URL(string: url), parsed.host != nil else { return }
        var list = entries
        list.removeAll { $0.url == url }
        list.insert(HistoryEntry(url: url, title: title), at: 0)
        entries = list
    }

    static func remove(url: String) {
        entries = entries.filter { $0.url != url }
    }

    static func clear() {
        d.removeObject(forKey: key)
    }

    /// Matches on title and URL together, so "google" finds both a page called
    /// Google and one at google.com.
    static func match(_ query: String, in pool: [HistoryEntry]) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return pool }
        return pool.filter {
            $0.title.lowercased().contains(trimmed) || $0.url.lowercased().contains(trimmed)
        }
    }
}
