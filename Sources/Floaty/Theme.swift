import AppKit
import CoreText

/// The buzzkit design system, translated to AppKit.
/// Tokens only — no view ever writes a literal color, size or radius.
enum Theme {

    // MARK: - Type
    //
    // One typeface, one weight. Hierarchy comes from the fg ramp and size,
    // never from weight. Nothing is ever uppercase.

    enum Size {
        static let xs: CGFloat = 13   // captions, shortcuts
        static let sm: CGFloat = 14   // the UI default: inputs, menus, descriptions
        static let base: CGFloat = 16 // titles
    }

    /// Registers the bundled Open Runde so the app doesn't depend on the
    /// user having it installed.
    static func registerFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    static func font(_ size: CGFloat, _ weight: Weight = .medium) -> NSFont {
        NSFont(name: weight.postScriptName, size: size)
            ?? .systemFont(ofSize: size, weight: weight.systemWeight)
    }

    enum Weight {
        case regular, medium, semibold

        var postScriptName: String {
            switch self {
            case .regular: return "OpenRunde-Regular"
            case .medium: return "OpenRunde-Medium"
            case .semibold: return "OpenRunde-Semibold"
            }
        }

        var systemWeight: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            }
        }
    }

    // MARK: - Color
    //
    // The neutral ladders mapped onto AppKit's semantic colors, so both themes
    // and Increase Contrast follow the system without a single literal.

    enum Color {
        /// Recessed surface — inputs, tiles.
        static let bg2 = NSColor.quaternaryLabelColor.withAlphaComponent(0.09)
        /// The border color. Every separator and hairline ring.
        static let bg3 = NSColor.separatorColor
        /// Decorative only — never text.
        static let fg1 = NSColor.quaternaryLabelColor
        /// Secondary text — descriptions, placeholders.
        static let fg2 = NSColor.secondaryLabelColor
        /// Body text.
        static let fg3 = NSColor.labelColor
        /// Strong text — titles.
        static let fg4 = NSColor.labelColor
        /// Focus ring / checked controls.
        static let primary = NSColor.controlAccentColor
        /// The alpha neutral used to mark a selected row — tints whatever is
        /// under it rather than covering it, so it works on any surface.
        static let selection = NSColor.labelColor.withAlphaComponent(0.1)
    }

    // MARK: - Shape
    //
    // Superellipse corners via continuous curvature, applied wherever we round.

    enum Radius {
        static let control: CGFloat = 12 // inputs, the default control radius
        static let tile: CGFloat = 14
        static let card: CGFloat = 16    // the window itself
        static let dialog: CGFloat = 24  // sheets and overlays
    }

    // MARK: - Motion
    //
    // Restraint: state changes only, never arrival. Nothing choreographs in.

    enum Motion {
        static let press: TimeInterval = 0.15   // press / hover / color
        static let overlay: TimeInterval = 0.2  // overlay enter and exit
        static let easeOut = CAMediaTimingFunction(name: .easeOut)
    }
}

extension CALayer {
    /// Rounds a layer the house way — superellipse, not a plain radius.
    func applySuperellipse(_ radius: CGFloat) {
        cornerRadius = radius
        cornerCurve = .continuous
        masksToBounds = true
    }
}
