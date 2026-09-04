import AppKit

/// Double-click and keep dragging to move the window.
///
/// The earlier attempt at drag-anywhere guessed at intent from speed and
/// distance, and stole selections when it guessed wrong. This doesn't guess: the
/// trigger is a discrete gesture the page has almost no use for. The one thing it
/// costs is double-click-drag to extend a selection by whole words.
final class DoubleClickDrag {

    private enum State {
        case idle
        /// A double-click landed; the next drag belongs to us.
        case armed
        case dragging(windowOrigin: NSPoint, mouseOrigin: NSPoint)
    }

    private var state: State = .idle
    private var monitor: Any?

    private unowned let panel: NSWindow
    private let isEnabled: () -> Bool
    /// Told when a drag starts and stops, so the page can be frozen for its
    /// duration rather than selecting text under the moving window.
    private let setPageFrozen: (Bool) -> Void

    init(panel: NSWindow,
         isEnabled: @escaping () -> Bool,
         setPageFrozen: @escaping (Bool) -> Void) {
        self.panel = panel
        self.isEnabled = isEnabled
        self.setPageFrozen = setPageFrozen
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Returning nil swallows the event, which is how the page stops extending
    /// its selection once the window starts moving.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, isEnabled() else {
            state = .idle
            return event
        }

        switch event.type {
        case .leftMouseDown:
            // clickCount keeps climbing on a triple click; anything past the
            // first still means "not a plain click".
            state = event.clickCount >= 2 ? .armed : .idle
            return event

        case .leftMouseDragged:
            switch state {
            case .armed:
                state = .dragging(windowOrigin: panel.frame.origin,
                                  mouseOrigin: NSEvent.mouseLocation)
                setPageFrozen(true)
                return nil
            case .dragging(let windowOrigin, let mouseOrigin):
                let now = NSEvent.mouseLocation
                panel.setFrameOrigin(NSPoint(x: windowOrigin.x + (now.x - mouseOrigin.x),
                                             y: windowOrigin.y + (now.y - mouseOrigin.y)))
                return nil
            case .idle:
                return event
            }

        case .leftMouseUp:
            if case .dragging = state {
                state = .idle
                setPageFrozen(false)
                Prefs.frame = panel.frame
                return nil
            }
            state = .idle
            return event

        default:
            return event
        }
    }
}
