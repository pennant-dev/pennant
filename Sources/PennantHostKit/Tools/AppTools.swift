import PennantCore
import Foundation

/// The window each task last looked at in each app, so app_click and friends take coordinates in that image's pixels.
public actor AppCaptureRegistry {
    public static let shared = AppCaptureRegistry()
    private var byTask: [TaskID: [Int32: WindowCapture]] = [:]

    public func record(_ capture: WindowCapture, for taskID: TaskID) {
        byTask[taskID, default: [:]][capture.app.pid] = capture
    }

    public func capture(app: String, for taskID: TaskID) -> WindowCapture? {
        let key = app.lowercased()
        return byTask[taskID]?.values.first { $0.app.name.lowercased() == key || $0.app.bundleID?.lowercased() == key }
            ?? byTask[taskID]?.values.first { $0.app.name.lowercased().contains(key) }
    }

    public func forget(taskID: TaskID) { byTask[taskID] = nil }
}

/// Working in an app in the background: the owner keeps their pointer, keyboard and screen. The app's window is seen
/// even behind other windows; presses, typing, keys and scrolling go to that app alone. Pennant's own cursor shows where.
public enum AppTools {
    public static let names: Set<String> = ["app_screenshot", "app_click", "app_type", "app_press_key", "app_scroll"]
    public static func all() -> [any Tool] { [AppScreenshotTool(), AppClickTool(), AppTypeTool(), AppPressKeyTool(), AppScrollTool()] }

    static let appParameter = JSONSchema.string("The app: its name as list_apps shows it (\"Finder\", \"Notes\") or its bundle id.")
    static let coordinateNote = "x and y are pixels in this task's latest app_screenshot of that app."

    /// Stopped by the owner (⇧⌘. or Pause in the app): background work stops too.
    static func checkNotPaused(_ context: ToolContext) async throws {
        if await context.lease.pausedByHuman { throw ToolError.denied("The owner paused computer use. Wait until they resume it.") }
    }

    static func latest(_ app: String, _ context: ToolContext) async throws -> WindowCapture {
        guard let capture = await AppCaptureRegistry.shared.capture(app: app, for: context.taskID) else {
            throw ToolError.failed("Look at \(app) first with app_screenshot: coordinates are pixels in that image.")
        }
        return capture
    }

    static func text(_ name: String, _ text: String) -> ToolResult { DesktopTools.text(name, text) }
}

struct AppScreenshotTool: Tool {
    let spec = ToolSpec(
        name: "app_screenshot",
        description: "See one app's window, even when other windows cover it, without bringing it to the front or touching the owner's screen. Use it, with app_click, app_type, app_press_key and app_scroll, to work in an app in the background while the owner keeps using their Mac. Coordinates for those tools are pixels in this image.",
        inputSchema: JSONSchema.object([
            "app": AppTools.appParameter,
            "window": JSONSchema.string("Optional: part of the window's title, when the app has several."),
            "max_width": JSONSchema.integer("Maximum image width in pixels (default from host settings)."),
        ], required: ["app"])
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await AppTools.checkNotPaused(context)
        let app = try arguments.requireString("app")
        let maxWidth = arguments.int("max_width") ?? context.config.desktop.screenshotMaxWidth
        let capture = try await context.desktop.captureWindow(app: app, title: arguments.string("window"), maxWidth: max(320, min(4096, maxWidth)))
        await AppCaptureRegistry.shared.record(capture, for: context.taskID)
        let caption = "\(capture.app.name) window\(capture.title.isEmpty ? "" : " “\(capture.title)”") \(capture.width)x\(capture.height)"
        let artifact = ArtifactRecord(kind: "screenshot", mimeType: "image/jpeg", byteCount: capture.jpeg.count, fileName: "window-\(Int(Date().timeIntervalSince1970)).jpg",
                                      taskID: context.taskID, agentID: context.agentID, caption: caption)
        try await context.store.putArtifact(artifact, data: capture.jpeg)
        var line = "\(caption) px\(capture.app.isFrontmost ? ", in front" : ", in the background (that's fine: the app_ tools work there)"). Give app_click, app_type and app_scroll coordinates in these pixels."
        line += "\nThe owner is free to use the Mac meanwhile; never use click or type_text on this app unless an app_ tool can't do it."
        let ref = ImageRef(artifactID: artifact.id, mimeType: "image/jpeg", width: capture.width, height: capture.height, caption: caption)
        return ToolResult(callID: DesktopTools.placeholderCallID, name: spec.name, content: [.text(line), .image(ref)])
    }
}

struct AppClickTool: Tool {
    let spec = ToolSpec(
        name: "app_click",
        description: "Click in an app's window in the background: a button is pressed, a field gets the caret, a right click opens the menu, without moving the owner's pointer or bringing the app forward. \(AppTools.coordinateNote) Check the result with app_screenshot.",
        inputSchema: JSONSchema.object([
            "app": AppTools.appParameter,
            "x": JSONSchema.number("Horizontal position in the app_screenshot's pixels"),
            "y": JSONSchema.number("Vertical position in the app_screenshot's pixels"),
            "button": JSONSchema.string("Mouse button", enumValues: ["left", "right", "middle"]),
            "count": JSONSchema.integer("Number of clicks, 1 to 3 (default 1)"),
        ], required: ["app", "x", "y"]),
        isConsequential: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await AppTools.checkNotPaused(context)
        let app = try arguments.requireString("app")
        let capture = try await AppTools.latest(app, context)
        let (x, y) = capture.toDisplay(x: try arguments.requireDouble("x"), y: try arguments.requireDouble("y"))
        let button = try DesktopTools.pointerButton(arguments.string("button"))
        let said = try await context.desktop.pressInApp(pid: capture.app.pid, x: x, y: y, button: button, count: max(1, min(3, arguments.int("count") ?? 1)))
        return AppTools.text(spec.name, said)
    }
}

struct AppTypeTool: Tool {
    let spec = ToolSpec(
        name: "app_type",
        description: "Type text into an app's focused field in the background (put the caret there first with app_click). The owner's keyboard is untouched. Newlines don't submit a form: use app_press_key with return.",
        inputSchema: JSONSchema.object([
            "app": AppTools.appParameter,
            "text": JSONSchema.string("The text to type"),
        ], required: ["app", "text"]),
        isConsequential: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await AppTools.checkNotPaused(context)
        let app = try arguments.requireString("app")
        let capture = try await AppTools.latest(app, context)
        let said = try await context.desktop.typeInApp(pid: capture.app.pid, text: try arguments.requireString("text"))
        return AppTools.text(spec.name, said)
    }
}

struct AppPressKeyTool: Tool {
    let spec = ToolSpec(
        name: "app_press_key",
        description: "Press a key or shortcut in an app in the background: \"return\", \"escape\", \"tab\", \"cmd+s\", \"cmd+shift+n\". Only that app gets it.",
        inputSchema: JSONSchema.object([
            "app": AppTools.appParameter,
            "keys": JSONSchema.string("Key name or modifier chord joined with '+'"),
        ], required: ["app", "keys"]),
        isConsequential: true
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await AppTools.checkNotPaused(context)
        let app = try arguments.requireString("app")
        let capture = try await AppTools.latest(app, context)
        let keys = try arguments.requireString("keys")
        try await context.desktop.keyInApp(pid: capture.app.pid, chord: KeyChord(parsing: keys))
        return AppTools.text(spec.name, "Pressed \(keys) in \(capture.app.name). Check with app_screenshot.")
    }
}

struct AppScrollTool: Tool {
    let spec = ToolSpec(
        name: "app_scroll",
        description: "Scroll in an app's window in the background, at a spot in the app_screenshot. Positive delta_y scrolls down. \(AppTools.coordinateNote)",
        inputSchema: JSONSchema.object([
            "app": AppTools.appParameter,
            "x": JSONSchema.number("Horizontal position in the app_screenshot's pixels"),
            "y": JSONSchema.number("Vertical position in the app_screenshot's pixels"),
            "delta_y": JSONSchema.number("Pixels to scroll down (negative: up)"),
            "delta_x": JSONSchema.number("Pixels to scroll right (negative: left)"),
        ], required: ["app", "x", "y", "delta_y"])
    )

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await AppTools.checkNotPaused(context)
        let app = try arguments.requireString("app")
        let capture = try await AppTools.latest(app, context)
        let (x, y) = capture.toDisplay(x: try arguments.requireDouble("x"), y: try arguments.requireDouble("y"))
        let scale = capture.frame.width / Double(max(1, capture.width))
        try await context.desktop.scrollInApp(pid: capture.app.pid, x: x, y: y, deltaX: (arguments.double("delta_x") ?? 0) * scale, deltaY: try arguments.requireDouble("delta_y") * scale)
        return AppTools.text(spec.name, "Scrolled in \(capture.app.name). Look again with app_screenshot.")
    }
}
