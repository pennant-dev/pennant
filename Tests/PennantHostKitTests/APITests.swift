import PennantClientKit
import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

// MARK: - Fakes

final class FakeAPIDelegate: HostAPIDelegate, @unchecked Sendable {
    let agent = AgentProfile(name: "Nova", role: "Assistant")
    let lock = NSLock()
    var clientsChanges: [(Int, Int)] = []
    var handled: [CommandBody] = []
    var frameCount = 3

    func authenticate(token: String?) async -> Bool {
        token == "t"
    }

    func snapshot() async -> StateSnapshot {
        StateSnapshot(
            host: HostInfo(hostName: "Test", version: "0", startedAt: Date(), mode: .everyday, inferenceEndpoint: "", inferenceModel: "", inferenceReachable: false, databasePath: "", activeTaskCount: 0, connectedClients: 1),
            agents: [agent], tasks: [], conversations: [], desktop: DesktopStatus(), mcpServers: [], latestEventSeq: 0)
    }

    func handle(_ body: CommandBody, from client: ConnectedClient) async -> ReplyBody {
        // A press takes a while to apply, so input run side by side would finish out of order.
        if case .remoteInput(.pointerDown) = body { try? await Task.sleep(for: .milliseconds(150)) }
        lock.withLock { handled.append(body) }
        switch body {
        case .remoteInput: return .ok
        case .listSchedules: return .schedules([])
        default: return .error(code: "unsupported", message: "not in fake")
        }
    }

    /// Speech: each request comes back as three pieces of audio and a last, empty one. Stops are counted by connection.
    var speechStops: [UUID] = []

    func speak(_ request: SpeechRequest, connection: UUID, send: @escaping VoiceService.Sink) async throws {
        guard request.voice == "penny" else { throw VoiceService.VoiceError.unavailable(request.voice) }
        for piece in 0 ..< 3 {
            send(SpeechChunkHeader(speechID: request.id, sampleRate: 24_000, final: false), [Float](repeating: Float(piece) / 4, count: 480))
        }
        send(SpeechChunkHeader(speechID: request.id, sampleRate: 24_000, final: true), [])
    }

    func stopSpeaking(connection: UUID) async {
        lock.withLock { speechStops.append(connection) }
    }

    /// Endless streams (a real capture never ends by itself) and how many of them are still running.
    var endless = false
    var liveStreams = 0

    func screenFrames(options: ScreenStreamOptions) async -> AsyncStream<(ScreenFrameHeader, Data)> {
        if endless {
            lock.withLock { liveStreams += 1 }
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let pump = Task {
                    var seq: Int64 = 0
                    while !Task.isCancelled {
                        seq += 1
                        continuation.yield((ScreenFrameHeader(sequence: seq, width: 4, height: 4, owner: .nobody), Data([0xFF, 0xD8, 0xFF, 0xD9])))
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                continuation.onTermination = { [self] _ in
                    pump.cancel()
                    lock.withLock { liveStreams -= 1 }
                }
            }
        }
        let count = frameCount
        return AsyncStream { continuation in
            for i in 0..<count {
                continuation.yield((ScreenFrameHeader(sequence: Int64(i), width: 4, height: 4, owner: .nobody), Data([0xFF, 0xD8, 0xFF, 0xD9])))
            }
            continuation.finish()
        }
    }

    func clientsChanged(_ clients: [ConnectedClient], streaming: Int) async {
        lock.withLock { clientsChanges.append((clients.count, streaming)) }
    }
}

/// Just enough store for the API server: an in-memory event log. Everything else is inert.
final class APITestStore: StoreProtocol, @unchecked Sendable {
    let lock = NSLock()
    var events: [HostEvent] = []

    func appendEvent(_ payload: EventPayload) async throws -> HostEvent {
        lock.withLock {
            let event = HostEvent(seq: EventSeq(events.count + 1), payload: payload)
            events.append(event)
            return event
        }
    }
    func events(afterSeq: EventSeq, limit: Int) async throws -> [HostEvent] { lock.withLock { Array(events.filter { $0.seq > afterSeq }.prefix(limit)) } }
    func latestEventSeq() async throws -> EventSeq { lock.withLock { events.last?.seq ?? 0 } }
    func upsertAgent(_ agent: AgentProfile) async throws {}
    func deleteConversations(_ ids: [ConversationID]) async throws {}
    func agent(_ id: AgentID) async throws -> AgentProfile? { nil }
    func listAgents(includeRetired: Bool) async throws -> [AgentProfile] { [] }
    func upsertConversation(_ conversation: Conversation) async throws {}
    func conversation(_ id: ConversationID) async throws -> Conversation? { nil }
    func mutateConversation(_ id: ConversationID, _ change: @Sendable (inout Conversation) -> Void) async throws -> Conversation? { nil }
    func listConversations(agentID: AgentID) async throws -> [Conversation] { [] }
    func appendMessage(_ message: Message) async throws {}
    func updateMessage(_ message: Message) async throws {}
    func message(_ id: MessageID) async throws -> Message? { nil }
    func listMessages(conversationID: ConversationID, before: MessageID?, limit: Int) async throws -> [Message] { [] }
    func messagesAfter(conversationID: ConversationID, after: MessageID?, limit: Int) async throws -> [Message] { [] }
    func searchMessages(text: String, agentID: AgentID?, limit: Int) async throws -> [Message] { [] }
    func upsertTask(_ task: TaskRecord) async throws {}
    func task(_ id: TaskID) async throws -> TaskRecord? { nil }
    func listTasks(agentID: AgentID?, includeFinished: Bool) async throws -> [TaskRecord] { [] }
    func recordTransition(_ transition: TaskTransition) async throws {}
    func childTasks(parentTaskID: TaskID) async throws -> [TaskRecord] { [] }
    func upsertToolRecord(_ record: ToolRecord) async throws {}
    func toolRecords(taskID: TaskID) async throws -> [ToolRecord] { [] }
    func saveCheckpoint(_ checkpoint: Checkpoint) async throws {}
    func latestCheckpoint(conversationID: ConversationID) async throws -> Checkpoint? { nil }
    func upsertSchedule(_ job: ScheduledJob) async throws {}
    func schedule(_ id: ScheduleID) async throws -> ScheduledJob? { nil }
    func listSchedules() async throws -> [ScheduledJob] { [] }
    func deleteSchedule(_ id: ScheduleID) async throws {}
    func dueSchedules(before date: Date) async throws -> [ScheduledJob] { [] }
    func putArtifact(_ record: ArtifactRecord, data: Data) async throws {}
    func artifactData(_ id: ArtifactID) async throws -> Data? { nil }
    func upsertEntity(_ entity: MemoryEntity) async throws {}
    func entity(_ id: MemoryEntityID) async throws -> MemoryEntity? { nil }
    func findEntities(name: String, kind: MemoryEntityKind?, scopes: [String]) async throws -> [MemoryEntity] { [] }
    func listEntities(kind: MemoryEntityKind?, scope: String?, includeInactive: Bool, limit: Int) async throws -> [MemoryEntity] { [] }
    func upsertRelation(_ relation: MemoryRelation) async throws {}
    func relations(entityID: MemoryEntityID, includeInactive: Bool) async throws -> [MemoryRelation] { [] }
    func upsertPreference(_ preference: Preference) async throws {}
    func preference(_ id: PreferenceID) async throws -> Preference? { nil }
    func listPreferences(scopes: [String]?, includeInactive: Bool) async throws -> [Preference] { [] }
    func searchEntities(text: String, scopes: [String], includeInactive: Bool, limit: Int) async throws -> [(MemoryEntity, Double)] { [] }
    func searchPreferences(text: String, scopes: [String], limit: Int) async throws -> [(Preference, Double)] { [] }
    func forgetEntity(_ id: MemoryEntityID) async throws {}
    func forgetRelation(_ id: MemoryRelationID) async throws {}
    func forgetPreference(_ id: PreferenceID) async throws {}
    func putEmbedding(kind: String, itemID: String, vector: [Float]) async throws {}
    func embeddedItemIDs(kind: String) async throws -> Set<String> { [] }
    func clearEmbeddings() async throws {}
    func nearestEmbeddings(kind: String, vector: [Float], limit: Int) async throws -> [(itemID: String, similarity: Double)] { [] }
    func upsertSkill(_ skill: Skill) async throws {}
    func skill(_ id: SkillID) async throws -> Skill? { nil }
    func listSkills(includeDisabled: Bool) async throws -> [Skill] { [] }
    func searchSkills(text: String, limit: Int) async throws -> [Skill] { [] }
    func upsertMCPServer(_ config: MCPServerConfig) async throws {}
    func listMCPServers() async throws -> [MCPServerConfig] { [] }
    func removeMCPServer(_ id: MCPServerID) async throws {}
    func appendUsage(_ record: UsageRecord) async throws {}
    func setSetting(_ key: String, value: String) async throws {}
    func setting(_ key: String) async throws -> String? { nil }
}

/// Collects inbound transport traffic so tests can wait for specific items.
actor InboundCollector {
    private var items: [TransportInbound] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<TransportInbound>) {
        task = Task {
            for await item in stream { self.append(item) }
        }
    }

    private func append(_ item: TransportInbound) { items.append(item) }


    func wait(timeout: TimeInterval = 5, _ predicate: @Sendable (TransportInbound) -> Bool) async -> TransportInbound? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = items.first(where: predicate) { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func reply(for id: CommandID, timeout: TimeInterval = 5) async -> ReplyBody? {
        let item = await wait(timeout: timeout) {
            if case .message(.reply(let r)) = $0, r.commandID == id { return true }
            return false
        }
        if case .message(.reply(let r))? = item { return r.result }
        return nil
    }

    func event(timeout: TimeInterval = 5, _ predicate: @Sendable (HostEvent) -> Bool) async -> HostEvent? {
        let item = await wait(timeout: timeout) {
            if case .message(.event(let e)) = $0 { return predicate(e) }
            return false
        }
        if case .message(.event(let e))? = item { return e }
        return nil
    }

    /// The pieces of speech received so far.
    var speech: [(SpeechChunkHeader, [Float])] {
        items.compactMap { if case .speech(let h, let s) = $0 { return (h, s) }; return nil }
    }

    /// The screen frames received so far, by number.
    var frameNumbers: [Int64] {
        items.compactMap { if case .screenFrame(let h, _) = $0 { return h.sequence }; return nil }
    }

    func frame(timeout: TimeInterval = 5) async -> (ScreenFrameHeader, Data)? {
        let item = await wait(timeout: timeout) {
            if case .screenFrame = $0 { return true }
            return false
        }
        if case .screenFrame(let h, let d)? = item { return (h, d) }
        return nil
    }

    func closed(timeout: TimeInterval = 5) async -> String? {
        let item = await wait(timeout: timeout) {
            if case .closed = $0 { return true }
            return false
        }
        if case .closed(let reason)? = item { return reason }
        return nil
    }

}

// MARK: - Tests

final class APITests: XCTestCase {
    var server: HostAPIServer!
    var delegate: FakeAPIDelegate!
    var bus: EventBus!
    var store: APITestStore!

    override func setUp() async throws {
        delegate = FakeAPIDelegate()
        bus = EventBus()
        store = APITestStore()
        server = HostAPIServer(config: HostConfig.API(port: 0, listenOnNetwork: false, advertiseBonjour: false), delegate: delegate, eventBus: bus, store: store, hostName: "TestHost")
        try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
    }

    private func openClient() async throws -> (WebSocketTransport, InboundCollector) {
        let port = await server.port
        XCTAssertGreaterThan(port, 0)
        let transport = WebSocketTransport()
        let inbound = try await transport.open(endpoint: HostEndpoint(host: "127.0.0.1", port: port))
        let collector = InboundCollector()
        await collector.start(inbound)
        return (transport, collector)
    }

    private func hello(token: String?, lastEventSeq: EventSeq = 0) -> ClientCommand {
        ClientCommand(body: .hello(ClientHello(clientID: ClientID(), displayName: "test", platform: "xctest", appVersion: "0", lastEventSeq: lastEventSeq, token: token)))
    }

    func testHelloWelcomeAndCommands() async throws {
        let (transport, collector) = try await openClient()
        defer { Task { await transport.close() } }

        let hello = hello(token: "t")
        try await transport.send(.command(hello))
        let welcome = await collector.reply(for: hello.id)
        guard case .welcome(let snapshot)? = welcome else { return XCTFail("expected welcome, got \(String(describing: welcome))") }
        XCTAssertEqual(snapshot.agents.first?.name, "Nova")
        XCTAssertEqual(snapshot.host.hostName, "Test")

        let list = ClientCommand(body: .listSchedules)
        try await transport.send(.command(list))
        guard case .schedules(let jobs)? = await collector.reply(for: list.id) else { return XCTFail("expected schedules") }
        XCTAssertTrue(jobs.isEmpty)

        let ping = ClientCommand(body: .ping)
        try await transport.send(.command(ping))
        guard case .ok? = await collector.reply(for: ping.id) else { return XCTFail("expected ok") }

        // Events published on the bus reach the client.
        let published = try await store.appendEvent(.notice(level: .info, agentID: nil, text: "hello there"))
        await bus.publish(published)
        let received = await collector.event { if case .notice(_, _, let text) = $0.payload { return text == "hello there" }; return false }
        XCTAssertEqual(received?.seq, published.seq)

        // listEvents is served from the store.
        let listEvents = ClientCommand(body: .listEvents(afterSeq: 0, limit: 10))
        try await transport.send(.command(listEvents))
        guard case .events(let events)? = await collector.reply(for: listEvents.id) else { return XCTFail("expected events") }
        XCTAssertEqual(events.count, 1)

        // Client list was reported to the delegate.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, delegate.lock.withLock({ delegate.clientsChanges.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(delegate.lock.withLock { delegate.clientsChanges.first?.0 }, 1)
        let clients = await server.connectedClients
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.displayName, "test")
    }

    func testScreenSubscriptionDeliversBinaryFrames() async throws {
        let (transport, collector) = try await openClient()
        defer { Task { await transport.close() } }
        let hello = hello(token: "t")
        try await transport.send(.command(hello))
        _ = await collector.reply(for: hello.id)

        let subscribe = ClientCommand(body: .subscribeScreen(ScreenStreamOptions(framesPerSecond: 5)))
        try await transport.send(.command(subscribe))
        guard case .ok? = await collector.reply(for: subscribe.id) else { return XCTFail("expected ok") }
        let frame = await collector.frame()
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.0.width, 4)
        XCTAssertEqual(frame?.1, Data([0xFF, 0xD8, 0xFF, 0xD9]))

        let unsubscribe = ClientCommand(body: .unsubscribeScreen)
        try await transport.send(.command(unsubscribe))
        guard case .ok? = await collector.reply(for: unsubscribe.id) else { return XCTFail("expected ok") }

        // Streaming count was reported at least once as 1.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !delegate.lock.withLock({ delegate.clientsChanges.contains { $0.1 == 1 } }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(delegate.lock.withLock { delegate.clientsChanges.contains { $0.1 == 1 } })
    }

    /// Talk mode on the iPhone: the host's speech comes back on the binary channel, every piece in order, ending with
    /// the last one; a voice the host doesn't have is an error; stopping and leaving both stop what it was saying.
    func testSpeechComesBackInOrderAndStops() async throws {
        let (transport, collector) = try await openClient()
        let hello = hello(token: "t")
        try await transport.send(.command(hello))
        _ = await collector.reply(for: hello.id)

        let request = SpeechRequest(text: "Hi, I'm Penny.", voice: "penny")
        let speak = ClientCommand(body: .speak(request))
        try await transport.send(.command(speak))
        guard case .ok? = await collector.reply(for: speak.id) else { return XCTFail("expected ok") }
        _ = await collector.wait { if case .speech(let h, _) = $0 { return h.final }; return false }
        let pieces = await collector.speech
        XCTAssertEqual(pieces.map(\.0.speechID), Array(repeating: request.id, count: 4))
        XCTAssertEqual(pieces.map(\.0.final), [false, false, false, true])
        XCTAssertEqual(pieces.map { $0.1.first ?? -1 }.prefix(3).map { ($0 * 4).rounded() }, [0, 1, 2])
        XCTAssertEqual(pieces[0].1.count, 480)

        let unknown = ClientCommand(body: .speak(SpeechRequest(text: "Hi.", voice: "nobody")))
        try await transport.send(.command(unknown))
        guard case .error(let code, _)? = await collector.reply(for: unknown.id) else { return XCTFail("expected an error") }
        XCTAssertEqual(code, "voice_unavailable")

        let stop = ClientCommand(body: .stopSpeaking)
        try await transport.send(.command(stop))
        guard case .ok? = await collector.reply(for: stop.id) else { return XCTFail("expected ok") }
        XCTAssertEqual(delegate.lock.withLock { delegate.speechStops.count }, 1)

        await transport.close()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, delegate.lock.withLock({ delegate.speechStops.count }) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(delegate.lock.withLock { delegate.speechStops.count }, 2, "leaving stops it too")
    }

    /// A client that confirms frames gets no more than two ahead of its confirmations, so frames never pile up on a
    /// slow link; confirming lets the next ones through. Numbers keep counting up across its streams.
    func testAConfirmingClientIsSentNoMoreThanTwoUnconfirmedFrames() async throws {
        delegate.endless = true
        let (transport, collector) = try await openClient()
        defer { Task { await transport.close() } }
        let hello = hello(token: "t")
        try await transport.send(.command(hello))
        _ = await collector.reply(for: hello.id)

        let subscribe = ClientCommand(body: .subscribeScreen(ScreenStreamOptions(framesPerSecond: 30, acknowledges: true)))
        try await transport.send(.command(subscribe))
        _ = await collector.reply(for: subscribe.id)
        try await Task.sleep(for: .milliseconds(600))
        var numbers = await collector.frameNumbers
        XCTAssertEqual(numbers, [1, 2], "two frames, then it waits (the fake captures every 10 ms)")

        try await transport.send(.command(ClientCommand(body: .screenFrameReceived(2))))
        try await Task.sleep(for: .milliseconds(300))
        numbers = await collector.frameNumbers
        XCTAssertEqual(Array(numbers.prefix(4)), [1, 2, 3, 4], "confirming lets the next frames through")
        XCTAssertLessThanOrEqual(numbers.count, 4)

        // A new stream (a zoomed-in region, say) carries on the numbering.
        let again = ClientCommand(body: .subscribeScreen(ScreenStreamOptions(framesPerSecond: 30, region: ScreenRegion(x: 0, y: 0, width: 0.5, height: 0.5), acknowledges: true)))
        try await transport.send(.command(again))
        _ = await collector.reply(for: again.id)
        try await Task.sleep(for: .milliseconds(300))
        numbers = await collector.frameNumbers
        XCTAssertEqual(numbers, Array(1 ... Int64(numbers.count)), "numbers only go up: \(numbers)")
        XCTAssertGreaterThan(numbers.count, 4)
    }

    /// The owner's live input is applied in the order it was sent, even when one input takes longer than the next.
    func testLiveInputIsAppliedInOrder() async throws {
        let (transport, collector) = try await openClient()
        defer { Task { await transport.close() } }
        let hello = hello(token: "t")
        try await transport.send(.command(hello))
        _ = await collector.reply(for: hello.id)
        let inputs: [RemoteInput] = [.pointerDown(x: 0.1, y: 0.1, button: .left), .pointerMove(x: 0.2, y: 0.2), .pointerUp(x: 0.2, y: 0.2, button: .left)]
        let commands = inputs.map { ClientCommand(body: .remoteInput($0)) }
        for command in commands { try await transport.send(.command(command)) }
        for command in commands { _ = await collector.reply(for: command.id) }
        let applied = delegate.lock.withLock { delegate.handled.compactMap { body -> RemoteInput? in if case .remoteInput(let i) = body { return i }; return nil } }
        XCTAssertEqual(applied, inputs)
    }

    /// A client from before frame confirmations gets frames as they come.
    func testAClientThatDoesntConfirmIsNotHeldBack() async throws {
        delegate.endless = true
        let (transport, collector) = try await openClient()
        defer { Task { await transport.close() } }
        let hello = hello(token: "t")
        try await transport.send(.command(hello))
        _ = await collector.reply(for: hello.id)
        let subscribe = ClientCommand(body: .subscribeScreen(ScreenStreamOptions(framesPerSecond: 30)))
        try await transport.send(.command(subscribe))
        _ = await collector.reply(for: subscribe.id)
        try await Task.sleep(for: .milliseconds(600))
        let count = await collector.frameNumbers.count
        XCTAssertGreaterThan(count, 10)
    }

    /// Every capture a client starts ends: when it asks again, when it unsubscribes, and when it just goes away.
    /// (2026-09-28: 28 captures kept running in the host, each encoding frames nobody read.)
    func testScreenStreamsEndOnResubscribeUnsubscribeAndDisconnect() async throws {
        delegate.endless = true
        func live() -> Int { delegate.lock.withLock { delegate.liveStreams } }
        func settle(to n: Int) async throws {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, live() != n { try await Task.sleep(for: .milliseconds(20)) }
        }

        let (transport, collector) = try await openClient()
        let hello = hello(token: "t")
        try await transport.send(.command(hello))
        _ = await collector.reply(for: hello.id)
        for _ in 0..<3 {
            let subscribe = ClientCommand(body: .subscribeScreen(ScreenStreamOptions(framesPerSecond: 6)))
            try await transport.send(.command(subscribe))
            _ = await collector.reply(for: subscribe.id)
        }
        try await settle(to: 1)
        XCTAssertEqual(live(), 1, "asking again replaces the capture instead of adding one")
        let unsubscribe = ClientCommand(body: .unsubscribeScreen)
        try await transport.send(.command(unsubscribe))
        _ = await collector.reply(for: unsubscribe.id)
        try await settle(to: 0)
        XCTAssertEqual(live(), 0, "unsubscribing ends it")

        let subscribe = ClientCommand(body: .subscribeScreen(ScreenStreamOptions(framesPerSecond: 6)))
        try await transport.send(.command(subscribe))
        _ = await collector.reply(for: subscribe.id)
        try await settle(to: 1)
        await transport.close()
        try await settle(to: 0)
        XCTAssertEqual(live(), 0, "a client that goes away takes its capture with it")
    }

    func testWrongTokenIsRejectedAndClosed() async throws {
        let (transport, collector) = try await openClient()
        defer { Task { await transport.close() } }
        let hello = hello(token: "wrong")
        try await transport.send(.command(hello))
        guard case .error(let code, _)? = await collector.reply(for: hello.id) else { return XCTFail("expected error") }
        XCTAssertEqual(code, "unauthenticated")
        let closed = await collector.closed()
        XCTAssertNotNil(closed)
    }

    func testCommandBeforeHelloIsRejected() async throws {
        let (transport, collector) = try await openClient()
        defer { Task { await transport.close() } }
        let list = ClientCommand(body: .listSchedules)
        try await transport.send(.command(list))
        guard case .error(let code, _)? = await collector.reply(for: list.id) else { return XCTFail("expected error") }
        XCTAssertEqual(code, "unauthenticated")
        let closed = await collector.closed()
        XCTAssertNotNil(closed)
    }

    func testHostSessionConnectsAndReplays() async throws {
        // Seed two events so a client with lastEventSeq 0 replays them on connect.
        for i in 1...2 {
            let e = try await store.appendEvent(.notice(level: .info, agentID: nil, text: "seed \(i)"))
            await bus.publish(e)
        }
        let port = await server.port
        let session = await MainActor.run {
            HostSession(transport: WebSocketTransport(), endpoint: HostEndpoint(host: "127.0.0.1", port: port), token: "t", displayName: "session", platform: "xctest")
        }
        // The fake snapshot reports latestEventSeq 0, so replay is driven by the store; verify via listEvents instead.
        await MainActor.run { session.connect() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await MainActor.run(body: { !session.connection.isConnected }) { try await Task.sleep(for: .milliseconds(20)) }
        let connected = await MainActor.run { session.connection.isConnected }
        XCTAssertTrue(connected)
        let agents = await MainActor.run { session.state.agents.map(\.name) }
        XCTAssertEqual(agents, ["Nova"])
        let reply = try await MainActor.run { () throws -> Task<ReplyBody, Error> in
            Task { @MainActor in try await session.send(.listEvents(afterSeq: 0, limit: 10)) }
        }.value
        guard case .events(let events) = reply else { return XCTFail("expected events") }
        XCTAssertEqual(events.count, 2)
        await session.disconnect()
    }
}

final class DeviceTokensTests: XCTestCase {
    func testSignedInDevicesAndTheLocalTokenAreKnownUntilRevoked() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        let tokens = DeviceTokens(paths: paths, useFileFallback: true)
        let person = PersonID("maya")
        let clientID = ClientID()
        let token = await tokens.mintToken(clientID: clientID, clientName: "iPhone", platform: "ios", personID: person)
        XCTAssertEqual(token.count, 64)
        let owner = await tokens.owner(of: token)
        XCTAssertEqual(owner, .person(person))
        let unknown = await tokens.owner(of: "nope")
        let empty = await tokens.owner(of: "")
        XCTAssertNil(unknown)
        XCTAssertNil(empty)

        // The local token is the owner's, mirrored to a 0600 file.
        let local = await tokens.localToken()
        XCTAssertEqual(local.count, 64)
        let localOwner = await tokens.owner(of: local)
        XCTAssertEqual(localOwner, .owner)
        let fileURL = await tokens.localTokenFileURL
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), local)
        let perms = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        // Kept across instances, until revoked.
        let reloaded = DeviceTokens(paths: paths, useFileFallback: true)
        let reloadedOwner = await reloaded.owner(of: token)
        XCTAssertEqual(reloadedOwner, .person(person))
        let reloadedLocal = await reloaded.localToken()
        XCTAssertEqual(reloadedLocal, local)
        await reloaded.revoke(personID: person)
        let afterRevoke = await reloaded.owner(of: token)
        XCTAssertNil(afterRevoke)
        let afterRevokeFresh = await DeviceTokens(paths: paths, useFileFallback: true).owner(of: token)
        XCTAssertNil(afterRevokeFresh)
    }
}

// MARK: - Encrypted port

final class TLSAPITests: XCTestCase {
    func testEncryptedPortPinsTheCertificateAndRefusesAnother() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try HostTLSIdentity.loadOrCreate(root: root, hostName: "Test Mac")
        let again = try HostTLSIdentity.loadOrCreate(root: root, hostName: "Test Mac")
        XCTAssertEqual(identity.fingerprint, again.fingerprint, "made once, then reused")
        XCTAssertEqual(identity.fingerprint.count, 64)

        let server = HostAPIServer(config: HostConfig.API(port: 0, listenOnNetwork: false, advertiseBonjour: false, tlsPort: 0),
                                   delegate: FakeAPIDelegate(), eventBus: EventBus(), store: APITestStore(), hostName: "TestHost", tls: identity)
        try await server.start()
        defer { Task { await server.stop() } }
        let tlsPort = await server.tlsPort
        XCTAssertGreaterThan(tlsPort, 0)

        // First contact: accepted, and the certificate is pinned for that address.
        let endpoint = HostEndpoint(host: "127.0.0.1", port: tlsPort, name: "Test", useTLS: true)
        HostPins.forget(endpoint)
        defer { HostPins.forget(endpoint) }
        let transport = WebSocketTransport()
        let inbound = try await transport.open(endpoint: endpoint)
        let collector = InboundCollector()
        await collector.start(inbound)
        let hello = ClientCommand(body: .hello(ClientHello(clientID: ClientID(), displayName: "t", platform: "xctest", appVersion: "0", token: "t")))
        try await transport.send(.command(hello))
        guard case .welcome? = await collector.reply(for: hello.id) else { return XCTFail("no welcome over TLS") }
        await transport.close()
        XCTAssertEqual(HostPins.pin(for: endpoint), identity.fingerprint)

        // A host that shows another certificate is refused, and not retried in the clear.
        HostPins.set(String(repeating: "0", count: 64), for: endpoint)
        do {
            _ = try await WebSocketTransport(connectTimeout: 5).open(endpoint: endpoint)
            XCTFail("connected despite a different certificate")
        } catch TransportError.certificateChanged {
        } catch {
            XCTFail("expected certificateChanged, got \(error)")
        }
    }
}
