import AppKit
import Carbon.HIToolbox

/// The ⌃Tab switcher: hold ⌃, press Tab to walk the tabs, release ⌃ to land on
/// one. Same shape as the system app switcher, with page previews instead of
/// app icons.
///
/// It would have been ⌘Tab, but the WindowServer takes that before any app sees
/// it — the only way through is a CGEventTap behind an Accessibility prompt, and
/// that would break the real app switcher.
final class TabSwitcher {

    private var panel: SwitcherPanel?
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var blurObserver: NSObjectProtocol?
    private var tabs: [Tab] = []
    private var index = 0

    var isVisible: Bool { panel != nil }

    /// Called on release with the tab to land on. A tab, not an index, because
    /// the switcher's order isn't the tab bar's order.
    var onCommit: ((Tab) -> Void)?

    // MARK: - Driving

    func advance(by offset: Int, tabs: [Tab], activeIndex: Int, over host: NSWindow) {
        // One tab has nothing to switch to.
        guard tabs.count > 1 else { return }

        if panel == nil {
            self.tabs = tabs
            index = activeIndex
            // The tab we're leaving is the only one still on screen, so it's the
            // only one whose preview can be refreshed now.
            tabs[safe: activeIndex]?.captureSnapshot { [weak self] in
                self?.panel?.refresh()
            }
            present(over: host)
        }

        index = (index + offset + self.tabs.count) % self.tabs.count
        panel?.select(index)
    }

    func commit() {
        guard panel != nil else { return }
        let landing = tabs[safe: index]
        dismiss()
        if let landing { onCommit?(landing) }
    }

    func cancel() { dismiss() }

    // MARK: - Presentation

    private func present(over host: NSWindow) {
        let panel = SwitcherPanel(tabs: tabs, selected: index)
        self.panel = panel

        // Centred on the host, then nudged fully on-screen — the host is a small
        // floating window and can sit near an edge.
        let screen = host.screen ?? NSScreen.main
        var frame = panel.frame
        frame.origin = NSPoint(
            x: host.frame.midX - frame.width / 2,
            y: host.frame.midY - frame.height / 2
        )
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 12), visible.maxX - frame.width - 12)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 12), visible.maxY - frame.height - 12)
        }
        panel.setFrameOrigin(frame.origin)

        panel.onHoverIndex = { [weak self] hovered in
            guard let self else { return }
            self.index = hovered
            self.panel?.select(hovered)
        }
        panel.onClickIndex = { [weak self] clicked in
            guard let self else { return }
            self.index = clicked
            self.commit()
        }

        // orderFront, not makeKey: the host window has to keep key status or it
        // stops receiving the Tab presses that drive this.
        panel.order(.above, relativeTo: host.windowNumber)

        // The shadow is cached from the window's shape at first display — the bare
        // rectangle, before the corner mask took effect. It's then drawn just
        // outside that rectangle, so the rounded cutouts, which sit inside it, get
        // no shadow at all and read as hard white wedges on a light background.
        // Recomputing from the real alpha wraps the shadow around the corners.
        panel.invalidateShadow()
        DispatchQueue.main.async { panel.invalidateShadow() }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.control) { self?.commit() }
            return event
        }

        // esc backs out and stays on the tab you started from. This is a monitor
        // rather than cancelOperation because the web view is first responder and
        // swallows the key before it ever reaches the panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, Int(event.keyCode) == kVK_Escape else { return event }
            self.cancel()
            return nil
        }

        // Switching apps mid-hold means we never see ⌃ come back up, so the panel
        // would sit there forever. Land on the highlighted tab and get out.
        blurObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.commit()
        }
    }

    private func dismiss() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let blurObserver { NotificationCenter.default.removeObserver(blurObserver) }
        flagsMonitor = nil
        keyMonitor = nil
        blurObserver = nil
        panel?.orderOut(nil)
        panel = nil
        tabs = []
    }
}

// MARK: - Panel

private final class SwitcherPanel: NSPanel {

    private var cells: [SwitcherCell] = []

    var onHoverIndex: ((Int) -> Void)?
    var onClickIndex: ((Int) -> Void)?

    private static let columns = 4
    private static let cellSize = NSSize(width: 172, height: 142)
    private static let gap: CGFloat = 8
    /// Nested radii are concentric — outer = inner + padding — so this number and
    /// the radii are one system: panel 24 over 8 padding → cell 16 over 8 inset →
    /// preview 8. Change one and the other two have to move with it.
    private static let padding: CGFloat = 8

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(tabs: [Tab], selected: Int) {
        let columns = min(tabs.count, Self.columns)
        let rows = Int(ceil(Double(tabs.count) / Double(Self.columns)))
        let width = CGFloat(columns) * Self.cellSize.width
            + CGFloat(columns - 1) * Self.gap + Self.padding * 2
        let height = CGFloat(rows) * Self.cellSize.height
            + CGFloat(rows - 1) * Self.gap + Self.padding * 2

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let size = NSSize(width: width, height: height)
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // A behind-window blur is composited by the window server against the
        // view's shape, so a layer corner radius doesn't touch it — the corners
        // stay square and show the unclipped material. maskImage is the only
        // thing that actually rounds it.
        backdrop.maskImage = Self.cornerMask(size: size, radius: Theme.Radius.dialog)
        contentView = backdrop

        // The system shadow is real but soft, and at a rounded corner the nearest
        // edge is ~7pt away diagonally, so almost none of it reaches the corner —
        // against a white backdrop that reads as a bright notch rather than a
        // rounded panel. The hairline ring is what actually draws the edge.
        let ring = RingView()
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.wantsLayer = true
        ring.layer?.cornerRadius = Theme.Radius.dialog
        ring.layer?.cornerCurve = .continuous
        ring.layer?.borderWidth = 1
        ring.layer?.borderColor = Theme.Color.bg3.cgColor
        backdrop.addSubview(ring)
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: backdrop.topAnchor),
            ring.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Self.gap
        grid.columnSpacing = Self.gap

        var row: [NSView] = []
        for (i, tab) in tabs.enumerated() {
            let cell = SwitcherCell(tab: tab, isSelected: i == selected)
            cell.onHover = { [weak self] in self?.onHoverIndex?(i) }
            cell.onClick = { [weak self] in self?.onClickIndex?(i) }
            cells.append(cell)
            row.append(cell)
            if row.count == Self.columns {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty {
            // Pad the last row so the grid doesn't stretch the stragglers.
            while row.count < columns && tabs.count > Self.columns {
                row.append(NSView())
            }
            grid.addRow(with: row)
        }

        backdrop.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Self.padding),
            grid.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Self.padding),
            grid.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: Self.padding),
            grid.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -Self.padding),
        ])
    }

    /// Rendered through a CALayer rather than an NSBezierPath so the mask gets the
    /// same continuous corner as everything else — NSBezierPath only draws
    /// circular ones. The panel is built fresh at a known size each time it
    /// opens, so the mask can be exact and needs no cap insets.
    private static func cornerMask(size: NSSize, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let layer = CALayer()
            layer.frame = rect
            layer.backgroundColor = NSColor.black.cgColor
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
            layer.render(in: context)
            return true
        }
    }

    func select(_ index: Int) {
        for (i, cell) in cells.enumerated() {
            cell.setSelected(i == index)
        }
    }

    func refresh() {
        cells.forEach { $0.refreshPreview() }
    }
}

/// Draws the panel's edge and nothing else — it sits over every cell, so it must
/// never take a click or it would swallow hover and selection.
private final class RingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = Theme.Color.bg3.cgColor
        }
    }
}

// MARK: - Cell

private final class SwitcherCell: NSView {

    private let tab: Tab
    /// Layer-backed rather than an NSImageView: the layer gives exact aspect-fill
    /// plus real clipping, where the image view letterboxed the page and left the
    /// box's own fill showing through the rounded corners.
    private let previewBox = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isSelected: Bool
    private var hasSnapshot = false

    /// Moving the pointer over a cell moves the highlight to it, the same way
    /// the system app switcher works while the modifier is held.
    var onHover: (() -> Void)?
    /// Clicking lands on it immediately, without waiting for the ⌃ release.
    var onClick: (() -> Void)?

    init(tab: Tab, isSelected: Bool) {
        self.tab = tab
        self.isSelected = isSelected
        super.init(frame: .zero)
        build()
        setSelected(isSelected)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // activeAlways, not activeInActiveApp: the switcher panel deliberately
        // never becomes key, so it can't rely on being the active window.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        wantsLayer = true
        // Concentric with the preview inside it: 8 (preview) + 8 (inset) = 16.
        layer?.applySuperellipse(Theme.Radius.card)
        translatesAutoresizingMaskIntoConstraints = false

        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.applySuperellipse(Self.previewRadius)
        previewBox.layer?.borderWidth = 1

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.font(Theme.Size.xs, .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(previewBox)
        addSubview(iconView)
        addSubview(titleLabel)

        // One inset all the way round, and the same gap between the preview and
        // the title row: 8 + 104 + 8 + 14 + 8 = 142.
        let inset = Self.inset
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 172),
            heightAnchor.constraint(equalToConstant: 142),

            previewBox.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            previewBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            previewBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            previewBox.heightAnchor.constraint(equalToConstant: 104),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            iconView.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: inset),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])

        refreshPreview()
    }

    private static let inset: CGFloat = 8
    private static let previewRadius: CGFloat = 8
    /// 172 wide minus both insets, over 104 tall.
    private static let previewAspect: CGFloat = (172 - 16) / 104

    func refreshPreview() {
        titleLabel.stringValue = tab.displayTitle

        if let favicon = tab.favicon {
            iconView.image = favicon
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            iconView.contentTintColor = Theme.Color.fg2
        }

        // A tab restored at launch but never opened has no preview yet. Its own
        // mark, centred on the empty surface, reads as deliberate.
        previewBox.layer?.contentsScale = window?.backingScaleFactor ?? 2

        if let snapshot = tab.snapshot {
            // Fill the box and crop the overflow. Fitting the page instead would
            // letterbox it and leave the box's own fill showing through the
            // rounded corners — the white corners.
            //
            // resizeAspectFill would centre that crop; a page preview belongs at
            // the top, so take the slice ourselves. Cropping here rather than via
            // contentsRect keeps the coordinate space unambiguous — NSImage is
            // bottom-left origin, and getting that backwards would silently show
            // the bottom of every page.
            previewBox.layer?.contents = Self.topCrop(snapshot, aspect: Self.previewAspect)
            previewBox.layer?.contentsGravity = .resizeAspectFill
            hasSnapshot = true
        } else {
            // Nothing captured yet — a tab restored at launch but never opened.
            // A quiet glyph on the recessed surface reads as empty on purpose;
            // the bare white box it used to be read as broken.
            previewBox.layer?.contents = Self.placeholderGlyph
            previewBox.layer?.contentsGravity = .center
            hasSnapshot = false
        }
        applyColors()
    }

    private static let placeholderGlyph: NSImage? = {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        guard let image else { return nil }
        // Layer contents can't be tinted, so bake the colour in.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            Theme.Color.fg1.set()
            rect.fill(using: .sourceOver)
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return tinted
    }()

    /// The top slice of an image at the given aspect ratio.
    private static func topCrop(_ image: NSImage, aspect: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let sliceHeight = min(size.width / aspect, size.height)
        // NSImage's origin is bottom-left, so the top of the page is the far end.
        let source = NSRect(x: 0,
                            y: size.height - sliceHeight,
                            width: size.width,
                            height: sliceHeight)

        let cropped = NSImage(size: NSSize(width: size.width, height: sliceHeight))
        cropped.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: cropped.size),
                   from: source,
                   operation: .copy,
                   fraction: 1)
        cropped.unlockFocus()
        return cropped
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
            // A captured page sits on its own white; an empty one sits on the
            // recessed surface so it reads as a placeholder, not a blank page.
            previewBox.layer?.backgroundColor = hasSnapshot
                ? NSColor.controlBackgroundColor.cgColor
                : Theme.Color.bg2.cgColor
            previewBox.layer?.borderColor = Theme.Color.bg3.cgColor
            titleLabel.textColor = isSelected ? Theme.Color.fg4 : Theme.Color.fg2
        }
    }
}

// MARK: -

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
