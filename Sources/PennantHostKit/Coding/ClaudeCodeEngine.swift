import PennantCore
import Foundation

/// Runs the Claude Code CLI headless (`claude -p --output-format stream-json`) for a coding agent and turns its event
/// stream into typed events. Each run is one message to one session; `--resume` continues the conversation's session,
/// so the CLI keeps its own context. Permission prompts go to Pennant through `pennant-host coder-permission`, an MCP
/// tool the CLI calls instead of asking on a terminal.
struct ClaudeCodeEngine: Sendable {
    enum Event: Sendable {
        /// The session started (or resumed): its id, and the model the CLI chose.
        case started(sessionID: String, model: String?)
        /// One assistant turn: text and tool calls, in order.
        case assistant([Piece])
        /// Results of tool calls, by call id.
        case toolResults([(id: String, text: String, isError: Bool)])
        /// The run ended.
        case finished(Finish)
    }

    enum Piece: Sendable {
        case text(String)
        case thinking(String)
        case toolUse(id: String, name: String, input: JSONValue)
    }

    struct Finish: Sendable {
        var text: String
        var isError: Bool
        var costUSD: Double?
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
    }

    struct NotInstalled: Error, CustomStringConvertible {
        var description: String { "Claude Code isn't installed on this Mac (no `claude` on the PATH or in ~/.local/bin). Install it from claude.com/code, sign in once in a terminal, then try again." }
    }

    /// Commands that only read, allowed without a card. Everything else Bash runs asks first.
    /// GitHub reads (PRs, issues, checks, runs) count too; `gh api` doesn't, since it can write.
    static let readOnlyCommands = ["git status", "git diff", "git log", "git show", "git branch", "ls", "pwd", "cat", "head", "tail", "wc", "rg", "grep", "which", "tree",
                                   "gh pr list", "gh pr view", "gh pr status", "gh pr checks", "gh pr diff", "gh issue list", "gh issue view",
                                   "gh repo view", "gh repo list", "gh run list", "gh run view", "gh search prs", "gh search issues"]

    let executable: URL

    /// The `claude` executable: a configured path, the PATH, or the usual install places.
    static func locate(configured: String? = nil) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let configured, !configured.isEmpty { candidates.append((configured as NSString).expandingTildeInPath) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/claude" }
        candidates += ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map { ($0 as NSString).expandingTildeInPath }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func arguments(prompt: String, sessionID: String?, mcpConfig: URL?, mode: CodingMode = .acceptEdits, model: String? = nil, instructions: String? = nil) -> [String] {
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", mode.rawValue]
        if let model, !model.isEmpty { args += ["--model", model] }
        if let instructions, !instructions.isEmpty { args += ["--append-system-prompt", instructions] }
        if let mcpConfig {
            args += ["--mcp-config", mcpConfig.path, "--permission-prompt-tool", "mcp__pennant__approve"]
        }
        args += ["--allowedTools"] + Self.readOnlyCommands.map { "Bash(\($0):*)" }
        // Pennant's own tools ask on their own terms (a message to someone not allowed waits on a card).
        if mcpConfig != nil { args += ["mcp__pennant__send_message", "mcp__pennant__list_contacts"] }
        if let sessionID { args += ["--resume", sessionID] }
        return args
    }

    /// Runs one message and calls `onEvent` for each event as it arrives. Cancelling the task stops the CLI.
    /// `environment` is laid over the host's (the session's GitHub identity); `instructions` go after Claude Code's own.
    func run(prompt: String, in directory: URL, sessionID: String?, mcpConfig: URL?, mode: CodingMode = .acceptEdits, model: String? = nil,
             instructions: String? = nil, environment: [String: String] = [:],
             onEvent: @escaping @Sendable (Event) async -> Void) async throws -> Finish {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(prompt: prompt, sessionID: sessionID, mcpConfig: mcpConfig, mode: mode, model: model, instructions: instructions)
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        // A host started by the app has a thin PATH; the CLI and the tools it runs need the usual places.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", ("~/.local/bin" as NSString).expandingTildeInPath]
        env["PATH"] = (extra + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
        // Approval cards can wait hours; the permission tool must not time out meanwhile.
        env["MCP_TOOL_TIMEOUT"] = "86400000"
        env.merge(environment) { _, new in new }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        var finish: Finish?
        var lastError = ""
        try await withTaskCancellationHandler {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8), let event = Self.parse(data) else { continue }
                if case .finished(let f) = event { finish = f }
                await onEvent(event)
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        if let errData = try? err.fileHandleForReading.readToEnd(), let text = String(data: errData, encoding: .utf8) {
            lastError = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let finish { return finish }
        throw ToolError.failed("Claude Code stopped without finishing (exit \(process.terminationStatus))\(lastError.isEmpty ? "" : ": " + String(lastError.suffix(400)))")
    }

    /// One line of the stream. Lines that don't matter to the chat (hooks, rate-limit notices) are skipped.
    static func parse(_ data: Data) -> Event? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = obj["type"] as? String else { return nil }
        switch type {
        case "system":
            guard obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String else { return nil }
            return .started(sessionID: sid, model: obj["model"] as? String)
        case "assistant":
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            let pieces: [Piece] = content.compactMap { c in
                switch c["type"] as? String {
                case "text": return (c["text"] as? String).map(Piece.text)
                case "thinking": return (c["thinking"] as? String).map(Piece.thinking)
                case "tool_use":
                    guard let id = c["id"] as? String, let name = c["name"] as? String else { return nil }
                    let input = (try? JSONSerialization.data(withJSONObject: c["input"] ?? [:])).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                    return .toolUse(id: id, name: name, input: input)
                default: return nil
                }
            }
            return pieces.isEmpty ? nil : .assistant(pieces)
        case "user":
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            let results: [(id: String, text: String, isError: Bool)] = content.compactMap { c in
                guard c["type"] as? String == "tool_result", let id = c["tool_use_id"] as? String else { return nil }
                return (id, Self.text(of: c["content"]), (c["is_error"] as? Bool) ?? false)
            }
            return results.isEmpty ? nil : .toolResults(results)
        case "result":
            let usage = obj["usage"] as? [String: Any] ?? [:]
            func int(_ k: String) -> Int { (usage[k] as? Int) ?? Int((usage[k] as? Double) ?? 0) }
            return .finished(Finish(
                text: (obj["result"] as? String) ?? "",
                isError: (obj["is_error"] as? Bool) ?? (obj["subtype"] as? String != "success"),
                costUSD: obj["total_cost_usd"] as? Double,
                inputTokens: int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens"),
                cachedInputTokens: int("cache_read_input_tokens"),
                outputTokens: int("output_tokens")))
        default:
            return nil
        }
    }

    /// A tool result's content is a string or a list of text blocks.
    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }
}
