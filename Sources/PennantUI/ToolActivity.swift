import PennantClientKit
import PennantCore
import SwiftUI

// One tool call as the conversation shows it, and the rules that turn a raw call/result pair into a line
// a person can read: "Ran `ls -la ~/Downloads` · Done · 1.2 s" over "drwxr-xr-x  14 items".

// MARK: - Model

/// A tool call, the result once it has arrived, and the runtime record (intent → running → outcome).
/// `call` is nil for a result whose call fell before the loaded history (cut by a checkpoint).
struct ToolActivity: Identifiable {
    var call: ToolCall?
    var result: ToolResult?
    var record: ToolRecord?
    /// True while the owning task is still going, so a call with no record yet reads as running.
    var taskActive: Bool = false

    var id: ToolCallID { call?.id ?? result?.callID ?? ToolCallID("") }
    var name: String { call?.name ?? record?.call.name ?? result?.name ?? "" }
    var arguments: JSONValue { call?.arguments ?? record?.call.arguments ?? .object([:]) }

    var status: ToolActivityStatus {
        // A result is the tool's own word; a record that still says "running" only means the events crossed.
        if let result {
            switch record?.status {
            case .uncertain?: return .uncertain
            case .denied?: return .denied
            case .cancelled?: return .cancelled
            case .failed?: return .failed
            default: return result.isError ? .failed : .done
            }
        }
        switch record?.status {
        case .intended?: return taskActive ? .running : .pending
        case .running?: return .running
        case .succeeded?: return .done
        case .failed?: return .failed
        case .uncertain?: return .uncertain
        case .cancelled?: return .cancelled
        case .denied?: return .denied
        case nil: return taskActive ? .running : .pending
        }
    }

    /// Wall time from the record, once the tool has finished.
    var duration: TimeInterval? {
        guard let record, let end = record.finishedAt else { return nil }
        return max(0, end.timeIntervalSince(record.startedAt))
    }

    var images: [ImageRef] {
        result?.content.compactMap { if case .image(let ref) = $0 { return ref } else { return nil } } ?? []
    }

    /// Argument rows in a stable order: the tool's main argument first, then the rest alphabetically.
    var argumentRows: [(key: String, value: JSONValue)] {
        guard let object = arguments.objectValue else { return [] }
        let primary = ToolPresentation.primaryArgument(for: name)
        return object.sorted { a, b in
            if a.key == primary { return true }
            if b.key == primary { return false }
            return a.key < b.key
        }.map { (key: $0.key, value: $0.value) }
    }
}

enum ToolActivityStatus {
    case pending, running, done, failed, uncertain, denied, cancelled

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        case .uncertain: return "Uncertain · checking before retrying"
        case .denied: return "Denied"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .pending, .cancelled: return PennantTheme.inkTertiary
        case .running: return PennantTheme.info
        case .done: return PennantTheme.success
        case .failed, .denied: return PennantTheme.danger
        case .uncertain: return PennantTheme.warning
        }
    }

    var isFailure: Bool { self == .failed || self == .denied }
}

/// Which results in a conversation already have their call on screen, so the standalone result rows can
/// fold into the call's card. Built once per timeline from every loaded message.
struct ToolPairing {
    var results: [ToolCallID: ToolResult] = [:]
    var calls: Set<ToolCallID> = []

    init() {}

    init(messages: [Message]) {
        for m in messages {
            for part in m.parts {
                switch part {
                case .toolCall(let c): calls.insert(c.id)
                case .toolResult(let r): results[r.callID] = r
                default: break
                }
            }
        }
    }

    /// True when every part of the message is a result whose call is shown elsewhere: nothing left to draw.
    func suppresses(_ message: Message) -> Bool {
        guard message.role == .tool, !message.parts.isEmpty else { return false }
        return message.parts.allSatisfy { part in
            if case .toolResult(let r) = part { return calls.contains(r.callID) }
            return false
        }
    }
}

/// Names the title builder needs beyond the call itself: skills by id, MCP servers by their tool prefix.
struct ToolNaming {
    var skillNames: [String: String] = [:]
    var mcpServerNames: [String: String] = [:]

    @MainActor
    static func from(_ state: ClientState) -> ToolNaming {
        var naming = ToolNaming()
        for skill in state.skills { naming.skillNames[skill.id.rawValue] = skill.name }
        for server in state.mcpServers {
            naming.mcpServerNames[ToolPresentation.mcpPrefix(for: server.config.name)] = server.config.name
        }
        return naming
    }
}

// MARK: - Presentation rules

/// A card title: a verb phrase, optionally followed by an inline code chip (a command, a URL) whose full
/// text shows on hover.
struct ToolTitle {
    var text: String
    var code: String?
    var codeFull: String?
}

struct ToolSummary {
    var text: String
    var isError: Bool = false
}

enum ToolPresentation {
    // MARK: Family

    /// The symbol and tint for a tool family. MCP tools are `<server>__<tool>`.
    static func glyph(for name: String) -> (symbol: String, tint: Color) {
        if name.contains("__") { return ("puzzlepiece.extension", ShellPalette.rose) }
        switch name {
        case "Bash": return ("terminal", PennantTheme.inkSecondary)
        case "Read", "Grep", "Glob": return ("doc.text.magnifyingglass", PennantTheme.info)
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return ("pencil", PennantTheme.success)
        case "TodoWrite": return ("checklist", PennantTheme.inkSecondary)
        case "WebFetch", "WebSearch": return ("safari", PennantTheme.info)
        case "Task", "Agent": return ("person.2", PennantTheme.success)
        case "shell": return ("terminal", PennantTheme.inkSecondary)
        case "read_file": return ("doc.text", PennantTheme.info)
        case "write_file": return ("square.and.pencil", PennantTheme.info)
        case "edit_file": return ("pencil", PennantTheme.success)
        case "list_directory": return ("folder", PennantTheme.info)
        case "screenshot": return ("camera.viewfinder", ShellPalette.teal)
        case "click", "double_click", "right_click", "move_mouse", "ui_action": return ("cursorarrow.click", ShellPalette.teal)
        case "type_text", "press_key", "ui_set_value": return ("keyboard", ShellPalette.teal)
        case "scroll": return ("scroll", ShellPalette.teal)
        case "drag": return ("arrow.up.left.and.down.right", ShellPalette.teal)
        case "ui_tree": return ("list.bullet.indent", ShellPalette.teal)
        case "wait": return ("clock", ShellPalette.teal)
        case "open_app", "activate_app", "list_apps": return ("app", ShellPalette.violet)
        case "run_applescript", "run_jxa": return ("applescript", ShellPalette.violet)
        case "open_url": return ("safari", PennantTheme.info)
        case "memory_search", "memory_remember", "remember_instruction": return ("brain", ShellPalette.violet)
        case "use_skill", "find_skill", "learn_skill", "import_skills": return ("wand.and.stars", PennantTheme.attention)
        case "delegate_task", "await_task": return ("person.2", PennantTheme.success)
        case "code": return ("chevron.left.forwardslash.chevron.right", PennantTheme.info)
        case "ask_user": return ("questionmark.bubble", ShellPalette.violet)
        case "schedule_job", "list_schedules", "cancel_schedule": return ("calendar.badge.clock", PennantTheme.warning)
        case "share_file": return ("paperclip", PennantTheme.info)
        default:
            if name.hasPrefix("browser_") { return ("safari", PennantTheme.info) }
            if name.hasPrefix("memory_") { return ("brain", ShellPalette.violet) }
            if name.hasPrefix("schedule_") { return ("calendar.badge.clock", PennantTheme.warning) }
            return ("wrench.and.screwdriver", PennantTheme.inkSecondary)
        }
    }

    /// The argument the title is built from, listed first in the Input rows.
    static func primaryArgument(for name: String) -> String? {
        switch name {
        case "shell": return "command"
        case "read_file", "write_file", "edit_file", "list_directory", "import_skills", "share_file": return "path"
        case "type_text": return "text"
        case "press_key": return "keys"
        case "open_app", "activate_app", "schedule_job", "learn_skill": return "name"
        case "run_applescript", "run_jxa": return "source"
        case "open_url": return "url"
        case "memory_search", "find_skill": return "query"
        case "use_skill": return "skill_id"
        case "delegate_task": return "title"
        case "code": return "request"
        case "ask_user": return "question"
        case "remember_instruction": return "instruction"
        case "ui_tree": return "app"
        default: return nil
        }
    }

    /// How the host derives an MCP tool's prefix from the server name.
    static func mcpPrefix(for serverName: String) -> String {
        serverName.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
    }

    /// "read_file" → "Read file".
    static func humanised(_ name: String) -> String {
        let words = name.split(separator: "_").map(String.init)
        guard let first = words.first, !first.isEmpty else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    // MARK: Title

    static func title(for activity: ToolActivity, naming: ToolNaming = ToolNaming()) -> ToolTitle {
        let name = activity.name
        let args = activity.arguments
        func str(_ key: String) -> String? {
            guard let s = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func num(_ key: String) -> Int? { args[key]?.intValue }
        func quoted(_ s: String, limit: Int = 48) -> String { "“\(truncatedLine(s, limit: limit))”" }
        func point(_ xKey: String = "x", _ yKey: String = "y") -> String? {
            guard let x = num(xKey), let y = num(yKey) else { return nil }
            return "\(x), \(y)"
        }
        /// A label the model attached to a click target, when it passed one.
        func target() -> String? {
            for key in ["label", "element", "target", "description"] { if let s = str(key) { return truncatedLine(s, limit: 40) } }
            return nil
        }

        if let range = name.range(of: "__") {
            let prefix = String(name[..<range.lowerBound])
            let tool = String(name[range.upperBound...])
            let server = naming.mcpServerNames[prefix] ?? humanised(prefix)
            let firstString = activity.argumentRows.first { $0.value.stringValue != nil }?.value.stringValue
            return ToolTitle(text: "\(server) · \(tool)", code: firstString.map { truncatedLine($0, limit: 40) }, codeFull: firstString)
        }

        switch name {
        case "shell":
            guard let command = str("command") else { return ToolTitle(text: "Ran a command") }
            return ToolTitle(text: "Ran", code: truncatedLine(command, limit: 60), codeFull: command)
        case "read_file":
            return ToolTitle(text: str("path").map { "Read \(fileName(of: $0))" } ?? "Read a file")
        case "write_file":
            return ToolTitle(text: str("path").map { "Wrote \(fileName(of: $0))" } ?? "Wrote a file")
        case "edit_file":
            return ToolTitle(text: str("path").map { "Edited \(fileName(of: $0))" } ?? "Edited a file")
        case "list_directory":
            return ToolTitle(text: str("path").map { "Listed \(truncatedLine(abbreviatePath($0), limit: 60))" } ?? "Listed a directory")
        case "screenshot":
            return ToolTitle(text: "Took a screenshot")
        case "click", "double_click", "right_click", "move_mouse":
            let verb: String = {
                switch name {
                case "double_click": return "Double-clicked"
                case "right_click": return "Right-clicked"
                case "move_mouse": return "Moved the pointer"
                default: return "Clicked"
                }
            }()
            if let t = target() { return ToolTitle(text: "\(verb) \(t)") }
            if let p = point() { return ToolTitle(text: "\(verb) at \(p)") }
            return ToolTitle(text: verb)
        case "ui_action":
            let action = str("action").map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Acted on"
            return ToolTitle(text: num("index").map { "\(action) element #\($0)" } ?? action)
        case "ui_set_value":
            return ToolTitle(text: num("index").map { "Set element #\($0)" } ?? "Set a value", code: str("value").map { truncatedLine($0, limit: 40) }, codeFull: str("value"))
        case "ui_tree":
            return ToolTitle(text: str("app").map { "Read the UI of \($0)" } ?? "Read the screen’s UI")
        case "type_text":
            return ToolTitle(text: str("text").map { "Typed \(quoted($0, limit: 40))" } ?? "Typed text")
        case "press_key":
            return ToolTitle(text: str("keys").map { "Pressed \(keyGlyphs($0))" } ?? "Pressed a key")
        case "scroll":
            let dy = num("delta_y") ?? 0, dx = num("delta_x") ?? 0
            let direction: String = abs(dy) >= abs(dx) ? (dy < 0 ? "up" : "down") : (dx < 0 ? "left" : "right")
            return ToolTitle(text: "Scrolled \(direction)")
        case "drag":
            if let from = point("from_x", "from_y"), let to = point("to_x", "to_y") { return ToolTitle(text: "Dragged from \(from) to \(to)") }
            return ToolTitle(text: "Dragged")
        case "wait":
            return ToolTitle(text: num("seconds").map { "Waited \($0) s" } ?? "Waited")
        case "open_app":
            return ToolTitle(text: str("name").map { "Opened \($0)" } ?? "Opened an app")
        case "activate_app":
            return ToolTitle(text: str("name").map { "Switched to \($0)" } ?? "Switched apps")
        case "list_apps":
            return ToolTitle(text: "Listed open apps")
        case "run_applescript", "run_jxa":
            let source = str("source")
            return ToolTitle(text: name == "run_jxa" ? "Ran JavaScript" : "Ran AppleScript", code: source.map { truncatedLine($0, limit: 48) }, codeFull: source)
        case "open_url":
            guard let url = str("url") else { return ToolTitle(text: "Opened a page") }
            return ToolTitle(text: "Opened", code: truncatedLine(url, limit: 60), codeFull: url)
        case "browser_read_page":
            return ToolTitle(text: "Read the page in \(str("browser") ?? "the browser")")
        case "browser_fill":
            return ToolTitle(text: "Filled a field", code: str("selector").map { truncatedLine($0, limit: 40) }, codeFull: str("selector"))
        case "memory_search":
            return ToolTitle(text: str("query").map { "Searched memory for \(quoted($0))" } ?? "Searched memory")
        case "memory_remember":
            return ToolTitle(text: str("name").map { "Remembered \($0)" } ?? "Remembered a fact")
        case "remember_instruction":
            return ToolTitle(text: "Remembered an instruction")
        case "use_skill":
            let id = str("skill_id")
            // The loaded skill list may not hold this id (an older version); the result names the skill too.
            let fromResult = activity.result?.textContent.firstMatch(of: /^Following '([^']+)'/).map { String($0.1) }
            let skill = id.flatMap { naming.skillNames[$0] } ?? fromResult ?? (id.map { $0.count > 20 ? "a skill" : $0 })
            return ToolTitle(text: skill.map { $0 == "a skill" ? "Used a skill" : "Used skill \(quoted($0))" } ?? "Used a skill")
        case "find_skill":
            return ToolTitle(text: str("query").map { "Searched skills for \(quoted($0))" } ?? "Searched skills")
        case "learn_skill":
            return ToolTitle(text: str("name").map { "Learned skill \(quoted($0))" } ?? "Learned a skill")
        case "import_skills":
            return ToolTitle(text: str("path").map { "Imported skills from \(truncatedLine(abbreviatePath($0), limit: 50))" } ?? "Imported skills")
        case "delegate_task":
            return ToolTitle(text: str("title").map { "Delegated: \(truncatedLine($0, limit: 60))" } ?? "Delegated a task")
        case "code":
            return ToolTitle(text: str("request").map { "Coding: \(truncatedLine($0, limit: 60))" } ?? "Started a coding run")
        case "await_task":
            return ToolTitle(text: "Waited for a delegated task")
        case "ask_user":
            return ToolTitle(text: "Asked you a question")
        case "schedule_job":
            return ToolTitle(text: str("name").map { "Scheduled \(quoted($0))" } ?? "Scheduled a job")
        case "list_schedules":
            return ToolTitle(text: "Listed schedules")
        case "cancel_schedule":
            return ToolTitle(text: "Cancelled a schedule")
        case "share_file":
            let file = str("path") ?? str("file_name") ?? str("name")
            return ToolTitle(text: file.map { "Shared \(fileName(of: $0))" } ?? "Shared a file")
        // Claude Code's tools, in its coding runs.
        case "Read":
            return ToolTitle(text: str("file_path").map { "Read \(fileName(of: $0))" } ?? "Read a file")
        case "Edit", "MultiEdit":
            return ToolTitle(text: str("file_path").map { "Edited \(fileName(of: $0))" } ?? "Edited a file")
        case "Write":
            return ToolTitle(text: str("file_path").map { "Wrote \(fileName(of: $0))" } ?? "Wrote a file")
        case "NotebookEdit":
            return ToolTitle(text: str("notebook_path").map { "Edited \(fileName(of: $0))" } ?? "Edited a notebook")
        case "Bash":
            let command = str("command")
            return ToolTitle(text: str("description") ?? "Ran a command", code: command.map { truncatedLine($0, limit: 44) }, codeFull: command)
        case "Grep":
            return ToolTitle(text: str("pattern").map { "Searched for \(quoted($0))" } ?? "Searched the code")
        case "Glob":
            return ToolTitle(text: str("pattern").map { "Found files matching \(quoted($0))" } ?? "Found files")
        case "TodoWrite":
            return ToolTitle(text: "Updated the plan")
        case "WebFetch":
            return ToolTitle(text: str("url").map { "Read \(truncatedLine($0, limit: 50))" } ?? "Read a web page")
        case "WebSearch":
            return ToolTitle(text: str("query").map { "Searched the web for \(quoted($0))" } ?? "Searched the web")
        case "Task", "Agent":
            return ToolTitle(text: str("description").map { "Sub-agent: \(truncatedLine($0, limit: 50))" } ?? "Started a sub-agent")
        default:
            return ToolTitle(text: humanised(name))
        }
    }

    // MARK: Summary

    /// The one line shown under a collapsed card. Nil when there is nothing worth a line (a screenshot, a
    /// call still running).
    static func summary(for activity: ToolActivity) -> ToolSummary? {
        let status = activity.status
        guard let result = activity.result else {
            // No result yet: a denied or cancelled call still has the runtime's note.
            if let record = activity.record, status != .running, status != .pending, !record.resultSummary.isEmpty {
                return ToolSummary(text: truncatedLine(record.resultSummary, limit: 200), isError: status.isFailure)
            }
            return nil
        }
        let text = result.textContent
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let failed = status == .failed || result.isError

        switch activity.name {
        case "shell":
            let exitCode = lines.last.flatMap { line -> Int? in
                guard line.hasPrefix("[exit code "), line.hasSuffix("]") else { return nil }
                return Int(line.dropFirst("[exit code ".count).dropLast())
            }
            let content = lines.filter { !($0.hasPrefix("[exit code ") || $0 == "[stderr]" || $0.hasPrefix("[timed out")) }
            if let last = content.last {
                return ToolSummary(text: truncatedLine(last, limit: 200), isError: failed)
            }
            if lines.contains(where: { $0.hasPrefix("[timed out") }) { return ToolSummary(text: "Timed out", isError: true) }
            if let exitCode { return ToolSummary(text: exitCode == 0 ? "No output · exit code 0" : "exit code \(exitCode)", isError: failed) }
            return ToolSummary(text: "No output", isError: failed)
        case "screenshot":
            return failed ? lines.first.map { ToolSummary(text: truncatedLine($0, limit: 200), isError: true) } : nil
        default:
            break
        }

        if failed {
            return ToolSummary(text: truncatedLine(lines.first ?? "Failed", limit: 200), isError: true)
        }

        switch activity.name {
        case "list_directory":
            let count = lines.filter { !$0.hasPrefix("…[") }.count
            let extra = trailingCount(lines, suffix: " more entries]")
            let total = count + extra
            return ToolSummary(text: total == 0 ? "Empty directory" : "\(total.formatted()) item\(total == 1 ? "" : "s")")
        case "read_file":
            let body = lines.filter { !$0.hasPrefix("…[") }
            let total = body.count + trailingCount(lines, suffix: " more lines]")
            if total <= 1, let first = body.first {
                // A one-line file: show the line without its number.
                let stripped = first.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
                return ToolSummary(text: truncatedLine(stripped.isEmpty ? first : stripped, limit: 200))
            }
            return ToolSummary(text: "\(total.formatted()) lines")
        case "memory_search":
            let hits = lines.filter { $0.hasPrefix("- ") }.count
            if hits == 0, let first = lines.first { return ToolSummary(text: truncatedLine(first, limit: 200)) }
            return ToolSummary(text: "\(hits) hit\(hits == 1 ? "" : "s")")
        default:
            if let first = lines.first { return ToolSummary(text: truncatedLine(first, limit: 200)) }
            return activity.images.isEmpty ? ToolSummary(text: "No output") : nil
        }
    }

    /// The N in a trailing "…[N more entries]" marker.
    private static func trailingCount(_ lines: [String], suffix: String) -> Int {
        guard let marker = lines.last(where: { $0.hasPrefix("…[") && $0.hasSuffix(suffix) }) else { return 0 }
        return Int(marker.dropFirst(2).dropLast(suffix.count)) ?? 0
    }

    /// Shell output keeps its columns, so it scrolls sideways; everything else wraps.
    static func wrapsOutput(_ name: String) -> Bool {
        !["shell", "list_directory", "read_file", "run_applescript", "run_jxa", "ui_tree"].contains(name)
    }

    /// Pretty JSON for nested argument values.
    static func pretty(_ value: JSONValue) -> String {
        (try? String(decoding: JSONCodec.prettyEncoder.encode(value), as: UTF8.self)) ?? value.compactText
    }
}
