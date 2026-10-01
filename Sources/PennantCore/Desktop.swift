import Foundation

/// Who currently holds the foreground desktop.
public enum DesktopOwner: Hashable, Codable, Sendable {
    case nobody
    case agent(AgentID, TaskID)
    case human
}

public enum PermissionState: String, Codable, Sendable {
    case granted, denied, notDetermined, unknown
}

public struct DesktopPermissions: Hashable, Codable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    /// Legacy summary flag: true when Automation of System Events is granted (or cannot be determined).
    public var automation: Bool
    public var inputMonitoring: Bool
    /// Automation consent per target bundle identifier (System Events, Safari, Finder, browsers).
    public var automationTargets: [String: PermissionState]
    /// Name of the process macOS attributes grants to (the app, or pennant-host when run by launchd).
    public var grantee: String

    public init(accessibility: Bool = false, screenRecording: Bool = false, automation: Bool = false, inputMonitoring: Bool = false, automationTargets: [String: PermissionState] = [:], grantee: String = "") {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.automation = automation
        self.inputMonitoring = inputMonitoring
        self.automationTargets = automationTargets
        self.grantee = grantee
    }

    /// Everything the desktop tools need for full computer use. Automation consent is per app and macOS
    /// asks on first use, so targets that were never asked do not count as missing; denied ones do.
    public var allGranted: Bool { accessibility && screenRecording && !automationTargets.values.contains(.denied) }
    public var missing: [String] {
        var out: [String] = []
        if !accessibility { out.append("Accessibility") }
        if !screenRecording { out.append("Screen Recording") }
        if !inputMonitoring { out.append("Input Monitoring (optional)") }
        for (target, state) in automationTargets.sorted(by: { $0.key < $1.key }) where state == .denied { out.append("Automation denied: \(target)") }
        return out
    }
    /// Automation targets macOS has not asked about yet; they prompt on first use or via Request.
    public var automationNotAsked: [String] { automationTargets.filter { $0.value == .notDetermined }.keys.sorted() }

    private enum CodingKeys: String, CodingKey { case accessibility, screenRecording, automation, inputMonitoring, automationTargets, grantee }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessibility = try c.decodeIfPresent(Bool.self, forKey: .accessibility) ?? false
        screenRecording = try c.decodeIfPresent(Bool.self, forKey: .screenRecording) ?? false
        automation = try c.decodeIfPresent(Bool.self, forKey: .automation) ?? false
        inputMonitoring = try c.decodeIfPresent(Bool.self, forKey: .inputMonitoring) ?? false
        automationTargets = try c.decodeIfPresent([String: PermissionState].self, forKey: .automationTargets) ?? [:]
        grantee = try c.decodeIfPresent(String.self, forKey: .grantee) ?? ""
    }
}

public struct DesktopStatus: Hashable, Codable, Sendable {
    public var owner: DesktopOwner
    /// Tasks waiting in line for the desktop.
    public var queue: [TaskID]
    /// True when a human paused agent desktop actions.
    public var pausedByHuman: Bool
    /// Pause automatically when the human touches the mouse or keyboard.
    public var pauseOnHumanInput: Bool
    public var permissions: DesktopPermissions
    public var frontmostApp: String?
    public var displayWidth: Int
    public var displayHeight: Int
    public var streamingClients: Int
    public var updatedAt: Date

    public init(owner: DesktopOwner = .nobody, queue: [TaskID] = [], pausedByHuman: Bool = false, pauseOnHumanInput: Bool = true, permissions: DesktopPermissions = DesktopPermissions(), frontmostApp: String? = nil, displayWidth: Int = 0, displayHeight: Int = 0, streamingClients: Int = 0, updatedAt: Date = Date()) {
        self.owner = owner
        self.queue = queue
        self.pausedByHuman = pausedByHuman
        self.pauseOnHumanInput = pauseOnHumanInput
        self.permissions = permissions
        self.frontmostApp = frontmostApp
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.streamingClients = streamingClients
        self.updatedAt = updatedAt
    }
}

/// Remote input from a client during human takeover. Coordinates are normalised 0...1.
public enum RemoteInput: Hashable, Codable, Sendable {
    case pointerMove(x: Double, y: Double)
    case pointerDown(x: Double, y: Double, button: PointerButton)
    case pointerUp(x: Double, y: Double, button: PointerButton)
    case click(x: Double, y: Double, button: PointerButton, count: Int)
    case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double)
    case typeText(String)
    case key(KeyChord)
}

public enum PointerButton: String, Codable, Sendable { case left, right, middle }

public struct KeyChord: Hashable, Codable, Sendable {
    /// Key name: a single character, or names like "return", "escape", "tab", "space", "delete", "up", "f5", "cmd".
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Parse "cmd+shift+s" style strings.
    public init(parsing text: String) {
        var chord = KeyChord(key: "")
        let parts = text.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        for part in parts {
            switch part {
            case "cmd", "command", "meta", "super": chord.command = true
            case "shift": chord.shift = true
            case "opt", "option", "alt": chord.option = true
            case "ctrl", "control": chord.control = true
            default: chord.key = part
            }
        }
        if chord.key.isEmpty, let last = parts.last { chord.key = last }
        self = chord
    }
}

/// Screen frame header sent before each JPEG on the screen stream channel.
public struct ScreenFrameHeader: Hashable, Codable, Sendable {
    public var sequence: Int64
    public var width: Int
    public var height: Int
    public var timestamp: Date
    public var cursorX: Double?
    public var cursorY: Double?
    public var owner: DesktopOwner

    public init(sequence: Int64, width: Int, height: Int, timestamp: Date = Date(), cursorX: Double? = nil, cursorY: Double? = nil, owner: DesktopOwner) {
        self.sequence = sequence
        self.width = width
        self.height = height
        self.timestamp = timestamp
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.owner = owner
    }
}

public struct ScreenStreamOptions: Hashable, Codable, Sendable {
    public var framesPerSecond: Int
    public var maxWidth: Int
    public var jpegQuality: Double

    public init(framesPerSecond: Int = 6, maxWidth: Int = 1440, jpegQuality: Double = 0.6) {
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
        self.jpegQuality = jpegQuality
    }
}
