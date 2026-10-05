import PennantCore
import Foundation

/// Sites the owner let Pennant work on in their Chrome, kept in the data folder. Pennant's Chrome tabs carry the
/// owner's own sign-ins, so a new site is asked about once, on a card.
public actor ChromeSites {
    private let file: URL
    private var allowed: Set<String>

    public init(folder: URL) {
        file = folder.appendingPathComponent("chrome-sites.json")
        allowed = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? [])
    }

    public func isAllowed(_ site: String) -> Bool { allowed.contains(site) }
    public func list() -> [String] { allowed.sorted() }

    public func allow(_ site: String) {
        allowed.insert(site)
        try? JSONEncoder().encode(allowed.sorted()).write(to: file, options: .atomic)
    }

    public func remove(_ site: String) {
        allowed.remove(site)
        try? JSONEncoder().encode(allowed.sorted()).write(to: file, options: .atomic)
    }

    /// "signin.aws.amazon.com" → "amazon.com": the site a card asks about (the last two labels; three for the
    /// two-label country domains like co.uk).
    public static func site(of url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let twoLabelSuffixes: Set<String> = ["co.uk", "com.au", "co.jp", "com.br", "co.nz", "co.in", "com.mx", "co.za", "org.uk", "ac.uk", "gov.uk"]
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return twoLabelSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }
}

/// The tab each task last worked in, and the page that tab was last on.
actor WebTabRegistry {
    static let shared = WebTabRegistry()
    private var byTask: [TaskID: Int] = [:]
    private var urls: [Int: String] = [:]

    func use(_ tab: Int, url: String?, for task: TaskID) {
        byTask[task] = tab
        if let url { urls[tab] = url }
    }

    func tab(for task: TaskID) -> Int? { byTask[task] }
    func url(of tab: Int) -> String? { urls[tab] }
}

/// Pennant in the owner's Chrome: tabs of its own, in a window of its own, worked with Chrome's own input. The owner's
/// pointer and keyboard stay theirs, and so do their own tabs. The extension (Settings › Pennant › Chrome) does it.
public enum WebTools {
    public static let names: Set<String> = ["web_open", "web_read", "web_screenshot", "web_click", "web_type", "web_press_key", "web_scroll", "web_back", "web_tabs", "web_close"]

    public static func all(link: any BrowserLinking, sites: ChromeSites) -> [any Tool] {
        [WebOpenTool(link: link, sites: sites), WebReadTool(link: link), WebScreenshotTool(link: link), WebClickTool(link: link, sites: sites),
         WebTypeTool(link: link, sites: sites), WebPressKeyTool(link: link, sites: sites), WebScrollTool(link: link), WebBackTool(link: link),
         WebTabsTool(link: link), WebCloseTool(link: link)]
    }

    static let tabParameter = JSONSchema.integer("Optional: which of Pennant's tabs (from web_open or web_tabs). Default: the one this task last used.")

    static func text(_ name: String, _ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(callID: ToolCallID("pending"), name: name, content: [.text(text)], isError: isError)
    }

    /// The tab to act in: the one named, else this task's last.
    static func tab(_ arguments: JSONValue, _ context: ToolContext) async throws -> Int {
        if let tab = arguments.int("tab") { return tab }
        if let tab = await WebTabRegistry.shared.tab(for: context.taskID) { return tab }
        throw ToolError.failed("Open a page first with web_open: Pennant works in tabs of its own.")
    }

    /// When the owner wants to be asked (`chromeAsksForNewSites`), a site they haven't let Pennant use in their Chrome
    /// is asked about once, on a card; until they allow it, nothing happens there.
    static func ensureAllowed(_ url: String, sites: ChromeSites, context: ToolContext) async throws {
        guard context.config.chromeAsksForNewSites else { return }
        guard let site = ChromeSites.site(of: url), !["about", "chrome", "newtab"].contains(site) else { return }
        if url.hasPrefix("about:") || url.hasPrefix("chrome:") { return }
        if await sites.isAllowed(site) { return }
        guard let hooks = context.runtimeHooks else { throw ToolError.denied("Pennant hasn't been allowed to use \(site) in Chrome.") }
        var card = ApprovalRequest(taskID: context.taskID, title: "Use \(site) in your Chrome", destination: "Chrome · \(site)", text: url,
                                   notes: "Pennant works in tabs of its own, with your Chrome's sign-ins for \(site). Allowing it lets Pennant open and work on \(site) from now on; you can take it back in Settings › Pennant › Chrome.")
        card.approveLabel = "Allow \(site)"
        let decided = try await hooks.requestApproval(context.taskID, card)
        guard decided.state == .approved else { throw ToolError.denied("The owner didn't let Pennant use \(site) in Chrome. Don't try it another way.") }
        await sites.allow(site)
    }

    /// Before acting in a tab: its page is on an allowed site.
    static func ensureTabAllowed(_ tab: Int, sites: ChromeSites, context: ToolContext) async throws {
        if let url = await WebTabRegistry.shared.url(of: tab) { try await ensureAllowed(url, sites: sites, context: context) }
    }

    static func checkNotPaused(_ context: ToolContext) async throws {
        if await context.lease.pausedByHuman { throw ToolError.denied("The owner paused computer use. Wait until they resume it.") }
    }

    /// Runs an action and remembers the tab and its page.
    static func act(_ link: any BrowserLinking, _ action: String, _ params: [String: JSONValue], tab: Int?, context: ToolContext, timeout: TimeInterval = 60) async throws -> JSONValue {
        var p = params
        if let tab { p["tab"] = .number(Double(tab)) }
        let result = try await link.request(action, .object(p), timeout: timeout)
        if let used = result["tab"]?.intValue ?? tab { await WebTabRegistry.shared.use(used, url: result["url"]?.stringValue, for: context.taskID) }
        return result
    }

    static func describePage(_ r: JSONValue) -> String {
        "“\(r["title"]?.stringValue ?? "")” (tab \(r["tab"]?.intValue ?? 0)) at \(r["url"]?.stringValue ?? "")"
    }
}

struct WebOpenTool: Tool {
    let link: any BrowserLinking
    let sites: ChromeSites
    var spec: ToolSpec {
        ToolSpec(name: "web_open", description: "Open a page in the owner's Chrome, in a tab of Pennant's own (in Pennant's own Chrome window, behind theirs), with their sign-ins. Use it for anything on the web that needs them signed in, or a real browser: admin consoles, sign-ups, web apps. The owner keeps their pointer, keyboard and tabs. Then read it with web_read and act with web_click and web_type. A site the owner hasn't allowed yet is asked about once, on a card. Pass tab to load the page in a tab you already have.",
                 inputSchema: JSONSchema.object(["url": JSONSchema.string("The page's address"), "tab": WebTools.tabParameter], required: ["url"]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await WebTools.checkNotPaused(context)
        let url = try arguments.requireString("url")
        try await WebTools.ensureAllowed(url, sites: sites, context: context)
        let r = try await WebTools.act(link, "open", ["url": .string(url)], tab: arguments.int("tab"), context: context, timeout: 90)
        return WebTools.text(spec.name, "Opened \(WebTools.describePage(r)). Read it with web_read, or look with web_screenshot.")
    }
}

struct WebReadTool: Tool {
    let link: any BrowserLinking
    var spec: ToolSpec {
        ToolSpec(name: "web_read", description: "Read the page in one of Pennant's Chrome tabs: its text, and the links (with where they go, for web_open), buttons and fields on it, numbered, for web_click and web_type. Cheaper and more exact than a screenshot. Read again after anything changes the page.",
                 inputSchema: JSONSchema.object(["tab": WebTools.tabParameter]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let tab = try await WebTools.tab(arguments, context)
        let r = try await WebTools.act(link, "read", [:], tab: tab, context: context)
        var out = WebTools.describePage(r) + "\n\n" + (r["text"]?.stringValue ?? "")
        let elements = r["elements"]?.arrayValue ?? []
        if !elements.isEmpty {
            out += "\n\nOn the page (numbers for web_click and web_type; † = scrolled out of view):\n"
            for e in elements {
                var line = "[\(e["ref"]?.intValue ?? 0)] \(e["kind"]?.stringValue ?? "") “\(e["label"]?.stringValue ?? "")”"
                if let v = e["value"]?.stringValue { line += " = \"\(v)\"" }
                if let href = e["href"]?.stringValue { line += " → \(href)" }
                if e["inView"]?.boolValue == false { line += " †" }
                out += line + "\n"
            }
        }
        return WebTools.text(spec.name, out)
    }
}

struct WebScreenshotTool: Tool {
    let link: any BrowserLinking
    var spec: ToolSpec {
        ToolSpec(name: "web_screenshot", description: "Look at one of Pennant's Chrome tabs as an image (what's in view). For checking layout, images and anything web_read can't say. web_click also takes x and y in this image's pixels.",
                 inputSchema: JSONSchema.object(["tab": WebTools.tabParameter]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let tab = try await WebTools.tab(arguments, context)
        let r = try await WebTools.act(link, "screenshot", [:], tab: tab, context: context)
        guard let b64 = r["data"]?.stringValue, let jpeg = Data(base64Encoded: b64) else { throw ToolError.failed("Chrome sent no image") }
        let width = r["width"]?.intValue ?? 0, height = r["height"]?.intValue ?? 0
        let caption = "Chrome tab \(tab) \(width)x\(height)"
        let artifact = ArtifactRecord(kind: "screenshot", mimeType: "image/jpeg", byteCount: jpeg.count, fileName: "tab-\(Int(Date().timeIntervalSince1970)).jpg",
                                      taskID: context.taskID, agentID: context.agentID, caption: caption)
        try await context.store.putArtifact(artifact, data: jpeg)
        let ref = ImageRef(artifactID: artifact.id, mimeType: "image/jpeg", width: width, height: height, caption: caption)
        return ToolResult(callID: ToolCallID("pending"), name: spec.name, content: [.text("\(WebTools.describePage(r)), \(width)x\(height) px. web_click takes x and y in these pixels."), .image(ref)])
    }
}

struct WebClickTool: Tool {
    let link: any BrowserLinking
    let sites: ChromeSites
    var spec: ToolSpec {
        ToolSpec(name: "web_click", description: "Click in one of Pennant's Chrome tabs: an element by its number from web_read (best), or x and y in web_screenshot's pixels. Chrome's own input, never the owner's pointer. Read or look again to check what it did.",
                 inputSchema: JSONSchema.object([
                    "element": JSONSchema.integer("The element's number from web_read"),
                    "x": JSONSchema.number("Or: horizontal position in the web_screenshot's pixels"),
                    "y": JSONSchema.number("Or: vertical position in the web_screenshot's pixels"),
                    "button": JSONSchema.string("Mouse button", enumValues: ["left", "right", "middle"]),
                    "count": JSONSchema.integer("Number of clicks, 1 to 3 (default 1)"),
                    "tab": WebTools.tabParameter,
                 ]), isConsequential: true)
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await WebTools.checkNotPaused(context)
        let tab = try await WebTools.tab(arguments, context)
        try await WebTools.ensureTabAllowed(tab, sites: sites, context: context)
        var p: [String: JSONValue] = ["button": .string(arguments.string("button") ?? "left"), "count": .number(Double(max(1, min(3, arguments.int("count") ?? 1))))]
        if let ref = arguments.int("element") { p["ref"] = .number(Double(ref)) } else if let x = arguments.double("x"), let y = arguments.double("y") { p["x"] = .number(x); p["y"] = .number(y) } else {
            throw ToolError.invalidArguments("Name the element (its number from web_read), or give x and y.")
        }
        let r = try await WebTools.act(link, "click", p, tab: tab, context: context)
        return WebTools.text(spec.name, (r["did"]?.stringValue ?? "Clicked.") + " Now at \(r["url"]?.stringValue ?? "the same page").")
    }
}

struct WebTypeTool: Tool {
    let link: any BrowserLinking
    let sites: ChromeSites
    var spec: ToolSpec {
        ToolSpec(name: "web_type", description: "Type into a field in one of Pennant's Chrome tabs: name the field by its number from web_read (it's clicked first), or type where the caret already is. clear replaces what's there; submit presses Enter after.",
                 inputSchema: JSONSchema.object([
                    "text": JSONSchema.string("What to type"),
                    "element": JSONSchema.integer("The field's number from web_read"),
                    "clear": JSONSchema.boolean("Replace what's in the field (default false)"),
                    "submit": JSONSchema.boolean("Press Enter after (default false)"),
                    "tab": WebTools.tabParameter,
                 ], required: ["text"]), isConsequential: true)
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await WebTools.checkNotPaused(context)
        let tab = try await WebTools.tab(arguments, context)
        try await WebTools.ensureTabAllowed(tab, sites: sites, context: context)
        var p: [String: JSONValue] = ["text": .string(try arguments.requireString("text")), "clear": .bool(arguments.bool("clear") ?? false), "submit": .bool(arguments.bool("submit") ?? false)]
        if let ref = arguments.int("element") { p["ref"] = .number(Double(ref)) }
        let r = try await WebTools.act(link, "type", p, tab: tab, context: context)
        return WebTools.text(spec.name, (r["did"]?.stringValue ?? "Typed.") + " Now at \(r["url"]?.stringValue ?? "the same page").")
    }
}

struct WebPressKeyTool: Tool {
    let link: any BrowserLinking
    let sites: ChromeSites
    var spec: ToolSpec {
        ToolSpec(name: "web_press_key", description: "Press a key or shortcut in one of Pennant's Chrome tabs: \"enter\", \"escape\", \"tab\", \"arrowdown\", \"cmd+a\".",
                 inputSchema: JSONSchema.object(["keys": JSONSchema.string("Key name or modifier chord joined with '+'"), "tab": WebTools.tabParameter], required: ["keys"]), isConsequential: true)
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await WebTools.checkNotPaused(context)
        let tab = try await WebTools.tab(arguments, context)
        try await WebTools.ensureTabAllowed(tab, sites: sites, context: context)
        let r = try await WebTools.act(link, "key", ["keys": .string(try arguments.requireString("keys"))], tab: tab, context: context)
        return WebTools.text(spec.name, (r["did"]?.stringValue ?? "Pressed.") + " Now at \(r["url"]?.stringValue ?? "the same page").")
    }
}

struct WebScrollTool: Tool {
    let link: any BrowserLinking
    var spec: ToolSpec {
        ToolSpec(name: "web_scroll", description: "Scroll one of Pennant's Chrome tabs. Positive delta_y scrolls down, in CSS pixels (a screen is about 800).",
                 inputSchema: JSONSchema.object(["delta_y": JSONSchema.number("Pixels down (negative: up)"), "tab": WebTools.tabParameter], required: ["delta_y"]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let tab = try await WebTools.tab(arguments, context)
        let r = try await WebTools.act(link, "scroll", ["deltaY": .number(try arguments.requireDouble("delta_y"))], tab: tab, context: context)
        return WebTools.text(spec.name, r["did"]?.stringValue ?? "Scrolled.")
    }
}

struct WebBackTool: Tool {
    let link: any BrowserLinking
    var spec: ToolSpec {
        ToolSpec(name: "web_back", description: "Go back one page in one of Pennant's Chrome tabs.", inputSchema: JSONSchema.object(["tab": WebTools.tabParameter]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let tab = try await WebTools.tab(arguments, context)
        let r = try await WebTools.act(link, "back", [:], tab: tab, context: context)
        return WebTools.text(spec.name, "Back to \(WebTools.describePage(r)).")
    }
}

struct WebTabsTool: Tool {
    let link: any BrowserLinking
    var spec: ToolSpec {
        ToolSpec(name: "web_tabs", description: "List Pennant's own Chrome tabs: number, title and address. (The owner's own tabs aren't Pennant's and aren't listed.)", inputSchema: JSONSchema.object([:]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let r = try await link.request("tabs")
        let tabs = r["tabs"]?.arrayValue ?? []
        guard !tabs.isEmpty else { return WebTools.text(spec.name, "Pennant has no Chrome tabs open.") }
        return WebTools.text(spec.name, tabs.map { "[\($0["tab"]?.intValue ?? 0)] “\($0["title"]?.stringValue ?? "")” \($0["url"]?.stringValue ?? "")" }.joined(separator: "\n"))
    }
}

struct WebCloseTool: Tool {
    let link: any BrowserLinking
    var spec: ToolSpec {
        ToolSpec(name: "web_close", description: "Close one of Pennant's Chrome tabs when you're done with it.", inputSchema: JSONSchema.object(["tab": WebTools.tabParameter]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let tab = try await WebTools.tab(arguments, context)
        _ = try await link.request("close", .object(["tab": .number(Double(tab))]))
        return WebTools.text(spec.name, "Closed tab \(tab).")
    }
}
