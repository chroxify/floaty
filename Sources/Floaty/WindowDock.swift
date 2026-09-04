import AppKit
import CoreGraphics

/// What Floaty is glued to.
enum DockMode: Equatable {
    case off
    /// Whatever app you're using, retargeting as you switch.
    case activeWindow
    /// A whitelist. Floaty follows whichever of these is frontmost, and — with
    /// `dockOnlyWhileFocused` — shows only while one of them is.
    case apps(Set<String>)

    var storage: String {
        switch self {
        case .off: return "off"
        case .activeWindow: return "active"
        case .apps(let ids): return "apps:" + ids.sorted().joined(separator: ",")
        }
    }

    init(storage: String) {
        switch storage {
        case "active":
            self = .activeWindow
        case let s where s.hasPrefix("apps:"):
            let ids = Set(String(s.dropFirst(5)).split(separator: ",").map(String.init))
            self = ids.isEmpty ? .off : .apps(ids)
        case let s where s.hasPrefix("app:"):
            // Older installs pinned exactly one app.
            self = .apps([String(s.dropFirst(4))])
        default:
            self = .off
        }
    }

    var bundleIDs: Set<String> {
        if case .apps(let ids) = self { return ids }
        return []
    }
}

enum DockSide: String {
    case auto, left, right
}

/// Keeps the window glued to another app's window: a small gap off one side,
/// following it as it moves and resizes.
///
/// Tracking is done by polling `CGWindowListCopyWindowInfo`, which reads window
/// frames with no Accessibility permission — the same reason the global hotkey
/// uses Carbon. The alternative, an AXObserver, would be smoother during a drag
/// but puts a permission prompt in front of a feature you haven't tried yet.
final class WindowDock {

    /// Breathing room between the two windows — the same inset on both axes, so
    /// a docked window sits as far from the parent's top as from its side.
    private var gap: CGFloat { Prefs.dockGap }
    /// While the parent is moving, keep up with it — one poll per display frame.
    ///
    /// Polling faster than the screen redraws doesn't help: the extra samples land
    /// between frames and are never shown. A velocity-projection pass was tried on
    /// top of this and removed — predicting ahead and correcting back on the next
    /// sample reads as wobble, which is worse than trailing cleanly by a frame.
    private let activeInterval: TimeInterval = 1.0 / 60
    /// When nothing has moved for a moment, stop burning a core.
    private let idleInterval: TimeInterval = 1.0 / 10
    /// Ticks of stillness before backing off.
    private let idleAfter = 30

    private unowned let panel: NSWindow
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// The app we follow in `.activeWindow` mode. Held separately because
    /// clicking Floaty makes Floaty frontmost, which must not retarget us.
    private var lastActivePID: pid_t?
    /// The last whitelisted app we followed, so leaving it briefly doesn't lose
    /// the target.
    private var lastWhitelistedPID: pid_t?
    /// Last visibility we asked for, so we only signal on a change.
    private var lastVisibilityRequest: Bool?
    private var stillTicks = 0
    private var currentSide: DockSide = .right
    private var lastParentFrame: CGRect?
    /// When we started waiting to reappear, so the wait can be capped.
    private var showWaitStart: TimeInterval?
    /// Longest we'll hold the window back waiting for the target's window to
    /// come forward. Normally it takes a frame or two.
    private let showWaitLimit: TimeInterval = 0.25

    /// True while we're the ones moving the window, so our own moves don't get
    /// mistaken for the user repositioning it — and so the window's saved frame
    /// isn't rewritten on every tick.
    private(set) var isRepositioning = false

    /// Held in memory while you drag and written once on release. Recording
    /// straight to Prefs would be a UserDefaults write per frame.
    private var verticalOffset: CGFloat = Prefs.dockVerticalOffset
    private var draggingPanel = false

    /// The frame we last set, read back after setting so rounding can't make it
    /// look like the user moved us. Any difference from this means they did.
    private var lastSetFrame: CGRect?

    var onStateChange: (() -> Void)?
    /// Whether Floaty should be on screen at all. Only ever false in whitelist
    /// mode with "only while focused" on.
    var onVisibilityChange: ((Bool) -> Void)?

    init(panel: NSWindow) {
        self.panel = panel
        observeActivation()
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    // MARK: - Control

    var isDocked: Bool { Prefs.dockMode != .off }

    func start() {
        stop()
        guard isDocked else { return }
        // Seed the target so `.activeWindow` has something to follow before you
        // switch apps — otherwise docking looks broken until you alt-tab once.
        if lastActivePID == nil {
            let ours = ProcessInfo.processInfo.processIdentifier
            lastActivePID = NSWorkspace.shared.runningApplications.first {
                $0.isActive && $0.processIdentifier != ours
            }?.processIdentifier
        }
        schedule(interval: activeInterval)
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastParentFrame = nil
        lastSetFrame = nil
        // Undocking must never leave the window stranded off screen.
        if lastVisibilityRequest == false { onVisibilityChange?(true) }
        lastVisibilityRequest = nil
    }

    /// The app currently being followed, so focus can be handed back to it.
    var targetApplication: NSRunningApplication? {
        guard isDocked, let pid = targetPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Where focus goes when leaving Floaty: the docked window if there is one,
    /// otherwise whatever you were in last. Tracked even when undocked, so the
    /// swap works either way.
    var focusReturnTarget: NSRunningApplication? {
        if let target = targetApplication { return target }
        guard let pid = lastActivePID else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// In whitelist mode you usually want Floaty out of the way when you're not
    /// in one of those apps. Floaty itself counts as focused, or clicking it
    /// would dismiss it.
    private var shouldBeVisible: Bool {
        guard case .apps(let ids) = Prefs.dockMode, Prefs.dockOnlyWhileFocused else { return true }
        guard let front = NSWorkspace.shared.frontmostApplication else { return true }
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        return front.bundleIdentifier.map(ids.contains) ?? false
    }

    func refresh() {
        verticalOffset = Prefs.dockVerticalOffset
        if isDocked { start() } else { stop() }
        onStateChange?()
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        // Common mode, or the timer stalls the moment a menu opens.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observeActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            self.lastActivePID = app.processIdentifier
            // A new target means the old cached frame is meaningless.
            self.lastParentFrame = nil
            self.stillTicks = 0
            if self.isDocked { self.schedule(interval: self.activeInterval); self.tick() }
        }

        // The whitelist cares which app is frontmost, including when it's ours.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isDocked else { return }
            self.tick()
        }
    }

    // MARK: - The loop

    private func tick() {
        guard isDocked else { return }

        let visible = shouldBeVisible
        if visible != lastVisibilityRequest {
            if visible {
                // Coming back: move first, show second. The window keeps the
                // frame it had when it was hidden, and ordering it front there
                // and correcting on the next tick reads as a jump.
                //
                // But don't trust the first read. The activation notification
                // arrives *before* the window server has brought the app's
                // windows forward, so a poll taken right then still sees the
                // old app's window in front — and for an app with several
                // windows, the wrong one of its own as frontmost. Comparing two
                // polls doesn't help: activation fires two observers that each
                // tick synchronously, so the "two" reads are the same instant.
                // The real signal is the window list itself: wait until the
                // target's window is the frontmost normal window, which is what
                // activation is about to make true. Capped, so an app with no
                // window to bring forward can't keep Floaty hidden.
                let now = ProcessInfo.processInfo.systemUptime
                if showWaitStart == nil { showWaitStart = now }
                let ready = targetIsFrontmostWindow() || now - showWaitStart! > showWaitLimit
                guard ready else {
                    if stillTicks >= idleAfter { schedule(interval: activeInterval) }
                    stillTicks = 0
                    return
                }
                showWaitStart = nil
                if let parent = parentFrame() {
                    place(against: parent)
                    lastParentFrame = parent
                }
            } else {
                showWaitStart = nil
            }
            lastVisibilityRequest = visible
            onVisibilityChange?(visible)
        }
        guard visible, panel.isVisible else { return }

        guard let parent = parentFrame() else {
            // Target has no window right now — minimised, or between windows.
            // Leave Floaty where it is rather than flinging it somewhere.
            return
        }

        // `pressedMouseButtons` is system-wide, so a button held anywhere — most
        // often dragging the parent window itself — looks identical to dragging
        // Floaty. The distinguishing fact is whether *our* frame moved without us
        // moving it. Testing the button alone made the dock freeze for the whole
        // of the parent's drag and then snap at the end.
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let movedByUser = lastSetFrame.map { $0 != panel.frame } ?? false

        if buttonDown && movedByUser {
            draggingPanel = true
            recordUserPosition(against: parent)
            lastParentFrame = parent
            stillTicks = 0
            return
        }
        if draggingPanel && !buttonDown {
            draggingPanel = false
            Prefs.dockVerticalOffset = verticalOffset
        }

        if parent == lastParentFrame {
            stillTicks += 1
            if stillTicks == idleAfter { schedule(interval: idleInterval) }
        } else {
            if stillTicks >= idleAfter { schedule(interval: activeInterval) }
            stillTicks = 0
        }
        lastParentFrame = parent
        place(against: parent)
    }

    /// Moves the window to where it belongs next to `parent`, if it isn't there.
    private func place(against parent: CGRect) {
        let target = dockedFrame(against: parent)
        guard target != panel.frame else { return }

        isRepositioning = true
        panel.setFrame(target, display: true)
        // Read back rather than storing `target`: AppKit can round, and a 0.5pt
        // difference would read as the user having moved the window.
        lastSetFrame = panel.frame
        isRepositioning = false
    }

    // MARK: - Geometry

    /// The frame of the target app's main window, in AppKit screen coordinates.
    ///
    /// "Main" needs care: alerts, sheets, popovers and save dialogs are all layer
    /// 0 too, and they arrive *in front*, so simply taking the frontmost window
    /// means an alert steals the dock and Floaty jumps to it. They're small next
    /// to the document window they interrupt, so anything well under the biggest
    /// window's area is discarded, and the frontmost of what remains wins —
    /// which keeps retargeting working for apps with several real windows.
    private func parentFrame() -> CGRect? {
        guard let pid = targetPID() else { return nil }
        // CGWindowList is ordered front to back, and this preserves that.
        let candidates = normalWindows().filter { $0.pid == pid }.map(\.frame)
        guard let largest = candidates.map({ $0.width * $0.height }).max() else { return nil }
        let mainWindow = candidates.first { $0.width * $0.height >= largest * Self.mainWindowAreaShare }
        return mainWindow.map(Self.flipToAppKit)
    }

    /// Whether the window at the very front of the normal layer belongs to the
    /// target — i.e. the window server has finished bringing it forward.
    private func targetIsFrontmostWindow() -> Bool {
        guard let pid = targetPID() else { return false }
        return normalWindows().first?.pid == pid
    }

    /// Every real, visible, layer-0 window on screen, front to back, in
    /// CGWindowList's top-left coordinates. Layer 0 is a normal window; panels,
    /// menus, tooltips and our own floating window all sit above it.
    private func normalWindows() -> [(pid: pid_t, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        var result: [(pid: pid_t, frame: CGRect)] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  owner != ourPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  // Floor for the obviously-not-a-window: tooltips, drag images.
                  width > 200, height > 150
            else { continue }
            result.append((owner, CGRect(x: x, y: y, width: width, height: height)))
        }
        return result
    }

    /// How much of the biggest window's area something must cover to count as a
    /// main window rather than a dialog. Generous enough that two real windows of
    /// different sizes both qualify, tight enough to exclude an alert.
    private static let mainWindowAreaShare: CGFloat = 0.6

    /// CGWindowList reports top-left origin against the primary display; AppKit
    /// screen coordinates are bottom-left.
    private static func flipToAppKit(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX,
                      y: primaryHeight - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    private func targetPID() -> pid_t? {
        switch Prefs.dockMode {
        case .off:
            return nil
        case .activeWindow:
            return lastActivePID
        case .apps(let ids):
            // Prefer the whitelisted app you're actually in.
            if let front = NSWorkspace.shared.frontmostApplication,
               let id = front.bundleIdentifier, ids.contains(id) {
                lastWhitelistedPID = front.processIdentifier
                return front.processIdentifier
            }
            // Otherwise stay with the one we were following, if it's still alive.
            if let last = lastWhitelistedPID,
               NSRunningApplication(processIdentifier: last) != nil {
                return last
            }
            return ids
                .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
                .first?.processIdentifier
        }
    }

    /// Where we should sit, given the parent.
    private func dockedFrame(against parent: CGRect) -> CGRect {
        let size = panel.frame.size
        let screen = screenFor(parent)
        let visible = screen?.visibleFrame ?? parent

        let side = resolveSide(parent: parent, visible: visible, width: size.width)
        currentSide = side

        let x: CGFloat
        switch side {
        case .left:  x = parent.minX - gap - size.width
        case .right, .auto: x = parent.maxX + gap
        }

        // The offset is measured from the parent's top edge down to ours, so the
        // pairing holds when the parent resizes from the bottom.
        let y = parent.maxY - verticalOffset - size.height

        var frame = CGRect(x: x, y: y, width: size.width, height: size.height)

        // Never let it walk off screen entirely.
        frame.origin.x = min(max(frame.origin.x, visible.minX - size.width + 60), visible.maxX - 60)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - size.height)
        return frame
    }

    /// Auto picks the side with room, and keeps the side it has while that side
    /// still fits — otherwise it flips back and forth as the parent nears an edge.
    private func resolveSide(parent: CGRect, visible: CGRect, width: CGFloat) -> DockSide {
        switch Prefs.dockSide {
        case .left: return .left
        case .right: return .right
        case .auto: break
        }

        let fitsRight = parent.maxX + gap + width <= visible.maxX
        let fitsLeft = parent.minX - gap - width >= visible.minX

        if currentSide == .right, fitsRight { return .right }
        if currentSide == .left, fitsLeft { return .left }
        if fitsRight { return .right }
        if fitsLeft { return .left }
        // Neither fits; overlap on whichever side has more room.
        return (visible.maxX - parent.maxX) >= (parent.minX - visible.minX) ? .right : .left
    }

    private func screenFor(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }
    }

    // MARK: - User repositioning

    /// Drag it and it keeps what you chose: the vertical offset it ends up at,
    /// and which side of the parent you dropped it on.
    private func recordUserPosition(against parent: CGRect) {
        guard !isRepositioning else { return }
        let frame = panel.frame

        verticalOffset = parent.maxY - frame.maxY

        // Only a manual side setting is sticky; in auto we let the drag pick.
        if Prefs.dockSide == .auto {
            currentSide = frame.midX < parent.midX ? .left : .right
        }
    }

    /// Puts it back to the top of the parent.
    func resetPosition() {
        verticalOffset = Prefs.dockGap
        Prefs.dockVerticalOffset = Prefs.dockGap
        stillTicks = 0
        lastParentFrame = nil
        tick()
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
