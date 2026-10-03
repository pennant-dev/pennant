import ApplicationServices
import CoreGraphics
import PennantCore
import Foundation

/// Synthesizes mouse and keyboard input with CGEvent. Every event is tagged with
/// `DesktopController.syntheticMarker` so the human-input monitor can tell it apart from real input.
final class InputSynthesizer: @unchecked Sendable {
    private let source: CGEventSource?
    private let actionDelayMilliseconds: Int
    private let lock = NSLock()
    private var interrupted = false
    /// The button the owner's live pointer is holding down, so its moves are posted as drags.
    private var heldButton: PointerButton?

    init(actionDelayMilliseconds: Int) {
        self.actionDelayMilliseconds = max(0, actionDelayMilliseconds)
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = DesktopController.syntheticMarker
        self.source = source
    }

    /// Abort any in-progress multi-step action (typing, dragging) as soon as it next checks.
    func interrupt() {
        lock.withLock { interrupted = true }
    }

    private func beginAction() throws {
        guard AXIsProcessTrusted() else { throw DesktopError.permissionMissing("Accessibility") }
        lock.withLock { interrupted = false }
    }

    private var isInterrupted: Bool { lock.withLock { interrupted } }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: DesktopController.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    private func pause(_ milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func settle() async { await pause(actionDelayMilliseconds) }

    // MARK: Mouse

    private func buttonTypes(_ button: PointerButton) -> (down: CGEventType, up: CGEventType, dragged: CGEventType, button: CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        }
    }

    private func mouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw DesktopError.inputFailed("Could not create mouse event")
        }
        return event
    }

    func move(to point: CGPoint) async throws {
        try beginAction()
        post(try mouseEvent(.mouseMoved, at: point))
        await settle()
    }

    /// The owner's pointer from another device, posted as it comes: no settling pause (that's for the agent's
    /// actions, and at sixty moves a second it left the pointer seconds behind the finger), and moves while a
    /// button is held go out as drags, so apps see one.
    func live(_ event: RemoteInput, at point: CGPoint) async throws {
        switch event {
        case .pointerMove:
            try beginAction()
            if let held = lock.withLock({ heldButton }) {
                let types = buttonTypes(held)
                post(try mouseEvent(types.dragged, at: point, button: types.button))
            } else {
                post(try mouseEvent(.mouseMoved, at: point))
            }
        case .pointerDown(_, _, let button):
            try beginAction()
            let types = buttonTypes(button)
            post(try mouseEvent(.mouseMoved, at: point))
            let down = try mouseEvent(types.down, at: point, button: types.button)
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            post(down)
            lock.withLock { heldButton = button }
        case .pointerUp(_, _, let button):
            try beginAction()
            let types = buttonTypes(button)
            let up = try mouseEvent(types.up, at: point, button: types.button)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            post(up)
            lock.withLock { heldButton = nil }
        case .click(_, _, let button, let count):
            try await click(at: point, button: button, count: count, settling: false)
        case .scroll, .typeText, .key:
            break
        }
    }

    func click(at point: CGPoint, button: PointerButton, count: Int, settling: Bool = true) async throws {
        try beginAction()
        let types = buttonTypes(button)
        post(try mouseEvent(.mouseMoved, at: point))
        await pause(40)
        let clicks = max(1, min(3, count))
        for i in 1 ... clicks {
            let down = try mouseEvent(types.down, at: point, button: types.button)
            let up = try mouseEvent(types.up, at: point, button: types.button)
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            post(down)
            await pause(25)
            post(up)
            if i < clicks { await pause(70) }
        }
        if settling { await settle() }
    }

    func drag(from start: CGPoint, to end: CGPoint) async throws {
        try beginAction()
        post(try mouseEvent(.mouseMoved, at: start))
        await pause(50)
        let down = try mouseEvent(.leftMouseDown, at: start)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        post(down)
        await pause(80)
        let steps = 16
        var current = start
        for i in 1 ... steps {
            if isInterrupted {
                post(try mouseEvent(.leftMouseUp, at: current))
                throw DesktopError.inputFailed("Drag interrupted")
            }
            let t = Double(i) / Double(steps)
            current = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(try mouseEvent(.leftMouseDragged, at: current))
            await pause(16)
        }
        await pause(80)
        post(try mouseEvent(.leftMouseUp, at: end))
        await settle()
    }

    /// Positive `deltaY` scrolls down (reveals content below); positive `deltaX` scrolls right.
    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) async throws {
        try beginAction()
        post(try mouseEvent(.mouseMoved, at: point))
        await pause(30)
        var remainingY = deltaY
        var remainingX = deltaX
        let step = 120.0
        while abs(remainingY) > 0.5 || abs(remainingX) > 0.5 {
            if isInterrupted { throw DesktopError.inputFailed("Scroll interrupted") }
            let stepY = max(-step, min(step, remainingY))
            let stepX = max(-step, min(step, remainingX))
            remainingY -= stepY
            remainingX -= stepX
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(-stepY.rounded()), wheel2: Int32(-stepX.rounded()), wheel3: 0) else {
                throw DesktopError.inputFailed("Could not create scroll event")
            }
            event.location = point
            post(event)
            await pause(12)
        }
        await settle()
    }

    // MARK: Keyboard

    private func keyEvent(code: CGKeyCode, down: Bool) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw DesktopError.inputFailed("Could not create keyboard event")
        }
        return event
    }

    private func tap(code: CGKeyCode, flags: CGEventFlags = []) async throws {
        let down = try keyEvent(code: code, down: true)
        let up = try keyEvent(code: code, down: false)
        down.flags = flags
        up.flags = flags
        post(down)
        await pause(12)
        post(up)
    }

    func type(_ text: String) async throws {
        try beginAction()
        for character in text {
            if isInterrupted { throw DesktopError.inputFailed("Typing interrupted") }
            switch character {
            case "\n", "\r", "\r\n":
                try await tap(code: KeyCodes.returnKey)
            case "\t":
                try await tap(code: KeyCodes.tab)
            default:
                var units = Array(String(character).utf16)
                let down = try keyEvent(code: 0, down: true)
                let up = try keyEvent(code: 0, down: false)
                units.withUnsafeMutableBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                post(down)
                post(up)
            }
            await pause(6)
        }
        await settle()
    }

    func press(_ chord: KeyChord) async throws {
        try beginAction()
        var flags: CGEventFlags = []
        if chord.command { flags.insert(.maskCommand) }
        if chord.shift { flags.insert(.maskShift) }
        if chord.option { flags.insert(.maskAlternate) }
        if chord.control { flags.insert(.maskControl) }

        let key = chord.key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw DesktopError.inputFailed("Empty key") }
        let resolved = KeyCodes.resolve(key)
        guard let code = resolved.code else { throw DesktopError.inputFailed("Unknown key '\(chord.key)'") }
        if resolved.shift { flags.insert(.maskShift) }

        let down = try keyEvent(code: code, down: true)
        let up = try keyEvent(code: code, down: false)
        if var units = resolved.unicode {
            units.withUnsafeMutableBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }
        down.flags = flags
        up.flags = flags
        post(down)
        await pause(20)
        post(up)
        await settle()
    }
}

/// US-ANSI virtual key codes and key-name resolution.
enum KeyCodes {
    static let returnKey: CGKeyCode = 36
    static let tab: CGKeyCode = 48

    static let named: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, " ": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "command": 55, "cmd": 55, "shift": 56, "capslock": 57, "option": 58, "alt": 58, "control": 59, "ctrl": 59, "fn": 63,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113, "help": 114, "insert": 114, "home": 115,
        "pageup": 116, "pgup": 116, "forwarddelete": 117, "fwddelete": 117, "del": 117, "f4": 118, "end": 119, "f2": 120,
        "pagedown": 121, "pgdn": 121, "f1": 122, "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124,
        "down": 125, "arrowdown": 125, "up": 126, "arrowup": 126,
    ]

    /// Characters that need Shift on a US layout, mapped to the unshifted key.
    static let shifted: [Character: CGKeyCode] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28, "(": 25, ")": 29, "_": 27, "+": 24,
        "{": 33, "}": 30, "|": 42, ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44, "~": 50,
    ]

    struct Resolved {
        var code: CGKeyCode?
        var shift: Bool
        var unicode: [UniChar]?
    }

    static func resolve(_ key: String) -> Resolved {
        if key.count == 1, let character = key.first {
            if character.isUppercase, let code = named[String(character).lowercased()] {
                return Resolved(code: code, shift: true, unicode: nil)
            }
            if let code = named[String(character)] { return Resolved(code: code, shift: false, unicode: nil) }
            if let code = shifted[character] { return Resolved(code: code, shift: true, unicode: nil) }
            // Unknown printable character: send it as a Unicode string on a neutral key code.
            return Resolved(code: 0, shift: false, unicode: Array(String(character).utf16))
        }
        if let code = named[key.lowercased()] { return Resolved(code: code, shift: false, unicode: nil) }
        return Resolved(code: nil, shift: false, unicode: nil)
    }
}
