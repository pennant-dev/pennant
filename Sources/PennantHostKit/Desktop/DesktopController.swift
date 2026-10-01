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

    public func moveMouse(x: Double, y: Double) async throws { try await input.move(to: clamp(x, y)) }

    public func click(x: Double, y: Double, button: PointerButton, count: Int) async throws {
        try await input.click(at: clamp(x, y), button: button, count: count)
    }

    public func mouseDown(x: Double, y: Double, button: PointerButton) async throws { try await input.mouseDown(at: clamp(x, y), button: button) }
    public func mouseUp(x: Double, y: Double, button: PointerButton) async throws { try await input.mouseUp(at: clamp(x, y), button: button) }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        try await input.drag(from: clamp(fromX, fromY), to: clamp(toX, toY))
    }

    public func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        try await input.scroll(at: clamp(x, y), deltaX: deltaX, deltaY: deltaY)
    }

    public func typeText(_ text: String) async throws { try await input.type(text) }
    public func pressKey(_ chord: KeyChord) async throws { try await input.press(chord) }

    public func interruptInput() async { input.interrupt() }

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
        try accessibility.perform(index: index, action: action)
        try? await Task.sleep(for: .milliseconds(config.actionDelayMilliseconds))
    }

    public func setAXValue(index: Int, value: String) async throws {
        guard AXIsProcessTrusted() else { throw DesktopError.permissionMissing("Accessibility") }
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
