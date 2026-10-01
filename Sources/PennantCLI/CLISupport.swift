import PennantClientKit
import PennantCore
import Foundation

// What every command shares: printing, failing, connecting to the host, and describing what it sends back.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func out(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func resolveToken(_ options: CLIOptions) -> String? {
    if let t = options.token, !t.isEmpty { return t }
    if let saved = ClientCredentials.load(for: options.endpoint) { return saved.token }
    if options.host == "127.0.0.1" || options.host == "localhost" { return ClientCredentials.readLocalHostToken() }
    return nil
}

@MainActor
func connect(_ options: CLIOptions) async throws -> HostSession {
    let token = resolveToken(options)
    let endpoint = options.access.map { HostEndpoint.access($0) } ?? options.endpoint
    let credentials = ClientCredentials.load(for: endpoint)
    let session = HostSession(transport: WebSocketTransport(), endpoint: endpoint, token: token, clientID: credentials?.clientID ?? ClientCredentials.deviceClientID(), displayName: "pennant CLI", platform: "macos-cli")
    if options.access != nil { session.accessToken = ProcessInfo.processInfo.environment["PENNANT_ACCESS_TOKEN"] }
    session.connect()
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        switch session.connection {
        case .connected: return session
        case .failed(let reason):
            await session.disconnect()
            throw HostSessionError.hostError(code: "connect_failed", message: "\(reason) (host \(options.endpoint.id))")
        case .reconnecting:
            // One-shot tool: do not sit through the session's reconnect backoff.
            await session.disconnect()
            throw HostSessionError.hostError(code: "connect_failed", message: "could not reach the host at \(options.endpoint.id); is pennant-host running?")
        default: try await Task.sleep(for: .milliseconds(20))
        }
    }
    await session.disconnect()
    throw HostSessionError.timeout
}

func shortID(_ raw: String) -> String { String(raw.prefix(8)) }

func describe(_ task: TaskRecord) -> String {
    let reason = task.stateReason.isEmpty ? "" : " — \(task.stateReason)"
    return "\(shortID(task.id.rawValue))  \(task.state.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) \(task.title)\(reason)"
}

func describe(_ agent: AgentProfile) -> String {
    let line = agent.statusLine.isEmpty ? "" : " — \(agent.statusLine)"
    let glyph = agent.avatar.hasPrefix("shape:") ? "◉" : agent.avatar
    return "\(glyph) \(agent.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(agent.status.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) \(agent.role)\(line)"
}

func describe(_ event: HostEvent) -> String {
    let stamp = ISO8601.format(event.at)
    switch event.payload {
    case .hostStatus(let h): return "\(stamp) host \(h.hostName) tasks=\(h.activeTaskCount) clients=\(h.connectedClients) inference=\(h.inferenceReachable ? "ok" : "down")"
    case .agentUpserted(let a): return "\(stamp) agent \(a.name) \(a.status.rawValue) \(a.statusLine)"
    case .agentRemoved(let id): return "\(stamp) agent removed \(id)"
    case .conversationsRemoved(let ids): return "\(stamp) \(ids.count) conversation(s) deleted"
    case .conversationUpserted(let c): return "\(stamp) conversation \(shortID(c.id.rawValue)) \(c.title)"
    case .messageAppended(let m): return "\(stamp) message \(m.role.rawValue) \(shortID(m.id.rawValue)) \(m.text.prefix(120))"
    case .messageDelta(let d): return "\(stamp) delta \(shortID(d.messageID.rawValue)) \((d.textDelta ?? d.reasoningDelta ?? d.toolCall?.name ?? "").prefix(80))"
    case .messageFinalized(let m): return "\(stamp) message done \(shortID(m.id.rawValue)) \(m.text.prefix(120))"
    case .taskUpserted(let t): return "\(stamp) task \(describe(t))"
    case .taskTransition(let tr): return "\(stamp) task \(shortID(tr.taskID.rawValue)) \(tr.from.rawValue) -> \(tr.to.rawValue) \(tr.reason)"
    case .toolRecordUpserted(let r): return "\(stamp) tool \(r.call.name) \(r.status.rawValue) \(r.resultSummary.prefix(100))"
    case .checkpointSaved(let c): return "\(stamp) checkpoint \(shortID(c.taskID.rawValue)) next: \(c.nextStep.prefix(100))"
    case .desktopStatus(let d): return "\(stamp) desktop owner=\(d.owner) paused=\(d.pausedByHuman) queue=\(d.queue.count)"
    case .memoryEntityUpserted(let e): return "\(stamp) memory entity \(e.kind.rawValue) \(e.name) [\(e.status.rawValue)]"
    case .memoryRelationUpserted(let r): return "\(stamp) memory relation \(r.relation)"
    case .preferenceUpserted(let p): return "\(stamp) preference v\(p.version) \(p.text.prefix(100))"
    case .memoryForgotten(let kind, let id): return "\(stamp) forgotten \(kind) \(id)"
    case .skillUpserted(let s): return "\(stamp) skill \(s.name) v\(s.version) \(s.status.rawValue)"
    case .skillRemoved(let id): return "skill removed \(id.rawValue.prefix(8))"
    case .scheduleUpserted(let job): return "schedule \(job.name): \(job.enabled ? "next " + (job.nextRunAt.map { ISO8601.format($0) } ?? "-") : "disabled")\(job.lastOutcome.map { " · " + String($0.prefix(60)) } ?? "")"
    case .scheduleRemoved(let id): return "schedule removed \(id.rawValue.prefix(8))"
    case .messagesRemoved(_, let ids): return "\(ids.count) message(s) removed"
    case .goalUpserted(let g): return "goal \(g.title): \(g.status.rawValue)"
    case .goalItemUpserted(let i): return "goal item \(i.title): \(i.state.rawValue)"
    case .goalRemoved(let id): return "goal removed \(id.rawValue.prefix(8))"
    case .teachingUpdated(let t): return "\(stamp) teaching \(t.map { "\($0.isRecording ? "recording" : "stopped") \($0.events.count) step(s)" } ?? "ended")"
    case .mcpServerStatus(let s): return "\(stamp) mcp \(s.config.name) \(s.state.rawValue) tools=\(s.toolCount) auth=\(s.authState.rawValue)\(s.authDetail.map { " (\($0))" } ?? "")"
    case .notice(let level, _, let text): return "\(stamp) \(level.rawValue): \(text)"
    }
}

/// Opens a raw transport and returns the inbound stream; used for signing in and watching.
func openRaw(_ options: CLIOptions) async throws -> (WebSocketTransport, AsyncStream<TransportInbound>) {
    let transport = WebSocketTransport()
    do {
        let inbound = try await transport.open(endpoint: options.endpoint)
        return (transport, inbound)
    } catch {
        throw HostSessionError.hostError(code: "connect_failed", message: "\(error) (host \(options.endpoint.id)); is pennant-host running?")
    }
}

func replyError(_ reply: ReplyBody) -> String {
    if case .error(let code, let message) = reply { return "\(code): \(message)" }
    return "Unexpected reply"
}

func openInBrowser(_ url: URL) {
    #if os(macOS)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [url.absoluteString]
    try? p.run()
    #endif
}
