import PennantCore
import Foundation

/// Remembers the geometry of the last screenshot per task so the model can give coordinates in
/// screenshot pixels (what it actually sees) while the desktop receives display points.
public actor CaptureGeometryRegistry {
    public static let shared = CaptureGeometryRegistry()
    private var byTask: [TaskID: CaptureGeometry] = [:]

    public init() {}

    public func record(_ capture: CapturedScreen, for taskID: TaskID) {
        byTask[taskID] = CaptureGeometry(capture)
    }

    public func geometry(for taskID: TaskID) -> CaptureGeometry? { byTask[taskID] }

    public func forget(taskID: TaskID) { byTask[taskID] = nil }

    /// Screenshot pixels → display points. Identity when the task has not taken a screenshot.
    public func toDisplay(x: Double, y: Double, taskID: TaskID) -> (x: Double, y: Double) {
        byTask[taskID]?.toDisplay(x: x, y: y) ?? (x, y)
    }

}

/// Built-in desktop tools. Pointer coordinates are in pixels of the task's most recent screenshot.
public enum DesktopTools {
    /// Tool results are created before the broker knows the call; the broker overwrites `callID`.
    static let placeholderCallID = ToolCallID("pending")

    public static func all() -> [any Tool] {
        [
            ScreenshotTool(),
            PointerTool(kind: .click),
            PointerTool(kind: .doubleClick),
            PointerTool(kind: .rightClick),
            PointerTool(kind: .move),
            DragTool(),
            ScrollTool(),
            TypeTextTool(),
            PressKeyTool(),
            OpenAppTool(),
            ActivateAppTool(),
            ListAppsTool(),
            UITreeTool(),
            UIActionTool(),
            UISetValueTool(),
            AppleScriptTool(),
            JXATool(),
            WaitTool(),
        ] + AppTools.all()
    }

    static func text(_ name: String, _ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(callID: placeholderCallID, name: name, content: [.text(text)], isError: isError)
    }

    static let coordinateNote = "x and y are pixels in the most recent screenshot for this task; take a screenshot first."

    static func describe(_ app: RunningApp) -> String {
        var line = "\(app.name) (pid \(app.pid)\(app.bundleID.map { ", \($0)" } ?? ""))\(app.isFrontmost ? " [frontmost]" : "")"
        if !app.windowTitles.isEmpty { line += " windows: " + app.windowTitles.map { "\"\($0)\"" }.joined(separator: ", ") }
        return line
    }

    static func pointerButton(_ raw: String?) throws -> PointerButton {
        guard let raw, !raw.isEmpty else { return .left }
        guard let button = PointerButton(rawValue: raw.lowercased()) else { throw ToolError.invalidArguments("button must be left, right, or middle") }
        return button
    }
}

// MARK: - Screenshot

struct ScreenshotTool: Tool {
    let spec = ToolSpec(
        name: "screenshot",
        description: "Capture the main display as an image. Use it before pointer actions to see the current screen and again after actions to verify the result. Returns the image plus its pixel size; give all click, drag, and scroll coordinates in these screenshot pixels.",
        inputSchema: JSONSchema.object(["max_width": JSONSchema.integer("Maximum image width in pixels (default from host settings, typically 1440)")]),
        isConsequential: false,
        needsDesktop: false
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let maxWidth = arguments.int("max_width") ?? context.config.desktop.screenshotMaxWidth
        let capture = try await context.desktop.captureScreen(maxWidth: max(320, min(4096, maxWidth)))
        await CaptureGeometryRegistry.shared.record(capture, for: context.taskID)
        let frontmost = await context.desktop.frontmostApp()
        let caption = "Screenshot \(capture.width)x\(capture.height)" + (frontmost.map { ", \($0.name) in front" } ?? "")
        let artifact = ArtifactRecord(kind: "screenshot", mimeType: "image/jpeg", byteCount: capture.jpeg.count, fileName: "screenshot-\(Int(capture.capturedAt.timeIntervalSince1970)).jpg", taskID: context.taskID, agentID: context.agentID, caption: caption)
        try await context.store.putArtifact(artifact, data: capture.jpeg)
        let scale = CaptureGeometry(capture).scale
        var lines: [String] = []
        lines.append("Screenshot \(capture.width)x\(capture.height) px of a \(capture.displayWidth)x\(capture.displayHeight) pt display (1 px = \(String(format: "%.2f", scale)) pt). Give coordinates in screenshot pixels.")
        if let frontmost { lines.append("Frontmost app: " + DesktopTools.describe(frontmost)) }
        if let cx = capture.cursorX, let cy = capture.cursorY { lines.append("Cursor at (\(Int(cx)), \(Int(cy))).") }
        let ref = ImageRef(artifactID: artifact.id, mimeType: "image/jpeg", width: capture.width, height: capture.height, caption: caption)
        return ToolResult(callID: DesktopTools.placeholderCallID, name: spec.name, content: [.text(lines.joined(separator: "\n")), .image(ref)])
    }
}

// MARK: - Pointer

struct PointerTool: Tool {
    enum Kind { case click, doubleClick, rightClick, move }
    let kind: Kind
    let spec: ToolSpec

    init(kind: Kind) {
        self.kind = kind
        let coords: [String: JSONValue] = [
            "x": JSONSchema.number("Horizontal position in screenshot pixels"),
            "y": JSONSchema.number("Vertical position in screenshot pixels"),
        ]
        switch kind {
        case .click:
            var props = coords
            props["button"] = JSONSchema.string("Mouse button", enumValues: ["left", "right", "middle"])
            props["count"] = JSONSchema.integer("Number of clicks, 1 to 3 (default 1)")
            spec = ToolSpec(name: "click", description: "Click at a position. \(DesktopTools.coordinateNote) Take a new screenshot afterwards to verify the result.", inputSchema: JSONSchema.object(props, required: ["x", "y"]), isConsequential: true, needsDesktop: true)
        case .doubleClick:
            spec = ToolSpec(name: "double_click", description: "Double-click at a position (opens items, selects words). \(DesktopTools.coordinateNote)", inputSchema: JSONSchema.object(coords, required: ["x", "y"]), isConsequential: true, needsDesktop: true)
        case .rightClick:
            spec = ToolSpec(name: "right_click", description: "Right-click (secondary click) at a position to open a context menu. \(DesktopTools.coordinateNote) Screenshot afterwards to read the menu.", inputSchema: JSONSchema.object(coords, required: ["x", "y"]), isConsequential: true, needsDesktop: true)
        case .move:
            spec = ToolSpec(name: "move_mouse", description: "Move the pointer without clicking (reveals hover states and tooltips). \(DesktopTools.coordinateNote)", inputSchema: JSONSchema.object(coords, required: ["x", "y"]), isConsequential: false, needsDesktop: true)
        }
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let sx = try arguments.requireDouble("x")
        let sy = try arguments.requireDouble("y")
        let (x, y) = await CaptureGeometryRegistry.shared.toDisplay(x: sx, y: sy, taskID: context.taskID)
        try await context.requireDesktop()
        switch kind {
        case .click:
            let button = try DesktopTools.pointerButton(arguments.string("button"))
            let count = max(1, min(3, arguments.int("count") ?? 1))
            try await context.desktop.click(x: x, y: y, button: button, count: count)
            return DesktopTools.text(spec.name, "Clicked \(button.rawValue)\(count > 1 ? " x\(count)" : "") at (\(Int(sx)), \(Int(sy))). Take a screenshot to verify.")
        case .doubleClick:
            try await context.desktop.click(x: x, y: y, button: .left, count: 2)
            return DesktopTools.text(spec.name, "Double-clicked at (\(Int(sx)), \(Int(sy))). Take a screenshot to verify.")
        case .rightClick:
            try await context.desktop.click(x: x, y: y, button: .right, count: 1)
            return DesktopTools.text(spec.name, "Right-clicked at (\(Int(sx)), \(Int(sy))). Take a screenshot to read the menu.")
        case .move:
            try await context.desktop.moveMouse(x: x, y: y)
            return DesktopTools.text(spec.name, "Pointer moved to (\(Int(sx)), \(Int(sy))).")
        }
    }
}

struct DragTool: Tool {
    let spec = ToolSpec(
        name: "drag",
        description: "Press the left button at one position, move to another, and release (moves items, selects text, resizes). \(DesktopTools.coordinateNote)",
        inputSchema: JSONSchema.object([
            "from_x": JSONSchema.number("Start x in screenshot pixels"),
            "from_y": JSONSchema.number("Start y in screenshot pixels"),
            "to_x": JSONSchema.number("End x in screenshot pixels"),
            "to_y": JSONSchema.number("End y in screenshot pixels"),
        ], required: ["from_x", "from_y", "to_x", "to_y"]),
        isConsequential: true,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let fx = try arguments.requireDouble("from_x"), fy = try arguments.requireDouble("from_y")
        let tx = try arguments.requireDouble("to_x"), ty = try arguments.requireDouble("to_y")
        let registry = CaptureGeometryRegistry.shared
        let from = await registry.toDisplay(x: fx, y: fy, taskID: context.taskID)
        let to = await registry.toDisplay(x: tx, y: ty, taskID: context.taskID)
        try await context.requireDesktop()
        try await context.desktop.drag(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y)
        return DesktopTools.text(spec.name, "Dragged from (\(Int(fx)), \(Int(fy))) to (\(Int(tx)), \(Int(ty))). Take a screenshot to verify.")
    }
}

struct ScrollTool: Tool {
    let spec = ToolSpec(
        name: "scroll",
        description: "Scroll at a position. Positive delta_y scrolls down (reveals content below); negative scrolls up. Positive delta_x scrolls right. \(DesktopTools.coordinateNote)",
        inputSchema: JSONSchema.object([
            "x": JSONSchema.number("Position x in screenshot pixels"),
            "y": JSONSchema.number("Position y in screenshot pixels"),
            "delta_x": JSONSchema.number("Horizontal amount in screenshot pixels (default 0)"),
            "delta_y": JSONSchema.number("Vertical amount in screenshot pixels (default 400)"),
        ], required: ["x", "y"]),
        isConsequential: false,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let sx = try arguments.requireDouble("x"), sy = try arguments.requireDouble("y")
        let dx = arguments.double("delta_x") ?? 0
        let dy = arguments.double("delta_y") ?? 400
        let registry = CaptureGeometryRegistry.shared
        let (x, y) = await registry.toDisplay(x: sx, y: sy, taskID: context.taskID)
        let scale = await registry.geometry(for: context.taskID)?.scale ?? 1
        try await context.requireDesktop()
        try await context.desktop.scroll(x: x, y: y, deltaX: dx * scale, deltaY: dy * scale)
        return DesktopTools.text(spec.name, "Scrolled by (\(Int(dx)), \(Int(dy))) at (\(Int(sx)), \(Int(sy))). Take a screenshot to see the new content.")
    }
}

// MARK: - Keyboard

struct TypeTextTool: Tool {
    let spec = ToolSpec(
        name: "type_text",
        description: "Type text into the focused control exactly as given (newlines press Return). Click into the target field first. For shortcuts use press_key instead.",
        inputSchema: JSONSchema.object(["text": JSONSchema.string("Text to type")], required: ["text"]),
        isConsequential: true,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let text = arguments.string("text") else { throw ToolError.invalidArguments("missing string 'text'") }
        guard text.count <= 20_000 else { throw ToolError.invalidArguments("text is too long (max 20000 characters)") }
        try await context.requireDesktop()
        try await context.desktop.typeText(text)
        return DesktopTools.text(spec.name, "Typed \(text.count) characters. Take a screenshot to verify.")
    }
}

struct PressKeyTool: Tool {
    let spec = ToolSpec(
        name: "press_key",
        description: "Press a key or shortcut, e.g. \"return\", \"escape\", \"tab\", \"cmd+s\", \"cmd+shift+t\", \"ctrl+a\", \"down\", \"f5\". Modifiers: cmd, shift, option/alt, ctrl.",
        inputSchema: JSONSchema.object(["keys": JSONSchema.string("Key name or modifier chord joined with '+'")], required: ["keys"]),
        isConsequential: true,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let keys = try arguments.requireString("keys")
        let chord = KeyChord(parsing: keys)
        guard !chord.key.isEmpty else { throw ToolError.invalidArguments("no key in '\(keys)'") }
        try await context.requireDesktop()
        try await context.desktop.pressKey(chord)
        return DesktopTools.text(spec.name, "Pressed \(keys). Take a screenshot to verify.")
    }
}

// MARK: - Applications

struct OpenAppTool: Tool {
    let spec = ToolSpec(
        name: "open_app",
        description: "Launch an application by name or bundle identifier (e.g. \"Safari\", \"com.apple.Notes\") and bring it to the front. If it is already running it is activated. Take a screenshot afterwards.",
        inputSchema: JSONSchema.object(["name": JSONSchema.string("Application name or bundle identifier")], required: ["name"]),
        isConsequential: false,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let name = try arguments.requireString("name")
        try await context.requireDesktop()
        let app = try await context.desktop.launchApp(nameOrBundleID: name)
        return DesktopTools.text(spec.name, "Opened " + DesktopTools.describe(app) + (app.isFrontmost ? "." : ". It is not frontmost yet; activate_app or wait, then screenshot."))
    }
}

struct ActivateAppTool: Tool {
    let spec = ToolSpec(
        name: "activate_app",
        description: "Bring a running application to the front by name or bundle identifier.",
        inputSchema: JSONSchema.object(["name": JSONSchema.string("Application name or bundle identifier")], required: ["name"]),
        isConsequential: false,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let name = try arguments.requireString("name")
        try await context.requireDesktop()
        let app = try await context.desktop.activateApp(nameOrBundleID: name)
        return DesktopTools.text(spec.name, "Activated " + DesktopTools.describe(app) + ".")
    }
}

struct ListAppsTool: Tool {
    let spec = ToolSpec(
        name: "list_apps",
        description: "List running applications with their window titles and which one is frontmost. Read-only.",
        inputSchema: JSONSchema.object([:]),
        isConsequential: false,
        needsDesktop: false
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let apps = await context.desktop.runningApps()
        guard !apps.isEmpty else { return DesktopTools.text(spec.name, "No regular applications are running.") }
        return DesktopTools.text(spec.name, apps.map { "- " + DesktopTools.describe($0) }.joined(separator: "\n"))
    }
}

// MARK: - Accessibility

struct UITreeTool: Tool {
    let spec = ToolSpec(
        name: "ui_tree",
        description: "Read the accessibility tree of an app (frontmost by default): buttons, fields, menus, text with positions. More reliable than guessing from pixels. Each node has an index for ui_action / ui_set_value; its center can also be clicked. Read-only.",
        inputSchema: JSONSchema.object([
            "app": JSONSchema.string("Application name, bundle identifier, or pid (default: frontmost)"),
            "max_depth": JSONSchema.integer("Tree depth limit (default 14)"),
            "max_nodes": JSONSchema.integer("Node limit (default 250, max 1500)"),
        ]),
        isConsequential: false,
        needsDesktop: false
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let maxDepth = max(1, min(40, arguments.int("max_depth") ?? 14))
        let maxNodes = max(1, min(1500, arguments.int("max_nodes") ?? 250))
        var pid: Int32?
        var appName = "frontmost app"
        if let reference = arguments.string("app"), !reference.isEmpty {
            let apps = await context.desktop.runningApps()
            let needle = reference.lowercased()
            let match = apps.first { String($0.pid) == needle || $0.bundleID?.lowercased() == needle || $0.name.lowercased() == needle }
                ?? apps.first { $0.name.lowercased().contains(needle) }
            guard let match else { throw ToolError.failed("No running application matches '\(reference)'") }
            pid = match.pid
            appName = match.name
        } else if let front = await context.desktop.frontmostApp() {
            appName = front.name
        }
        let nodes = try await context.desktop.accessibilityTree(pid: pid, maxDepth: maxDepth, maxNodes: maxNodes)
        let registry = CaptureGeometryRegistry.shared
        let geometry = await registry.geometry(for: context.taskID)
        var lines: [String] = []
        lines.append("\(appName): \(nodes.count) nodes (depth ≤ \(maxDepth)\(nodes.count >= maxNodes ? ", truncated" : "")). Positions are \(geometry == nil ? "display points" : "screenshot pixels") as @x,y wxh. Act with ui_action {index, action} or click the node's center.")
        for node in nodes {
            let (x, y) = geometry?.toScreenshot(x: node.x, y: node.y) ?? (node.x, node.y)
            let scale = geometry.map { 1 / $0.scale } ?? 1
            var line = String(repeating: " ", count: min(node.depth, 12)) + "[\(node.index)] \(node.role)"
            if !node.title.isEmpty { line += " '\(node.title)'" }
            if !node.value.isEmpty { line += " value=\"\(node.value.replacingOccurrences(of: "\n", with: " "))\"" }
            if !node.description.isEmpty, node.description != node.title { line += " (\(node.description))" }
            line += " @\(Int(x)),\(Int(y)) \(Int(node.width * scale))x\(Int(node.height * scale))"
            if !node.enabled { line += " disabled" }
            if node.focused { line += " focused" }
            let actions = node.actions.filter { $0 != "AXScrollToVisible" && $0 != "AXShowMenu" }
            if !actions.isEmpty { line += " actions=" + actions.joined(separator: ",") }
            lines.append(line)
        }
        return DesktopTools.text(spec.name, lines.joined(separator: "\n"))
    }
}

struct UIActionTool: Tool {
    let spec = ToolSpec(
        name: "ui_action",
        description: "Perform an accessibility action on a node from the last ui_tree call (default AXPress, which activates buttons, menu items, checkboxes, links). Other common actions: AXShowMenu, AXIncrement, AXDecrement, AXConfirm, AXCancel.",
        inputSchema: JSONSchema.object([
            "index": JSONSchema.integer("Node index from ui_tree"),
            "action": JSONSchema.string("Action name (default AXPress)"),
        ], required: ["index"]),
        isConsequential: true,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let index = arguments.int("index") else { throw ToolError.invalidArguments("missing integer 'index'") }
        let action = arguments.string("action").flatMap { $0.isEmpty ? nil : $0 } ?? "AXPress"
        try await context.requireDesktop()
        try await context.desktop.performAXAction(index: index, action: action)
        return DesktopTools.text(spec.name, "Performed \(action) on node \(index). Re-read ui_tree or take a screenshot to verify.")
    }
}

struct UISetValueTool: Tool {
    let spec = ToolSpec(
        name: "ui_set_value",
        description: "Set the value of a text field, text area, slider, or similar node from the last ui_tree call directly through accessibility (faster and more reliable than typing).",
        inputSchema: JSONSchema.object([
            "index": JSONSchema.integer("Node index from ui_tree"),
            "value": JSONSchema.string("New value"),
        ], required: ["index", "value"]),
        isConsequential: true,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let index = arguments.int("index") else { throw ToolError.invalidArguments("missing integer 'index'") }
        guard let value = arguments.string("value") else { throw ToolError.invalidArguments("missing string 'value'") }
        try await context.requireDesktop()
        try await context.desktop.setAXValue(index: index, value: value)
        return DesktopTools.text(spec.name, "Set node \(index) value (\(value.count) characters). Re-read ui_tree or take a screenshot to verify.")
    }
}

// MARK: - Scripting

struct AppleScriptTool: Tool {
    let spec = ToolSpec(
        name: "run_applescript",
        description: "Run AppleScript on this Mac and return its result. Best for scriptable apps (Finder, Mail, Safari, Notes, Calendar, Music, Numbers). Runs with the user's permissions; a first run against an app may need Automation approval.",
        inputSchema: JSONSchema.object(["source": JSONSchema.string("AppleScript source")], required: ["source"]),
        isConsequential: true,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let source = try arguments.requireString("source")
        try await context.requireDesktop()
        let output = try await context.desktop.runAppleScript(source)
        return DesktopTools.text(spec.name, output.isEmpty ? "(no result)" : String(output.prefix(20_000)))
    }
}

struct JXATool: Tool {
    let spec = ToolSpec(
        name: "run_jxa",
        description: "Run JavaScript for Automation (osascript -l JavaScript) and return its output. Use `Application('Safari')`-style automation; call `console.log` or return a value.",
        inputSchema: JSONSchema.object(["source": JSONSchema.string("JavaScript for Automation source")], required: ["source"]),
        isConsequential: true,
        needsDesktop: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let source = try arguments.requireString("source")
        try await context.requireDesktop()
        let output = try await context.desktop.runJavaScriptForAutomation(source)
        return DesktopTools.text(spec.name, output.isEmpty ? "(no output)" : String(output.prefix(20_000)))
    }
}

// MARK: - Wait

struct WaitTool: Tool {
    let spec = ToolSpec(
        name: "wait",
        description: "Pause for a few seconds while an app loads or an animation finishes, then take a screenshot.",
        inputSchema: JSONSchema.object(["seconds": JSONSchema.number("Seconds to wait, 0.1 to 30 (default 2)")]),
        isConsequential: false,
        needsDesktop: false
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let seconds = max(0.1, min(30, arguments.double("seconds") ?? 2))
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        return DesktopTools.text(spec.name, "Waited \(String(format: "%.1f", seconds)) s.")
    }
}
