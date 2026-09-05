import AppKit
import Carbon.HIToolbox

/// A key plus its modifiers, stored as Carbon values so the global hotkey and the
/// in-window shortcuts speak the same language.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String { KeyName.describe(keyCode: keyCode, modifiers: modifiers) }

    /// Matches against a key event. Compares the physical key rather than the
    /// character it produces, so a binding survives a layout change and works for
    /// keys like `[` that shift into something else.
    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode
            && KeyName.carbonModifiers(from: event.modifierFlags) == modifiers
    }

    static func encode(_ shortcut: Shortcut) -> String { "\(shortcut.keyCode):\(shortcut.modifiers)" }

    static func decode(_ raw: String) -> Shortcut? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let key = UInt32(parts[0]),
              let mods = UInt32(parts[1]) else { return nil }
        return Shortcut(keyCode: key, modifiers: mods)
    }
}

/// Everything that can be rebound. Adding a case here is all it takes to put a
/// new action in the menu — the recorder, storage and matching are generic.
enum ShortcutAction: String, CaseIterable {
    case toggleWindow
    case swapFocus
    case hide
    case newTab
    case newTabAnywhere
    case closeTab
    case openPage
    case copyLink
    case reload
    case hardReload
    case back
    case forward
    case zoomIn
    case zoomOut
    case zoomReset
    case togglePin
    case toggleDock
    case opacityUp
    case opacityDown
    case nextTab
    case previousTab

    var label: String {
        switch self {
        case .toggleWindow: return "Show / Hide"
        case .swapFocus: return "Swap Focus"
        case .hide: return "Hide"
        case .newTab: return "New Tab"
        case .newTabAnywhere: return "Open in New Tab…"
        case .closeTab: return "Close Tab"
        case .openPage: return "Open in This Tab"
        case .copyLink: return "Copy Page Link"
        case .reload: return "Reload"
        case .hardReload: return "Hard Reload"
        case .back: return "Back"
        case .forward: return "Forward"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomReset: return "Actual Size"
        case .togglePin: return "Always on Top"
        case .toggleDock: return "Dock to Window"
        case .opacityUp: return "More Opaque"
        case .opacityDown: return "More Transparent"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        }
    }

    /// These have to work while another app is frontmost, so they're the ones
    /// registered with Carbon rather than resolved inside the window.
    var isGlobal: Bool { self == .toggleWindow || self == .swapFocus }

    /// Only registered while it can actually do something. A Carbon hotkey
    /// swallows its key system-wide, so a binding that's inert most of the time
    /// would still eat the key in every other app.
    var isContextual: Bool { self == .swapFocus }

    var defaultShortcut: Shortcut {
        let cmd = UInt32(cmdKey)
        let shift = UInt32(shiftKey)
        let option = UInt32(optionKey)
        let control = UInt32(controlKey)
        switch self {
        case .toggleWindow:  return Shortcut(keyCode: UInt32(kVK_Space), modifiers: control)
        case .swapFocus:     return Shortcut(keyCode: UInt32(kVK_Tab), modifiers: option)
        case .hide:          return Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: cmd)
        case .newTab:        return Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: cmd)
        case .newTabAnywhere: return Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: cmd | shift)
        case .closeTab:      return Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: cmd)
        case .openPage:      return Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: cmd)
        case .copyLink:      return Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: cmd | shift)
        case .reload:        return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: cmd)
        case .hardReload:    return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: cmd | shift)
        case .back:          return Shortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: cmd)
        case .forward:       return Shortcut(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: cmd)
        case .zoomIn:        return Shortcut(keyCode: UInt32(kVK_ANSI_Equal), modifiers: cmd)
        case .zoomOut:       return Shortcut(keyCode: UInt32(kVK_ANSI_Minus), modifiers: cmd)
        case .zoomReset:     return Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: cmd)
        case .togglePin:     return Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: cmd | option)
        case .toggleDock:    return Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: cmd | option)
        case .opacityUp:     return Shortcut(keyCode: UInt32(kVK_UpArrow), modifiers: cmd | option)
        case .opacityDown:   return Shortcut(keyCode: UInt32(kVK_DownArrow), modifiers: cmd | option)
        case .nextTab:       return Shortcut(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: cmd | shift)
        case .previousTab:   return Shortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: cmd | shift)
        }
    }
}

/// Reads and writes the bindings. Only overrides are stored, so a default that
/// changes in a later version reaches anyone who never touched that action.
enum Shortcuts {
    private static let d = UserDefaults.standard
    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }

    static subscript(action: ShortcutAction) -> Shortcut {
        get {
            guard let raw = d.string(forKey: key(action)),
                  let stored = Shortcut.decode(raw) else { return action.defaultShortcut }
            return stored
        }
        set {
            if newValue == action.defaultShortcut {
                d.removeObject(forKey: key(action))
            } else {
                d.set(Shortcut.encode(newValue), forKey: key(action))
            }
        }
    }

    static func isCustomised(_ action: ShortcutAction) -> Bool {
        d.string(forKey: key(action)) != nil
    }

    static func reset(_ action: ShortcutAction) {
        d.removeObject(forKey: key(action))
    }

    static func resetAll() {
        ShortcutAction.allCases.forEach(reset)
    }

    /// The action bound to this event, if any. Nil when nothing matches.
    static func action(for event: NSEvent) -> ShortcutAction? {
        ShortcutAction.allCases.first { !$0.isGlobal && self[$0].matches(event) }
    }

    /// Whichever action already owns this combination, so the recorder can say so
    /// instead of silently creating a binding that never fires.
    static func conflict(for shortcut: Shortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self[$0] == shortcut }
    }
}
