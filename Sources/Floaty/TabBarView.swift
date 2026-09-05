import AppKit

/// What a tab's right-click menu can do to it.
enum TabMenuAction {
    case reload, duplicate, copyLink, openInBrowser, close, closeOthers
}

/// The strip above the page. Tabs stretch to fill it, the active one wears a
/// solid pill, and the empty space around them drags the window — which is what
/// a title bar would have done if this window had one.
final class TabBarView: NSView {

    static let height: CGFloat = 38

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onMenuAction: ((TabMenuAction, Int) -> Void)?

    /// Carries which action on which tab through an NSMenuItem.
    private struct MenuChoice {
        let action: TabMenuAction
        let index: Int
    }

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
        newTabButton.toolTip = "Open in new tab (⇧⌘T)"
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
                status: tab.status,
                isActive: index == activeIndex,
                // A lone tab has no close affordance — closing it would leave nothing.
                canClose: tabs.count > 1,
                // A hairline where the group changes — between two Kanna projects,
                // between Kanna and GitHub. Read off the current order, so nothing
                // ever moves to make a group; "Group Tabs" in the menu does that.
                startsGroup: index > 0 && tabs[index - 1].groupKey != tab.groupKey
            )
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.menuProvider = { [weak self] in self?.contextMenu(for: index, of: tabs.count) }
            stack.addArrangedSubview(item)
        }
    }

    @objc private func newTab() { onNewTab?() }

    // MARK: - Context menu

    /// The things you'd otherwise reach for a shortcut or the menubar to do to a
    /// tab, on the tab. Shortcuts are shown where one exists so the menu also
    /// teaches them.
    private func contextMenu(for index: Int, of count: Int) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: TabMenuAction, key: String = "", mods: NSEvent.ModifierFlags = .command, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            item.target = self
            item.representedObject = MenuChoice(action: action, index: index)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        add("Reload", .reload, key: "r")
        add("Duplicate Tab", .duplicate)
        menu.addItem(.separator())
        add("Copy Link", .copyLink, key: "c", mods: [.command, .shift])
        add("Open in Browser", .openInBrowser)
        menu.addItem(.separator())
        add("Close Tab", .close, key: "w")
        add("Close Other Tabs", .closeOthers, enabled: count > 1)
        return menu
    }

    @objc private func menuAction(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? MenuChoice else { return }
        onMenuAction?(choice.action, choice.index)
    }

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
    /// Built on demand, so it reflects the tab set at the moment of the click.
    var menuProvider: (() -> NSMenu?)?

    private let iconView = NSImageView()
    private let statusDot = StatusDot()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isActive: Bool
    private let canClose: Bool
    private var isHovered = false
    private var didDrag = false
    private var downLocation: NSPoint?

    init(title: String, favicon: NSImage?, status: PageStatus, isActive: Bool, canClose: Bool,
         startsGroup: Bool = false) {
        self.isActive = isActive
        self.canClose = canClose
        super.init(frame: .zero)
        build(title: title, favicon: favicon, status: status)
        if startsGroup { addGroupDivider() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A 1pt hairline standing in the gap before this tab, 12pt tall so it reads
    /// as a divider rather than a border.
    private func addGroupDivider() {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Color.bg3.cgColor
        addSubview(line)
        NSLayoutConstraint.activate([
            // Centred in the 4pt stack gap: 2pt outside our leading edge.
            line.centerXAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    private func build(title: String, favicon: NSImage?, status: PageStatus) {
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

        // On the favicon's corner, the way presence badges sit on avatars: it
        // reads as "this tab's state" without taking a slot of its own.
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.status = status
        statusDot.toolTip = status.label
        addSubview(statusDot)

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

            statusDot.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
            statusDot.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            statusDot.widthAnchor.constraint(equalToConstant: StatusDot.size),
            statusDot.heightAnchor.constraint(equalToConstant: StatusDot.size),

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

    /// Right-click. Doesn't select the tab — you asked about it, not for it.
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    @objc private func close() { onClose?() }
}

/// A page-status badge: a filled dot with a ring in the surface colour so it
/// separates from the favicon under it. Hidden for idle. "Working" breathes —
/// the one place motion earns its keep, because the state itself is ongoing.
/// It breathes by size, never by opacity: the dot has to stay solid to be
/// readable over a favicon at 8pt.
final class StatusDot: NSView {

    static let size: CGFloat = 8

    var status: PageStatus = .idle {
        didSet { apply() }
    }

    /// The dot is a sublayer rather than the view's own layer: AppKit anchors a
    /// view's layer at its corner, so a scale animation on it would shrink the
    /// dot towards the corner instead of breathing in place.
    private let dot = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.cornerRadius = Self.size / 2
        dot.borderWidth = 1.5
        layer?.addSublayer(dot)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = CGRect(origin: .zero, size: bounds.size)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        guard let color = status.color else {
            isHidden = true
            dot.removeAllAnimations()
            return
        }
        isHidden = false
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = color.cgColor
            dot.borderColor = NSColor.windowBackgroundColor.cgColor
        }
        dot.removeAllAnimations()
        dot.opacity = 1
        if status == .working {
            // Barely: enough to read as alive from the corner of the eye, not
            // enough to draw the eye to it.
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 0.85
            pulse.duration = 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }
}
