import AppKit
import ApplicationServices
import CoreGraphics
import PennantCore
import Foundation

/// Records a demonstration: a listen-only event tap for clicks, keys and scrolling, and Accessibility to name
/// what each click landed on. It never records pixels, never blocks or changes events, skips the agent's own
/// synthetic input, skips Pennant's windows (the teaching panel), and never records password fields.
///
/// The tap callback only copies the few fields it needs and hands them to a serial queue, where the
/// Accessibility lookups and the merging (typing per field, scrolling per burst) happen.
final class TeachingRecorder: @unchecked Sendable {
    struct Recorded: Sendable {
        var at: Date
        var kind: TeachingEventKind
    }

    /// What the tap callback copies out of a `CGEvent` before handing it to the queue.
    private enum RawInput: Sendable {
        case mouseDown(point: CGPoint, button: String, clicks: Int)
        case key(code: Int, flags: UInt64, text: String, baseText: String)
        case scroll(dy: Double)
    }

    private let onEvent: @Sendable (Recorded) -> Void
    private let queue = DispatchQueue(label: "dev.pennant.teaching", qos: .userInitiated)
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var running = false
    private var timer: DispatchSourceTimer?

    // Queue-only state.
    private let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.3)
        return e
    }()
    private var lastAppPID: pid_t = 0
    private var lastWindow: [pid_t: String] = [:]
    /// Chromium apps whose web content has been asked to expose Accessibility during this recording.
    private var webEnabled: Set<pid_t> = []
    private var typing: (text: String, field: TeachingElement?, app: String, pid: pid_t, secure: Bool, lastAt: Date)?
    private var scrolling: (direction: String, app: String, lastAt: Date)?
    /// Diagnostics for the host log: raw inputs heard, skipped as Pennant's own, and steps emitted.
    private var heard = 0
    private var skippedPennant = 0
    private var emitted = 0

    init(onEvent: @escaping @Sendable (Recorded) -> Void) {
        self.onEvent = onEvent
    }

    /// Starts listening. Returns false when macOS refused the event tap (Accessibility or Input Monitoring
    /// is not granted to the host).
    func start() -> Bool {
        lock.lock()
        if running { lock.unlock(); return true }
        running = true
        lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let created = LockedFlag()
        let thread = Thread { [self] in runTap(ready: ready, created: created) }
        thread.name = "dev.pennant.teaching.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        guard created.value else {
            lock.withLock { running = false }
            return false
        }
        queue.async { [self] in noteFrontApp(at: Date()) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        lock.withLock { timer = t }
        return true
    }

    /// Stops listening and flushes merged typing and scrolling. Waits for the queue, so every step recorded
    /// before the call has been delivered when it returns.
    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let port = port, runLoop = runLoop, timer = timer
        self.port = nil
        self.runLoop = nil
        self.timer = nil
        lock.unlock()
        guard wasRunning else { return }
        timer?.cancel()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        queue.sync {
            flushAll()
            log.info("Teaching recorder heard \(heard) input(s), skipped \(skippedPennant) in Pennant, recorded \(emitted) step(s)", category: "teaching")
        }
    }

    // MARK: Tap

    private static let mask: CGEventMask = {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private func runTap(ready: DispatchSemaphore, created: LockedFlag) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<TeachingRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: Self.mask, callback: callback, userInfo: refcon) else {
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.withLock {
            self.port = port
            self.runLoop = loop
        }
        created.value = true
        ready.signal()
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        // The agent's own input carries this marker; a demonstration is the human's alone.
        if event.getIntegerValueField(.eventSourceUserData) == DesktopController.syntheticMarker { return }
        let at = Date()
        let raw: RawInput
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = type == .leftMouseDown ? "left" : (type == .rightMouseDown ? "right" : "other")
            raw = .mouseDown(point: event.location, button: button, clicks: Int(event.getIntegerValueField(.mouseEventClickState)))
        case .keyDown:
            // Held keys repeat; one press is one step.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let base = event.copy()
            base?.flags = []
            raw = .key(code: code, flags: event.flags.rawValue, text: Self.unicode(event), baseText: base.map(Self.unicode) ?? "")
        case .scrollWheel:
            let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            guard dy != 0 else { return }
            raw = .scroll(dy: dy)
        default:
            return
        }
        queue.async { [self] in process(raw, at: at) }
    }

    private static func unicode(_ event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: Processing (queue)

    private func process(_ raw: RawInput, at: Date) {
        heard += 1
        switch raw {
        case .mouseDown(let point, let button, let clicks):
            flushAll()
            recordClick(at: point, button: button, clicks: max(1, clicks), time: at)
        case .key(let code, let flags, let text, let baseText):
            recordKey(code: code, flags: CGEventFlags(rawValue: flags), text: text, baseText: baseText, time: at)
        case .scroll(let dy):
            guard let app = frontApp(), !app.isPennant else { return }
            flushTyping()
            let direction = dy > 0 ? "up" : "down"
            if let s = scrolling, s.direction == direction, s.app == app.name {
                scrolling?.lastAt = at
            } else {
                flushScroll()
                noteApp(pid: app.pid, name: app.name, bundleID: app.bundleID, at: at)
                scrolling = (direction, app.name, at)
            }
        }
    }

    private func tick() {
        let now = Date()
        if let t = typing, now.timeIntervalSince(t.lastAt) > 2.5 { flushTyping() }
        if let s = scrolling, now.timeIntervalSince(s.lastAt) > 1.2 { flushScroll() }
        if typing == nil { noteFrontApp(at: now) }
    }

    private func emit(_ kind: TeachingEventKind, at: Date = Date()) {
        emitted += 1
        onEvent(Recorded(at: at, kind: kind))
    }

    private func flushAll() {
        flushTyping()
        flushScroll()
    }

    private func flushTyping() {
        guard let t = typing else { return }
        typing = nil
        if t.secure {
            emit(.secureTyped(app: t.app), at: t.lastAt)
        } else if !t.text.isEmpty {
            emit(.typed(text: t.text, field: t.field, app: t.app), at: t.lastAt)
        }
    }

    private func flushScroll() {
        guard let s = scrolling else { return }
        scrolling = nil
        emit(.scroll(direction: s.direction, app: s.app), at: s.lastAt)
    }

    // MARK: Apps and windows

    private struct AppInfo {
        var pid: pid_t
        var name: String
        var bundleID: String?
        var isPennant: Bool { bundleID?.hasPrefix("dev.pennant") == true }
    }

    private func appInfo(pid: pid_t) -> AppInfo? {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return AppInfo(pid: pid, name: app.localizedName ?? app.bundleIdentifier ?? "an app", bundleID: app.bundleIdentifier)
    }

    /// The app with keyboard focus, from Accessibility. `NSWorkspace.frontmostApplication` is only refreshed by
    /// the main run loop's notifications, which a background host may not process, so it goes stale.
    private func frontApp() -> AppInfo? {
        if let focused = AccessibilityReader.attribute(systemWide, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(unsafeDowncast(focused, to: AXUIElement.self), &pid) == .success, let info = appInfo(pid: pid) {
                return info
            }
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppInfo(pid: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "an app", bundleID: app.bundleIdentifier)
    }

    private func noteFrontApp(at: Date) {
        guard let app = frontApp(), !app.isPennant else { return }
        noteApp(pid: app.pid, name: app.name, bundleID: app.bundleID, at: at)
    }

    /// System UI that is clicked through rather than switched to: its clicks are steps, its "activation" is not.
    private static let passThroughApps: Set<String> = ["com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager"]

    /// Records a switch to `pid` and a change of its focused window, when either changed. Returns true when
    /// it just asked a Chromium app to build its web Accessibility tree (a click there is worth re-reading).
    @discardableResult
    private func noteApp(pid: pid_t, name: String, bundleID: String?, at: Date) -> Bool {
        if let bundleID, Self.passThroughApps.contains(bundleID) { return false }
        var enabledWeb = false
        if !webEnabled.contains(pid), let bundleID, AccessibilityReader.chromiumBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            webEnabled.insert(pid)
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            AccessibilityReader.enableWebAccessibilityIfNeeded(app: appElement, pid: pid)
            enabledWeb = true
        }
        if pid != lastAppPID {
            flushAll()
            lastAppPID = pid
            emit(.appActivated(app: name, bundleID: bundleID), at: at)
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        if let window = AccessibilityReader.attribute(appElement, kAXFocusedWindowAttribute) {
            let title = AccessibilityReader.string(unsafeDowncast(window, to: AXUIElement.self), kAXTitleAttribute)
            if !title.isEmpty, lastWindow[pid] != title {
                lastWindow[pid] = title
                emit(.window(app: name, title: title), at: at)
            }
        }
        return enabledWeb
    }

    // MARK: Clicks

    private func recordClick(at point: CGPoint, button: String, clicks: Int, time: Date) {
        var hit: AXUIElement?
        var found = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success
        var pid: pid_t = 0
        if found, let hit { AXUIElementGetPid(hit, &pid) }
        let app = appInfo(pid: pid) ?? frontApp()
        guard let app, !app.isPennant else { skippedPennant += 1; return }
        if noteApp(pid: app.pid, name: app.name, bundleID: app.bundleID, at: time) {
            // The page's controls exist now; read the click again so it gets a name.
            var again: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &again) == .success, let again {
                hit = again
                found = true
            }
        }
        var element: TeachingElement?
        var windowTitle: String?
        var fx: Double?
        var fy: Double?
        if found, let hit {
            let target = Self.meaningful(hit)
            element = Self.describe(target)
            if let win = AccessibilityReader.attribute(hit, kAXWindowAttribute) {
                let w = unsafeDowncast(win, to: AXUIElement.self)
                let title = AccessibilityReader.string(w, kAXTitleAttribute)
                windowTitle = title.isEmpty ? nil : title
                if let origin = AccessibilityReader.point(w, kAXPositionAttribute), let size = AccessibilityReader.size(w, kAXSizeAttribute), size.width > 0, size.height > 0 {
                    fx = min(1, max(0, (point.x - origin.x) / size.width))
                    fy = min(1, max(0, (point.y - origin.y) / size.height))
                }
            }
        }
        emit(.click(button: button, count: clicks, element: element, app: app.name, window: windowTitle, x: fx, y: fy), at: time)
    }

    /// Roles a click usually lands inside of, and roles worth naming instead.
    private static let wrapperRoles: Set<String> = ["AXImage", "AXStaticText", "AXGroup", "AXUnknown", "AXLayoutItem"]
    private static let actionableRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXCell", "AXRow", "AXTab", "AXDisclosureTriangle", "AXComboBox", "AXTextField", "AXSearchField", "AXSlider"]

    /// The clicked element, or the button or link it sits inside (a click on a button's icon names the button).
    private static func meaningful(_ element: AXUIElement) -> AXUIElement {
        let role = AccessibilityReader.string(element, kAXRoleAttribute)
        guard wrapperRoles.contains(role) else { return element }
        var current = element
        for _ in 0 ..< 3 {
            guard let parent = AccessibilityReader.attribute(current, kAXParentAttribute) else { break }
            let p = unsafeDowncast(parent, to: AXUIElement.self)
            if actionableRoles.contains(AccessibilityReader.string(p, kAXRoleAttribute)) { return p }
            current = p
        }
        return element
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func describe(_ element: AXUIElement) -> TeachingElement {
        let role = AccessibilityReader.string(element, kAXRoleAttribute)
        let roleDescription = AccessibilityReader.string(element, kAXRoleDescriptionAttribute)
        var label = ""
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            let v = AccessibilityReader.string(element, attribute).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { label = v; break }
        }
        if label.isEmpty, role == "AXStaticText" {
            label = AccessibilityReader.string(element, kAXValueAttribute)
        }
        if label.isEmpty, let titleElement = AccessibilityReader.attribute(element, kAXTitleUIElementAttribute) {
            let t = unsafeDowncast(titleElement, to: AXUIElement.self)
            label = AccessibilityReader.string(t, kAXValueAttribute)
            if label.isEmpty { label = AccessibilityReader.string(t, kAXTitleAttribute) }
        }
        let identifier = AccessibilityReader.string(element, "AXIdentifier")
        var value: String?
        if !textRoles.contains(role), ["AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXMenuButton"].contains(role) {
            let v = AccessibilityReader.string(element, kAXValueAttribute)
            if !v.isEmpty { value = String(v.prefix(40)) }
        }
        return TeachingElement(
            role: role,
            roleDescription: roleDescription,
            label: String(label.replacingOccurrences(of: "\n", with: " ").prefix(80)),
            identifier: identifier.isEmpty ? nil : String(identifier.prefix(80)),
            value: value
        )
    }

    // MARK: Keys

    private static let namedKeys: [Int: String] = [
        36: "Return", 76: "Enter", 48: "Tab", 53: "Escape", 51: "Delete", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        49: "Space",
    ]

    private func recordKey(code: Int, flags: CGEventFlags, text: String, baseText: String, time: Date) {
        // Keys go to the focused element's app, which may be Pennant's own panel even while another app is in front.
        var focused: AXUIElement?
        var pid: pid_t = 0
        if let f = AccessibilityReader.attribute(systemWide, kAXFocusedUIElementAttribute) {
            focused = unsafeDowncast(f, to: AXUIElement.self)
            AXUIElementGetPid(focused!, &pid)
        }
        guard let app = appInfo(pid: pid) ?? frontApp(), !app.isPennant else { skippedPennant += 1; return }
        let command = flags.contains(.maskCommand), control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)
        let named = Self.namedKeys[code]

        if command || control {
            flushAll()
            noteApp(pid: app.pid, name: app.name, bundleID: app.bundleID, at: time)
            var keys = ""
            if control { keys += "⌃" }
            if option { keys += "⌥" }
            if shift { keys += "⇧" }
            if command { keys += "⌘" }
            keys += named ?? baseText.uppercased()
            emit(.shortcut(keys: keys, app: app.name), at: time)
            return
        }

        // Delete while typing edits the pending text instead of becoming a step.
        if code == 51, var t = typing, t.pid == app.pid, !t.secure, !t.text.isEmpty {
            t.text.removeLast()
            t.lastAt = time
            typing = t
            return
        }

        if let named, code != 49 {
            flushAll()
            noteApp(pid: app.pid, name: app.name, bundleID: app.bundleID, at: time)
            emit(.key(name: (shift ? "⇧" : "") + (option ? "⌥" : "") + named, app: app.name), at: time)
            return
        }

        let typed = code == 49 ? " " : text
        guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        flushScroll()
        if var t = typing, t.pid == app.pid {
            if !t.secure { t.text += typed }
            t.lastAt = time
            typing = t
            return
        }
        flushTyping()
        noteApp(pid: app.pid, name: app.name, bundleID: app.bundleID, at: time)
        let field = focused.map(Self.describe)
        let secure = focused.map { AccessibilityReader.string($0, kAXSubroleAttribute) == "AXSecureTextField" } ?? false
        typing = (secure ? "" : typed, field, app.name, app.pid, secure, time)
    }
}

/// A flag written on the tap thread and read by the caller waiting for it.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
