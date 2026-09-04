import AppKit

/// Favicons kept on disk, keyed by host.
///
/// The suggestion list needs marks for pages that aren't open — in fact it only
/// ever shows pages that *aren't* open — so asking the live tabs for them, as an
/// earlier version did, could never return anything. Caching by host also means
/// the list has icons on the very first launch after a restart.
enum FaviconCache {

    private static var memo: [String: NSImage] = [:]

    private static let directory: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.christo.floaty")
            .appendingPathComponent("Favicons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Hosts vary in case and in the www prefix; the mark doesn't.
    private static func key(forHost host: String) -> String {
        host.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    private static func file(forHost host: String) -> URL? {
        // Ports and colons aren't safe in a filename, and localhost:3000 is a
        // perfectly ordinary host here.
        let safe = key(forHost: host).replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return directory?.appendingPathComponent(safe + ".png")
    }

    static func store(_ image: NSImage, host: String) {
        let key = key(forHost: host)
        memo[key] = image
        guard let file = file(forHost: host),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file)
    }

    static func image(forHost host: String) -> NSImage? {
        let key = key(forHost: host)
        if let cached = memo[key] { return cached }
        guard let file = file(forHost: host),
              let image = NSImage(contentsOf: file) else { return nil }
        memo[key] = image
        return image
    }

    /// For a full URL, which is what history stores.
    static func image(for urlString: String) -> NSImage? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return image(forHost: host)
    }

    /// Nothing cached yet — most likely a page from before favicons were being
    /// stored — so try the conventional path once. Without this the suggestion
    /// list shows nothing but globes until you've re-visited everything.
    static func fetch(for urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: urlString), let host = url.host else {
            completion(nil)
            return
        }
        if let cached = image(forHost: host) { completion(cached); return }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(nil)
            return
        }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        guard let iconURL = components.url else { completion(nil); return }

        URLSession.shared.dataTask(with: iconURL) { data, response, _ in
            // A single-page app answers unknown paths with its own document.
            let mime = response?.mimeType?.lowercased() ?? ""
            guard !mime.hasPrefix("text/"), !mime.contains("html"),
                  let data, let image = NSImage(data: data), image.isValid,
                  image.size.width > 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let mark = circular(image)
            DispatchQueue.main.async {
                store(mark, host: host)
                completion(mark)
            }
        }.resume()
    }

    /// Favicons arrive in every shape there is. Clipping them all to a circle is
    /// the only treatment that looks deliberate across a column of them.
    static func circular(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
