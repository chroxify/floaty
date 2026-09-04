import AppKit

/// The strip above the page. Tabs stretch to fill it, the active one wears a
/// solid pill, and the empty space around them drags the window — which is what
/// a title bar would have done if this window had one.
final class TabBarView: NSView {

    static let height: CGFloat = 38

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let separator = NSBox()
    private let stack = NSStackView()
    private let newTabButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .headerView
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        addSubview(backdrop)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        addSubview(separator)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        addSubview(stack)

        let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.image = plus
        newTabButton.isBordered = false
        newTabButton.bezelStyle = .texturedRounded
        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        newTabButton.contentTintColor = Theme.Color.fg2
        newTabButton.toolTip = "New tab (⌘T)"
        addSubview(newTabButton)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 28),

            newTabButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 4),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 24),
            newTabButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Content

    func reload(tabs: [Tab], activeIndex: Int) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, tab) in tabs.enumerated() {
            let item = TabItemView(
                title: tab.displayTitle,
                favicon: tab.favicon,
                isActive: index == activeIndex,
                // A lone tab has no close affordance — closing it would leave nothing.
                canClose: tabs.count > 1
            )
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            stack.addArrangedSubview(item)
        }
    }

    @objc private func newTab() { onNewTab?() }

    // MARK: - Dragging

    /// Empty strip is a grab handle. Tabs sit on top and take their own clicks,
    /// so this only fires on the gaps.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// Start dragging on the click that focuses the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A single tab: favicon, title, and a close button that only appears on hover.
final class TabItemView: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isActive: Bool
    private let canClose: Bool
    private var isHovered = false
    private var didDrag = false
    private var downLocation: NSPoint?

    init(title: String, favicon: NSImage?, isActive: Bool, canClose: Bool) {
        self.isActive = isActive
        self.canClose = canClose
        super.init(frame: .zero)
        build(title: title, favicon: favicon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(title: String, favicon: NSImage?) {
        wantsLayer = true
        layer?.applySuperellipse(10) // the xs/sm control radius

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        if let favicon {
            iconView.image = favicon
        } else {
            iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            iconView.contentTintColor = Theme.Color.fg2
        }
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.font(Theme.Size.xs, .medium)
        titleLabel.textColor = isActive ? Theme.Color.fg4 : Theme.Color.fg2
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.Color.fg2
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.isHidden = true
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isActive {
                // The active tab is a solid surface wearing a hairline ring.
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                layer?.borderWidth = 1
                layer?.borderColor = Theme.Color.bg3.cgColor
            } else {
                layer?.backgroundColor = isHovered ? Theme.Color.bg2.cgColor : NSColor.clear.cgColor
                layer?.borderWidth = 0
            }
        }
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if canClose { closeButton.isHidden = false }
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeButton.isHidden = true
        applyColors()
    }

    /// Switch tabs on the click that focuses the window, not the one after it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Tabs stretch to fill the strip, so if only the gaps between them dragged
    /// there'd be almost nothing to grab. Dragging a tab moves the window — free,
    /// since there's no reordering to conflict with.
    ///
    /// Selection lands on mouse *up*, so starting a drag from a tab never
    /// switches to it on the way past.
    override func mouseDown(with event: NSEvent) {
        didDrag = false
        downLocation = NSEvent.mouseLocation
        if event.modifierFlags.contains(.command) {
            didDrag = true
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let start = downLocation else { return }
        let now = NSEvent.mouseLocation
        // A couple of points of jitter during a click isn't a drag.
        guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
        didDrag = true
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // performDrag runs its own event loop and swallows the mouse up, so this
        // only runs when the gesture stayed a click.
        guard !didDrag else {
            didDrag = false
            return
        }
        onSelect?()
    }

    @objc private func close() { onClose?() }
}
