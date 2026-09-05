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

    private let icon = TabIconView()
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

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.favicon = favicon
        icon.status = status
        addSubview(icon)

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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TabIconView.size),
            icon.heightAnchor.constraint(equalToConstant: TabIconView.size),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
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

/// The 14pt slot at the front of a tab. Shows the favicon — until the page has
/// something to say, when the status takes the slot over entirely. The favicon
/// is what a tab looks like at rest; a state is more important than a logo, so
/// it gets the whole slot rather than a corner of it.
///
/// The indicators are Kanna's own, reproduced exactly, so a chat looks the same
/// in Floaty's strip as in Kanna's sidebar (`renderChatStatusDot`):
/// - working: lucide's loader-circle — a 315° arc, 2/24 stroke, round caps —
///   in Kanna's logo colour, one turn per second, linear.
/// - waiting / done: a 10px dot, blue-400 / emerald-400, with a ping ring
///   behind it scaling to 2× and fading out over a second.
/// - failed: Kanna's sidebar shows nothing; here a red dot, no ping — a failed
///   turn is worth a mark.
final class TabIconView: NSView {

    static let size: CGFloat = 14

    var favicon: NSImage? { didSet { apply() } }
    var status: PageStatus = .idle { didSet { apply() } }

    private let imageView = NSImageView()
    private let dot = CALayer()
    private let ping = CALayer()
    private let arc = CAShapeLayer()

    private static let dotSize: CGFloat = 10                 // size-2.5
    private static let arcSize: CGFloat = 14                 // size-3.5
    private static let arcWidth: CGFloat = 14 * 2 / 24        // lucide stroke 2 on a 24 box
    private static let arcSweep: CGFloat = 0.875             // loader-circle: 315°

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for l in [ping, dot] {
            l.cornerRadius = Self.dotSize / 2
            l.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            layer?.addSublayer(l)   // ping first, so it sits behind the dot
        }

        arc.bounds = CGRect(x: 0, y: 0, width: Self.arcSize, height: Self.arcSize)
        arc.path = CGPath(ellipseIn: arc.bounds.insetBy(dx: Self.arcWidth / 2, dy: Self.arcWidth / 2), transform: nil)
        arc.fillColor = nil
        arc.lineWidth = Self.arcWidth
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = Self.arcSweep
        layer?.addSublayer(arc)

        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.position = centre
        ping.position = centre
        arc.position = centre
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        toolTip = status.label.isEmpty ? nil : status.label

        guard let color = status.color else {
            imageView.isHidden = false
            dot.isHidden = true
            ping.isHidden = true
            ping.removeAllAnimations()
            arc.isHidden = true
            arc.removeAllAnimations()
            if let favicon {
                imageView.image = favicon
                imageView.contentTintColor = nil
            } else {
                imageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
                imageView.contentTintColor = Theme.Color.fg2
            }
            return
        }

        imageView.isHidden = true
        dot.backgroundColor = color.cgColor
        ping.backgroundColor = color.withAlphaComponent(0.8).cgColor   // bg-blue-400/80
        arc.strokeColor = color.cgColor

        if status == .working {
            dot.isHidden = true
            ping.isHidden = true
            ping.removeAllAnimations()
            arc.isHidden = false
            if arc.animation(forKey: "spin") == nil {
                // Tailwind animate-spin: one turn per second, linear, clockwise.
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 1.0
                spin.repeatCount = .infinity
                spin.timingFunction = CAMediaTimingFunction(name: .linear)
                arc.add(spin, forKey: "spin")
            }
            return
        }

        arc.isHidden = true
        arc.removeAllAnimations()
        dot.isHidden = false

        // Kanna's `kanna-ping`: scale 1 → 2 and opacity → 0 by 75%, held to
        // 100%, one second, forever. Waiting and done only, as in the sidebar.
        let pings = status == .waiting || status == .done
        ping.isHidden = !pings
        if pings, ping.animation(forKey: "ping") == nil {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1.0, 2.0, 2.0]
            scale.keyTimes = [0, 0.75, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1.0, 0.0, 0.0]
            fade.keyTimes = [0, 0.75, 1]
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.0
            group.repeatCount = .infinity
            ping.add(group, forKey: "ping")
        } else if !pings {
            ping.removeAllAnimations()
        }
    }
}
