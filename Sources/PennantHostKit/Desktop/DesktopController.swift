import AppKit
import CoreGraphics
import PennantCore
import Foundation

/// The macOS implementation of desktop control. One instance per host.
/// Coordinates are display points with the origin at the top-left of the main display.
public actor DesktopController: DesktopControlling {
    /// Placed in `eventSourceUserData` of every synthesized event so real input can be told apart.
    public static let syntheticMarker: Int64 = 0x0C0F_E000

    private let config: HostConfig.Desktop
    private let input: InputSynthesizer
    private let accessibility = AccessibilityReader()

    public init(config: HostConfig.Desktop) {
        self.config = config
        self.input = InputSynthesizer(actionDelayMilliseconds: config.actionDelayMilliseconds)
    }

    // MARK: Permissions

    public func permissions() async -> DesktopPermissions { PermissionCheck.current() }

    public func requestPermissions(targets: [String]) async -> DesktopPermissions {
        await PermissionCheck.request(targets)
    }

    // MARK: Screen

    public func captureScreen(maxWidth: Int) async throws -> CapturedScreen {
        let capture = try await ScreenCapturer.capture(maxWidth: maxWidth > 0 ? maxWidth : config.screenshotMaxWidth)
        return capture
    }

    public func displaySize() async -> (width: Int, height: Int) { ScreenCapturer.mainDisplaySizePoints() }


    nonisolated public func screenStream(options: ScreenStreamOptions) -> AsyncStream<CapturedScreen> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let session = ScreenStreamSession(options: options) { frame in
                continuation.yield(frame)
            } onEnd: {
                continuation.finish()
            }
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }

    // MARK: Input

    private func clamp(_ x: Double, _ y: Double) -> CGPoint {
        let size = ScreenCapturer.mainDisplaySizePoints()
        let cx = max(0, min(Double(max(1, size.width) - 1), x))
        let cy = max(0, min(Double(max(1, size.height) - 1), y))
        return CGPoint(x: cx, y: cy)
    }

    public func moveMouse(x: Double, y: Double) async throws {
        await showCursor(x: x, y: y, click: false)
        try await input.move(to: clamp(x, y))
    }
    public func livePointer(_ event: RemoteInput, x: Double, y: Double) async throws { try await input.live(event, at: clamp(x, y)) }

    public func click(x: Double, y: Double, button: PointerButton, count: Int) async throws {
        await showCursor(x: x, y: y, click: true)
        try await input.click(at: clamp(x, y), button: button, count: count)
    }


    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        await showCursor(x: fromX, y: fromY, click: true)
        try await input.drag(from: clamp(fromX, fromY), to: clamp(toX, toY))
        await showCursor(x: toX, y: toY, click: false)
    }

    public func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        await showCursor(x: x, y: y, click: false)
        try await input.scroll(at: clamp(x, y), deltaX: deltaX, deltaY: deltaY)
    }

    public func typeText(_ text: String) async throws { try await input.type(text) }
    public func pressKey(_ chord: KeyChord) async throws { try await input.press(chord) }

    public func interruptInput() async {
        input.interrupt()
        await MainActor.run { PennantCursor.shared.hide() }
    }

    // MARK: Background, one app

    public func captureWindow(app: String, title: String?, maxWidth: Int) async throws -> WindowCapture {
        let front = await AppControl.frontmost()?.pid
        guard let found = await MainActor.run(body: { AppControl.findRunning(app).map { AppControl.describe($0, frontmostPID: front) } }) else {
            throw DesktopError.appNotFound(app)
        }
        let shot = try await ScreenCapturer.captureWindow(pid: found.pid, title: title, maxWidth: maxWidth > 0 ? maxWidth : config.screenshotMaxWidth)
        return WindowCapture(jpeg: shot.jpeg, width: shot.width, height: shot.height, frame: shot.frame, title: shot.title, app: found)
    }

    public func pressInApp(pid: Int32, x: Double, y: Double, button: PointerButton, count: Int) async throws -> String {
        await showCursor(x: x, y: y, click: true)
        let said = try BackgroundInput.press(pid: pid, at: CGPoint(x: x, y: y), button: button, count: count)
        try? await Task.sleep(for: .milliseconds(config.actionDelayMilliseconds))
        return said
    }

    public func typeInApp(pid: Int32, text: String) async throws -> String {
        if let at = Self.focusedCenter(pid: pid) { await showCursor(x: at.x, y: at.y, click: false) }
        let said = try BackgroundInput.type(pid: pid, text: text)
        try? await Task.sleep(for: .milliseconds(config.actionDelayMilliseconds))
        return said
    }

    public func keyInApp(pid: Int32, chord: KeyChord) async throws {
        if let at = Self.focusedCenter(pid: pid) { await showCursor(x: at.x, y: at.y, click: false) }
        try BackgroundInput.key(pid: pid, chord: chord)
        try? await Task.sleep(for: .milliseconds(config.actionDelayMilliseconds))
    }

    public func scrollInApp(pid: Int32, x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        await showCursor(x: x, y: y, click: false)
        try BackgroundInput.scroll(pid: pid, at: CGPoint(x: x, y: y), deltaX: deltaX, deltaY: deltaY)
        try? await Task.sleep(for: .milliseconds(config.actionDelayMilliseconds))
    }

    /// Where an app's focused element is, for Pennant's cursor while it types.
    private static func focusedCenter(pid: Int32) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = AccessibilityReader.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return AccessibilityReader.center(unsafeDowncast(focused, to: AXUIElement.self))
    }

    public func showCursor(x: Double, y: Double, click: Bool) async {
        let point = clamp(x, y)
        await MainActor.run { PennantCursor.shared.show(at: point, click: click) }
    }

    // MARK: Applications

    public func runningApps() async -> [RunningApp] { await AppControl.runningApps(includeWindows: true) }
    public func frontmostApp() async -> RunningApp? { await AppControl.frontmost() }
    public func launchApp(nameOrBundleID: String) async throws -> RunningApp { try await AppControl.launch(nameOrBundleID) }
    public func activateApp(nameOrBundleID: String) async throws -> RunningApp { try await AppControl.activate(nameOrBundleID) }

    // MARK: Accessibility

    public func accessibilityTree(pid: Int32?, maxDepth: Int, maxNodes: Int) async throws -> [AXNode] {
        let target: pid_t
        if let pid {
            target = pid
        } else if let front = await AppControl.frontmost() {
            target = front.pid
        } else {
            throw DesktopError.appNotFound("frontmost application")
        }
        return try accessibility.tree(pid: target, maxDepth: maxDepth, maxNodes: maxNodes)
    }

    public func performAXAction(index: Int, action: String) async throws {
        guard AXIsProcessTrusted() else { throw DesktopError.permissionMissing("Accessibility") }
        if let center = accessibility.center(index: index) { await showCursor(x: center.x, y: center.y, click: true) }
        try accessibility.perform(index: index, action: action)
        try? await Task.sleep(for: .milliseconds(config.actionDelayMilliseconds))
    }

    public func setAXValue(index: Int, value: String) async throws {
        guard AXIsProcessTrusted() else { throw DesktopError.permissionMissing("Accessibility") }
        if let center = accessibility.center(index: index) { await showCursor(x: center.x, y: center.y, click: true) }
        try accessibility.setValue(index: index, value: value)
        try? await Task.sleep(for: .milliseconds(config.actionDelayMilliseconds))
    }

    // MARK: Scripting

    public func runAppleScript(_ source: String) async throws -> String {
        try await MainActor.run { try Scripting.runAppleScript(source) }
    }

    public func runJavaScriptForAutomation(_ source: String) async throws -> String {
        try await Scripting.runJXA(source)
    }
}
