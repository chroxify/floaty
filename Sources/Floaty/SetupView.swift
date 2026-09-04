import AppKit

/// The one piece of chrome Floaty owns: asked once on first run, and again
/// on ⌘L when you want a different page. Everything else is just the web view.
final class SetupView: NSView {

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Favicons for suggestions, when this session happens to have one.
    var faviconProvider: ((String) -> NSImage?)?
    /// False on first run — there is nothing to go back to, so esc shouldn't dismiss.
    var isDismissable = true

    private let backdrop = NSVisualEffectView()
    private let tile = NSView()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Floaty")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let fieldBox = NSView()
    private let field = SetupTextField()
    private let suggestions = NSStackView()

    /// Everything we could offer, and the slice currently shown.
    private var pool: [HistoryEntry] = []
    private var shown: [HistoryEntry] = []
    /// -1 means "open what's typed" rather than a suggestion.
    private var selection = -1
    /// More than this and the card stops being a card.
    private let maxRows = 5
    /// Held so the block can be re-centred as the list grows and shrinks.
    private var blockCentre: NSLayoutConstraint!

    override var acceptsFirstResponder: Bool { false }

    init(title: String, description: String, placeholder: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description
        field.placeholderString = placeholder
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Build

    private func build() {
        wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        addSubview(backdrop)

        // Icon tile — a glyph on a soft recessed surface, wearing its hairline ring.
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.applySuperellipse(Theme.Radius.tile)
        tile.layer?.borderWidth = 1

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(
            systemSymbolName: "square.on.square.dashed",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
        glyph.imageScaling = .scaleNone
        tile.addSubview(glyph)

        // One weight throughout — size and the fg ramp carry the hierarchy.
        style(titleLabel, size: Theme.Size.base, weight: .medium, color: Theme.Color.fg4)
        style(descriptionLabel, size: Theme.Size.sm, weight: .regular, color: Theme.Color.fg2)
        descriptionLabel.alignment = .center
        titleLabel.alignment = .center

        fieldBox.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.wantsLayer = true
        fieldBox.layer?.applySuperellipse(Theme.Radius.control)
        fieldBox.layer?.borderWidth = 1

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(Theme.Size.sm, .medium)
        field.textColor = Theme.Color.fg4
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingHead
        field.delegate = self
        field.onFocusChange = { [weak self] in self?.applyColors() }
        fieldBox.addSubview(field)

        addSubview(tile)
        addSubview(titleLabel)
        addSubview(descriptionLabel)
        addSubview(fieldBox)

        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestions.orientation = .vertical
        suggestions.spacing = 1
        suggestions.alignment = .leading
        addSubview(suggestions)

        // Offset so the block as a whole reads optically centered, not the tile.
        blockCentre = tile.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -68)
        blockCentre.priority = .defaultHigh
        let centerY = blockCentre!

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            tile.widthAnchor.constraint(equalToConstant: 48),
            tile.heightAnchor.constraint(equalToConstant: 48),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            // A title and its description sit 2px apart. Everywhere.
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            descriptionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            descriptionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            fieldBox.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 20),
            fieldBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            fieldBox.heightAnchor.constraint(equalToConstant: 34),
            fieldBox.widthAnchor.constraint(equalToConstant: 268),
            fieldBox.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),

            field.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 11),
            field.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -11),
            field.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            suggestions.topAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: 8),
            suggestions.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor),
            suggestions.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor),
        ])

        applyColors()
    }

    private func style(_ label: NSTextField, size: CGFloat, weight: Theme.Weight, color: NSColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.font(size, weight)
        label.textColor = color
        label.isSelectable = false
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Semantic colors have to be resolved against the current appearance before
    /// they reach a layer, so every theme change re-runs this.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tile.layer?.backgroundColor = Theme.Color.bg2.cgColor
            tile.layer?.borderColor = Theme.Color.bg3.cgColor
            glyph.contentTintColor = Theme.Color.fg2

            fieldBox.layer?.backgroundColor = Theme.Color.bg2.cgColor
            let focused = field.hasFocus
            fieldBox.layer?.borderColor = focused
                ? Theme.Color.primary.cgColor
                : Theme.Color.bg3.cgColor
            fieldBox.layer?.borderWidth = focused ? 1.5 : 1
        }
    }

    // MARK: - Presentation

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func prefill(_ text: String) {
        field.stringValue = text
        reloadSuggestions()
    }

    /// Pages to offer under the field. Passing an empty list hides the section
    /// entirely rather than leaving a gap.
    func setSuggestions(_ entries: [HistoryEntry]) {
        pool = entries
        reloadSuggestions()
    }

    private func reloadSuggestions() {
        let query = field.stringValue
        shown = Array(History.match(query, in: pool).prefix(maxRows))
        // Typing narrows to one obvious answer; keep it highlighted so return
        // opens it. With nothing typed, return should still open what you type.
        selection = query.trimmingCharacters(in: .whitespaces).isEmpty ? -1 : (shown.isEmpty ? -1 : 0)

        suggestions.arrangedSubviews.forEach {
            suggestions.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, entry) in shown.enumerated() {
            let row = HistoryRow(entry: entry, favicon: faviconProvider?(entry.url))
            row.onPick = { [weak self] in self?.onSubmit?(entry.url) }
            row.onHover = { [weak self] in self?.select(index) }
            suggestions.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: suggestions.widthAnchor).isActive = true
        }
        // Lift the whole block by half the list, so card and suggestions stay
        // centred together rather than the card sitting still while the list
        // pushes off the bottom.
        let listHeight = shown.isEmpty
            ? 0
            : CGFloat(shown.count) * HistoryRow.height + CGFloat(shown.count - 1)
        blockCentre.constant = -68 - listHeight / 2
        applySelection()
    }

    private func select(_ index: Int) {
        selection = index
        applySelection()
    }

    private func applySelection() {
        for (index, view) in suggestions.arrangedSubviews.enumerated() {
            (view as? HistoryRow)?.setSelected(index == selection)
        }
    }

    /// Arrow keys walk the list, and stepping off the top returns to the field so
    /// return opens whatever you typed.
    fileprivate func moveSelection(by offset: Int) {
        guard !shown.isEmpty else { return }
        let next = selection + offset
        selection = next < -1 ? shown.count - 1 : (next >= shown.count ? -1 : next)
        applySelection()
    }

    /// What return should open: the highlighted suggestion, or the typed text.
    fileprivate var committedText: String? {
        if shown.indices.contains(selection) { return shown[selection].url }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : typed
    }

    /// Overlays fade; they never slide or scale in.
    func dismiss(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.overlay
            context.timingFunction = Theme.Motion.easeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.alphaValue = 1
            completion?()
        }
    }
}

// MARK: - NSTextFieldDelegate

extension SetupView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reloadSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let text = committedText else { return true }
            onSubmit?(text)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }
}

// MARK: - Field

/// Reports focus changes so the box can draw its own ring — the field's
/// native focus ring is off.
final class SetupTextField: NSTextField {
    var onFocusChange: (() -> Void)?
    private(set) var hasFocus = false

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { hasFocus = true; onFocusChange?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { hasFocus = false; onFocusChange?() }
        return ok
    }
}
