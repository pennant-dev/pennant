import AppKit
import ApplicationServices
import CoreGraphics
import PennantCore
import Foundation

/// Working in an app without the owner's pointer or keyboard: the app's own window is looked at (even behind other
/// windows), and presses and typing go to that app alone, through its accessibility interface where it has one and as
/// events sent to its process where it doesn't. Nothing here moves the pointer or brings the app to the front.
enum BackgroundInput {
    /// Roles that take typing: a press on one puts the caret there.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]

    /// A press at a display point inside one app's window, by the most direct means it takes. Returns what happened,
    /// in words, for the model.
    static func press(pid: pid_t, at point: CGPoint, button: PointerButton, count: Int) throws -> String {
        guard AXIsProcessTrusted() else { throw DesktopError.permissionMissing("Accessibility") }
        let app = AXUIElementCreateApplication(pid)
        AccessibilityReader.enableWebAccessibilityIfNeeded(app: app, pid: pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var hit: AXUIElement?
        // Asked of the app itself, so it answers from its own windows, whatever covers them.
        if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var element = hit {
            for _ in 0 ..< 5 {
                let role = AccessibilityReader.string(element, kAXRoleAttribute)
                let actions = AccessibilityReader.actions(element)
                if button == .right, actions.contains("AXShowMenu") {
                    try perform(element, "AXShowMenu")
                    return "Opened the menu of \(describe(element))."
                }
                if button == .left, textRoles.contains(role) {
                    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    return "Put the caret in \(describe(element)); app_type types there."
                }
                if button == .left, actions.contains(kAXPressAction) {
                    for _ in 0 ..< max(1, count) { try perform(element, kAXPressAction) }
                    return "Pressed \(describe(element))."
                }
                guard let parent = AccessibilityReader.attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = unsafeDowncast(parent, to: AXUIElement.self)
            }
        }
        // Nothing there takes a press: a click sent to the app itself, at that spot.
        try postClick(pid: pid, at: point, button: button, count: count)
        return "Sent a \(button.rawValue) click to the app at that spot (nothing there takes a press directly). Check it landed with app_screenshot; some apps only take clicks while in front."
    }

    /// Types into the app's focused field: inserted at the caret where the field allows it, else keystrokes sent to
    /// the app alone.
    static func type(pid: pid_t, text: String) throws -> String {
        guard AXIsProcessTrusted() else { throw DesktopError.permissionMissing("Accessibility") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        if let focused = AccessibilityReader.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let field = unsafeDowncast(focused, to: AXUIElement.self)
            var settable = DarwinBoolean(false)
            if !text.contains("\n"), AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue,
               AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                return "Typed into \(describe(field))."
            }
        }
        for character in text {
            switch character {
            case "\n", "\r", "\r\n": try postKey(pid: pid, code: KeyCodes.returnKey, flags: [], unicode: nil)
            case "\t": try postKey(pid: pid, code: KeyCodes.tab, flags: [], unicode: nil)
            default: try postKey(pid: pid, code: 0, flags: [], unicode: Array(String(character).utf16))
            }
            usleep(6000)
        }
        return "Typed the text as keystrokes sent to the app."
    }

    /// A key or chord sent to the app alone ("return", "cmd+s").
    static func key(pid: pid_t, chord: KeyChord) throws {
        var flags: CGEventFlags = []
        if chord.command { flags.insert(.maskCommand) }
        if chord.shift { flags.insert(.maskShift) }
        if chord.option { flags.insert(.maskAlternate) }
        if chord.control { flags.insert(.maskControl) }
        let resolved = KeyCodes.resolve(chord.key.trimmingCharacters(in: .whitespaces))
        guard let code = resolved.code else { throw DesktopError.inputFailed("Unknown key '\(chord.key)'") }
        if resolved.shift { flags.insert(.maskShift) }
        try postKey(pid: pid, code: code, flags: flags, unicode: resolved.unicode)
    }

    /// Scroll wheel events sent to the app alone, at a display point inside its window.
    static func scroll(pid: pid_t, at point: CGPoint, deltaX: Double, deltaY: Double) throws {
        let steps = max(1, Int((max(abs(deltaX), abs(deltaY)) / 40).rounded(.up)))
        for _ in 0 ..< min(steps, 30) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(-deltaY / Double(steps)), wheel2: Int32(-deltaX / Double(steps)), wheel3: 0) else {
                throw DesktopError.inputFailed("Could not create a scroll event")
            }
            event.location = point
            mark(event)
            event.postToPid(pid)
            usleep(8000)
        }
    }

    // MARK: Events to one process

    private static func postClick(pid: pid_t, at point: CGPoint, button: PointerButton, count: Int) throws {
        let (down, up, cg): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
        for n in 1 ... max(1, min(3, count)) {
            guard let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: cg),
                  let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: cg) else {
                throw DesktopError.inputFailed("Could not create a click")
            }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            mark(d)
            mark(u)
            d.postToPid(pid)
            usleep(15000)
            u.postToPid(pid)
            usleep(30000)
        }
    }

    private static func postKey(pid: pid_t, code: CGKeyCode, flags: CGEventFlags, unicode: [UniChar]?) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw DesktopError.inputFailed("Could not create a key event")
        }
        if var units = unicode {
            units.withUnsafeMutableBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }
        down.flags = flags
        up.flags = flags
        mark(down)
        mark(up)
        down.postToPid(pid)
        usleep(12000)
        up.postToPid(pid)
    }

    /// Pennant's own events are marked, so the human-input monitor doesn't take them for the owner's.
    private static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: DesktopController.syntheticMarker)
    }

    private static func perform(_ element: AXUIElement, _ action: String) throws {
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success else { throw DesktopError.inputFailed("\(action) failed (\(error.rawValue))") }
    }

    /// "the “Save” button", for the model.
    static func describe(_ element: AXUIElement) -> String {
        let role = AccessibilityReader.string(element, kAXRoleDescriptionAttribute)
        let name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].lazy
            .map { AccessibilityReader.string(element, $0) }.first { !$0.isEmpty && $0.count < 80 } ?? ""
        let kind = role.isEmpty ? "element" : role
        return name.isEmpty ? "the \(kind)" : "the “\(name)” \(kind)"
    }
}
