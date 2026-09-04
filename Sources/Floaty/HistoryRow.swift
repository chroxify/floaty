import AppKit

/// One suggestion under the new-tab field: title over host, with the favicon if
/// we happen to have one cached from this session.
final class HistoryRow: NSView {

    static let height: CGFloat = 36

    var onPick: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private var isSelected = false

    init(entry: HistoryEntry, favicon: NSImage?) {
        super.init(frame: .zero)
        build(entry: entry, favicon: favicon)
        guard favicon == nil else { return }
        // Nothing cached for this host yet; go and get one so the list isn't a
        // column of identical globes.
        FaviconCache.fetch(for: entry.url) { [weak self] mark in
            guard let self, let mark else { return }
            self.iconView.image = mark
            self.iconView.contentTintColor = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(entry: HistoryEntry, favicon: NSImage?) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.applySuperellipse(8)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        if let favicon {
            iconView.image = favicon
        } else {
            iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            iconView.contentTintColor = Theme.Color.fg1
        }
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.font(Theme.Size.xs, .medium)
        titleLabel.textColor = Theme.Color.fg4
        titleLabel.stringValue = entry.displayTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.font = Theme.font(Theme.Size.xs, .regular)
        hostLabel.textColor = Theme.Color.fg2
        hostLabel.stringValue = entry.host
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.cell?.usesSingleLineMode = true
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(hostLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The host takes what the title doesn't, and gives way first.
            hostLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                               constant: 8),
            hostLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hostLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyColors()
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected
                ? Theme.Color.selection.cgColor
                : NSColor.clear.cgColor
        }
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Hovering moves the selection, so the pointer and the arrow keys drive the
    /// same highlight rather than showing two.
    override func mouseEntered(with event: NSEvent) { onHover?() }
    var onHover: (() -> Void)?

    override func mouseUp(with event: NSEvent) { onPick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
