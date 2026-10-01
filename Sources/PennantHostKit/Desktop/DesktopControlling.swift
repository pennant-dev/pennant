import PennantCore
import Foundation

/// A captured screen image plus the geometry needed to map model coordinates back to the display.
public struct CapturedScreen: Sendable {
    public var jpeg: Data
    public var width: Int
    public var height: Int
    /// Full display size in points; captured images may be scaled down.
    public var displayWidth: Int
    public var displayHeight: Int
    public var capturedAt: Date
    public var cursorX: Double?
    public var cursorY: Double?

    public init(jpeg: Data, width: Int, height: Int, displayWidth: Int, displayHeight: Int, capturedAt: Date = Date(), cursorX: Double? = nil, cursorY: Double? = nil) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.capturedAt = capturedAt
        self.cursorX = cursorX
        self.cursorY = cursorY
    }

}

public struct RunningApp: Hashable, Codable, Sendable {
    public var name: String
    public var bundleID: String?
    public var pid: Int32
    public var isFrontmost: Bool
    public var windowTitles: [String]

    public init(name: String, bundleID: String?, pid: Int32, isFrontmost: Bool, windowTitles: [String] = []) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.isFrontmost = isFrontmost
        self.windowTitles = windowTitles
    }
}

/// A node of the accessibility tree, flattened for the model with a stable index for targeting.
public struct AXNode: Hashable, Codable, Sendable {
    public var index: Int
    public var role: String
    public var title: String
    public var value: String
    public var description: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var enabled: Bool
    public var focused: Bool
    public var depth: Int
    public var actions: [String]

    public init(index: Int, role: String, title: String, value: String, description: String, x: Double, y: Double, width: Double, height: Double, enabled: Bool, focused: Bool, depth: Int, actions: [String]) {
        self.index = index
        self.role = role
        self.title = title
        self.value = value
        self.description = description
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.enabled = enabled
        self.focused = focused
        self.depth = depth
        self.actions = actions
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

public enum DesktopError: Error, Sendable, CustomStringConvertible {
    case permissionMissing(String)
    case captureFailed(String)
    case appNotFound(String)
    case scriptFailed(String)
    case inputFailed(String)
    case leaseRevoked

    public var description: String {
        switch self {
        case .permissionMissing(let p): return "Missing macOS permission: \(p). Grant it in System Settings > Privacy & Security."
        case .captureFailed(let s): return "Screen capture failed: \(s)"
        case .appNotFound(let s): return "Application not found: \(s)"
        case .scriptFailed(let s): return "Script failed: \(s)"
        case .inputFailed(let s): return "Input failed: \(s)"
        case .leaseRevoked: return "Desktop lease revoked"
        }
    }
}

/// Everything the host can do to the desktop. Implemented by `DesktopController` on macOS
/// and by a fake in tests. Coordinates are display points with origin at the top-left.
public protocol DesktopControlling: Sendable {
    func permissions() async -> DesktopPermissions
    /// Shows the system permission dialogs for the listed targets (empty = all) and returns the state afterwards.
    func requestPermissions(targets: [String]) async -> DesktopPermissions

    func captureScreen(maxWidth: Int) async throws -> CapturedScreen
    func displaySize() async -> (width: Int, height: Int)

    func moveMouse(x: Double, y: Double) async throws
    func click(x: Double, y: Double, button: PointerButton, count: Int) async throws
    func mouseDown(x: Double, y: Double, button: PointerButton) async throws
    func mouseUp(x: Double, y: Double, button: PointerButton) async throws
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws
    func typeText(_ text: String) async throws
    func pressKey(_ chord: KeyChord) async throws

    func runningApps() async -> [RunningApp]
    func frontmostApp() async -> RunningApp?
    func launchApp(nameOrBundleID: String) async throws -> RunningApp
    func activateApp(nameOrBundleID: String) async throws -> RunningApp

    /// Flattened accessibility tree of an app (frontmost when nil), limited by depth and node count.
    func accessibilityTree(pid: Int32?, maxDepth: Int, maxNodes: Int) async throws -> [AXNode]
    /// Perform an AX action (e.g. AXPress) on the node at `index` from the most recent tree read.
    func performAXAction(index: Int, action: String) async throws
    func setAXValue(index: Int, value: String) async throws

    func runAppleScript(_ source: String) async throws -> String
    func runJavaScriptForAutomation(_ source: String) async throws -> String

    /// Starts an SCStream producing JPEG frames at the requested rate. The stream ends when cancelled.
    func screenStream(options: ScreenStreamOptions) -> AsyncStream<CapturedScreen>

    /// Called by the lease when a human takes over; must stop synthesizing input immediately.
    func interruptInput() async
}

/// Timestamp of the last human-originated input event, for pause-on-human-input.
public protocol HumanInputObserving: Sendable {
    func lastHumanInputAt() async -> Date?
    func start() async
    func stop() async
}
