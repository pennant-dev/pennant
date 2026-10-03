import PennantClientKit
import PennantCore
import Foundation

// Work: threads and tasks, sending and answering, the desktop, approvals, files, and a conversation's context.

@MainActor
func approvalCommand(_ options: CLIOptions) async throws {
    guard options.args.count >= 2, let verdict = ["approve": ApprovalDecision.Verdict.approve, "changes": .requestChanges, "reject": .reject][options.args[1]] else {
        fail("Usage: pennant approval <id> approve|changes|reject [comment]")
    }
    let session = try await connect(options)
    let comment = options.args.dropFirst(2).joined(separator: " ")
    try await session.decideApproval(ApprovalDecision(approvalID: options.args[0], verdict: verdict, editedText: nil, comment: comment.isEmpty ? nil : comment))
    out("Sent.")
    await session.disconnect()
}

/// pennant tool <name> [json]: one of Pennant's tools, run by hand. Images in the result are saved in the current folder.
@MainActor
func toolCommand(_ options: CLIOptions) async throws {
    guard let name = options.args.first else { fail("Usage: pennant tool <name> [json arguments]") }
    let raw = options.args.dropFirst().joined(separator: " ")
    let arguments: JSONValue
    if raw.isEmpty {
        arguments = .object([:])
    } else {
        guard let parsed = try? JSONValue.from(Data(raw.utf8)) else { fail("The arguments aren't JSON: \(raw)") }
        arguments = parsed
    }
    let session = try await connect(options)
    let reply = try await session.send(.runTool(name: name, arguments: arguments), timeout: 180)
    guard case .coderToolResult(let text, let isError) = reply else {
        await session.disconnect()
        if case .error(_, let message) = reply { fail(message) }
        fail("Unexpected reply: \(reply)")
    }
    out(text)
    for match in text.matches(of: /\[image: artifact ([A-Za-z0-9-]+)\]/) {
        let id = String(match.1)
        if case .artifact(_, let base64) = try await session.send(.getArtifact(ArtifactID(id))), let data = Data(base64Encoded: base64) {
            let file = FileManager.default.currentDirectoryPath + "/\(id).jpg"
            try data.write(to: URL(fileURLWithPath: file))
            out("saved \(file)")
        }
    }
    await session.disconnect()
    if isError { exit(1) }
}

/// pennant heartbeat [on|off|every <minutes>|cap <n>]: Pennant checking in on its own.
@MainActor
func heartbeatCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    var c = try await session.getConfig().config
    let args = options.args.map { $0.lowercased() }
    switch args.first {
    case nil: break
    case "on": c.heartbeat.enabled = true
    case "off": c.heartbeat.enabled = false
    case "every" where args.count > 1:
        guard let minutes = Int(args[1].trimmingCharacters(in: CharacterSet(charactersIn: "m"))), minutes >= 5 else {
            await session.disconnect(); fail("Usage: pennant heartbeat every <minutes> (at least 5)")
        }
        c.heartbeat.intervalMinutes = minutes
    case "cap" where args.count > 1:
        guard let n = Int(args[1]), n >= 1 else { await session.disconnect(); fail("Usage: pennant heartbeat cap <check-ins a day>") }
        c.heartbeat.maxTurnsPerDay = n
    default:
        await session.disconnect(); fail("Usage: pennant heartbeat [on|off|every <minutes>|cap <n>]")
    }
    if args.first != nil { _ = try await session.updateConfig(c) }
    await session.disconnect()
    let h = c.heartbeat
    out(h.enabled ? "Pennant checks in every \(h.intervalMinutes) minutes, and stops to think at most \(h.maxTurnsPerDay) times a day. Goals run on it." : "Heartbeat off: goals run on their own schedules.")
}

@MainActor
func threadsCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    // pennant threads close-after <days|never>: how long a quiet thread stays in the list.
    if options.args.first == "close-after", options.args.count > 1 {
        let arg = options.args[1].lowercased()
        let days = arg == "never" ? nil : Int(arg)
        guard arg == "never" || (days ?? 0) > 0 else { await session.disconnect(); fail("Usage: pennant threads close-after <days|never>") }
        var c = try await session.getConfig().config
        c.autoCloseIdleDays = days
        _ = try await session.updateConfig(c)
        await session.disconnect()
        out(days.map { "Quiet threads close after \($0) day\($0 == 1 ? "" : "s")." } ?? "Quiet threads stay until you close them.")
        return
    }
    let all = session.state.conversations.filter { $0.parentID == nil && session.state.agent($0.agentID)?.kind == .persistent }
    let open = all.filter { !$0.isClosed }.sorted { $0.updatedAt > $1.updatedAt }
    out("\(open.count) open, \(all.count - open.count) closed")
    for c in open.prefix(40) {
        let who = session.state.agent(c.agentID)?.name ?? "?"
        let mark = session.state.conversationNeedsUser(c.id) ? "!" : " "
        out("\(mark) [\(c.id.rawValue.prefix(8))] \(ISO8601.format(c.updatedAt)) \(who): \(c.title.isEmpty ? c.preview : c.title)")
    }
    await session.disconnect()
}

@MainActor
func tasksCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    for t in session.state.tasks.sorted(by: { $0.updatedAt > $1.updatedAt }) { out(describe(t)) }
    await session.disconnect()
}

@MainActor
func sendCommand(_ options: CLIOptions) async throws {
    // pennant send [--new | --conversation <id>] <text…>
    var sendArgs = options.args
    func take(_ flag: String) -> String? {
        guard let i = sendArgs.firstIndex(of: flag), i + 1 < sendArgs.count else { return nil }
        let v = sendArgs[i + 1]; sendArgs.removeSubrange(i...(i + 1)); return v
    }
    // --conversation <id or prefix>: into that conversation (a task already working there takes it as a note).
    let conversationArg = take("--conversation")
    // --new: a conversation of its own (the latest one may be a shared Teams chat, where replies are posted).
    let wantsNew = sendArgs.contains("--new")
    sendArgs.removeAll { $0 == "--new" }
    guard !sendArgs.isEmpty else { fail("Usage: pennant send [--new | --conversation <id>] <text…>") }
    let text = sendArgs.joined(separator: " ")
    let session = try await connect(options)
    guard let agent = session.state.leadAgent else { await session.disconnect(); fail("There's no agent yet.") }
    // By default, the Pennant chat (on a host from before it, the latest conversation).
    var conversationID = wantsNew ? nil : (session.state.mainConversation?.id ?? session.state.conversations(for: agent.id).first?.id)
    if let conversationArg {
        guard let match = session.state.conversations(for: agent.id).first(where: { $0.id.rawValue.hasPrefix(conversationArg) }) else {
            await session.disconnect()
            fail("No conversation starts with \(conversationArg).")
        }
        conversationID = match.id
    }
    let (_, convID, taskID) = try await session.sendMessage(to: agent.id, conversationID: conversationID, text: text)
    out("[task \(shortID(taskID.rawValue)) started]")
    var printed: [MessageID: Int] = [:]
    var printedCalls: Set<ToolCallID> = []
    var seenRecords: Set<ToolRecordID> = []
    var lastNoticeCount = session.state.notices.count
    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
        let messages = (session.state.messages[convID] ?? []).filter { $0.role == .assistant && ($0.taskID == taskID || $0.taskID == nil) }
        for m in messages {
            let full = m.text
            let already = printed[m.id] ?? 0
            if full.count > already {
                write(String(full.dropFirst(already)))
                printed[m.id] = full.count
            }
            for call in m.toolCalls where !printedCalls.contains(call.id) {
                printedCalls.insert(call.id)
                out("\n[tool] \(call.name) \(call.arguments.compactText.prefix(200))")
            }
        }
        for r in session.state.toolRecords[taskID] ?? [] where !seenRecords.contains(r.id) && r.status != .intended && r.status != .running {
            seenRecords.insert(r.id)
            out("[tool \(r.call.name) \(r.status.rawValue)] \(r.resultSummary.prefix(200))")
        }
        if session.state.notices.count > lastNoticeCount {
            for n in session.state.notices[lastNoticeCount...] { out("[\(n.level.rawValue)] \(n.text)") }
            lastNoticeCount = session.state.notices.count
        }
        if let t = session.state.task(taskID), t.state.isTerminal {
            out("\n[task \(t.state.rawValue)\(t.stateReason.isEmpty ? "" : ": \(t.stateReason)")]")
            if let summary = t.resultSummary, !summary.isEmpty { out(summary) }
            break
        }
        if let t = session.state.task(taskID), t.state == .waitingForUser {
            out("\n[task is waiting for you: \(t.stateReason)]  Reply with: pennant answer \(taskID) <text>")
            break
        }
        try await Task.sleep(for: .milliseconds(80))
    }
    await session.disconnect()
}

@MainActor
func answerCommand(_ options: CLIOptions) async throws {
    guard options.args.count >= 2 else { fail("Usage: pennant answer <taskID> <text…>") }
    let session = try await connect(options)
    try await session.answerQuestion(taskID: TaskID(options.args[0]), text: options.args.dropFirst().joined(separator: " "))
    out("Answer delivered")
    await session.disconnect()
}

@MainActor
func taskControlCommand(_ options: CLIOptions) async throws {
    guard let id = options.args.first else { fail("Usage: pennant \(options.command) <taskID>") }
    let session = try await connect(options)
    let taskID = session.state.tasks.first { $0.id.rawValue.hasPrefix(id) }?.id ?? TaskID(id)
    switch options.command {
    case "pause": try await session.pauseTask(taskID)
    case "resume": try await session.resumeTask(taskID)
    default: try await session.cancelTask(taskID)
    }
    out("\(options.command) sent for \(shortID(taskID.rawValue))")
    await session.disconnect()
}

@MainActor
func takeoverCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    try await session.takeoverDesktop()
    out("You have desktop control. Run `pennant release` to hand it back.")
    await session.disconnect()
}

@MainActor
func releaseCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    try await session.releaseDesktop()
    out("Desktop control released.")
    await session.disconnect()
}

@MainActor
func watchCommand(_ options: CLIOptions) async throws {
    let (transport, inbound) = try await openRaw(options)
    let hello = ClientHello(clientID: ClientCredentials.deviceClientID(), displayName: "pennant watch", platform: "macos-cli", appVersion: PennantVersion.string, token: resolveToken(options))
    try await transport.send(.command(ClientCommand(body: .hello(hello))))
    for await item in inbound {
        switch item {
        case .message(.reply(let reply)):
            if case .error(let code, let message) = reply.result { fail("\(code): \(message)") }
            if case .welcome(let snapshot) = reply.result { out("connected to \(snapshot.host.hostName); \(snapshot.agents.count) agents, latest event \(snapshot.latestEventSeq)") }
        case .message(.event(let event)):
            out(describe(event))
        case .closed(let reason):
            fail("connection closed: \(reason)")
        default:
            break
        }
    }
}

@MainActor
func artifactCommand(_ options: CLIOptions) async throws {
    guard options.args.count >= 3, options.args[0] == "save" else { fail("Usage: pennant artifact save <id|prefix> <out-path>") }
    let ident = options.args[1]
    let session = try await connect(options)
    var id = ArtifactID(ident)
    if ident.count < 36 {
        // A prefix: look through the files shared into every conversation, newest first.
        var matches: [ArtifactID: String] = [:]
        for conversation in session.state.conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            _ = try await session.loadMessages(conversationID: conversation.id, limit: 200)
            for message in session.state.messages[conversation.id] ?? [] {
                for part in message.parts {
                    if case .file(let ref) = part, ref.artifactID.rawValue.hasPrefix(ident) { matches[ref.artifactID] = ref.fileName }
                }
            }
        }
        guard matches.count == 1, let only = matches.first else {
            await session.disconnect()
            if matches.isEmpty { fail("No shared file has an id starting with '\(ident)'. Pass the full artifact id for other artifacts.") }
            fail("Ambiguous prefix '\(ident)': " + matches.map { "\(shortID($0.key.rawValue)) \($0.value)" }.sorted().joined(separator: ", "))
        }
        id = only.key
    }
    let (record, data) = try await session.artifact(id)
    await session.disconnect()
    var url = URL(fileURLWithPath: (options.args[2] as NSString).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { url.appendPathComponent(record.fileName) }
    try data.write(to: url, options: .atomic)
    out("Saved \(record.fileName) (\(data.count) bytes, \(record.mimeType)) to \(url.path)")
}

@MainActor
func contextCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    guard let agent = session.state.leadAgent, let conversation = session.state.conversations(for: agent.id).first else { await session.disconnect(); fail("There's no conversation yet") }
    var task = session.state.tasks.filter { $0.conversationID == conversation.id }.sorted { $0.updatedAt > $1.updatedAt }.first
    if options.command == "compact" {
        let r = try await session.send(.compactConversation(conversation.id), timeout: 180)
        guard case .task(let t) = r else { await session.disconnect(); fail("Unexpected reply") }
        task = t
        out("Compacted '\(conversation.title)'.")
    }
    let window = task?.usage.contextWindowTokens ?? session.state.host?.contextWindowTokens ?? 0
    let used = task?.usage.lastContextTokens ?? 0
    let pct = window > 0 ? Int(Double(used) / Double(window) * 100) : 0
    out("Conversation: \(conversation.title)")
    out("Context: \(used) / \(window) tokens (\(pct)%)")
    if let t = task { out("Task: \(t.title) [\(t.state.rawValue)] compactions=\(t.usage.compactions)\(t.usage.lastCompactedAt.map { " last=\(ISO8601.format($0))" } ?? "")") }
    let cps = try await session.send(.getConversationCheckpoints(conversation.id))
    if case .checkpoints(let list) = cps, let last = list.last {
        out("Latest checkpoint \(ISO8601.format(last.createdAt)): next step: \(last.nextStep)")
        out(String(last.historySummary.prefix(600)))
    }
    await session.disconnect()
}
