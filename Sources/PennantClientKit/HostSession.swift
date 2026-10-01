import PennantCore
import Foundation
import Observation

public enum HostSessionError: Error, CustomStringConvertible, Sendable {
    case notConnected
    case hostError(code: String, message: String)
    case unexpectedReply
    case timeout

    public var description: String {
        switch self {
        case .notConnected: return "Not connected to the host"
        case .hostError(let code, let message): return "\(code): \(message)"
        case .unexpectedReply: return "Unexpected reply from host"
        case .timeout: return "Timed out waiting for the host"
        }
    }

    /// A readable message for any error from a host call: the host's own words when it sent some.
    public static func message(_ error: any Error) -> String {
        if case HostSessionError.hostError(_, let message) = error { return message }
        return String(describing: error)
    }
}

/// The app's connection to one host: keeps `ClientState` current, sends commands, reconnects,
/// and replays events from the last applied sequence. Shared by the Mac and iPhone apps.
@MainActor
@Observable
public final class HostSession {
    public let state = ClientState()
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var endpoint: HostEndpoint
    public var token: String?
    /// Through Cloudflare Access: the Access token, which opens the tunnel and signs in (see `HostEndpoint.access`).
    public var accessToken: String? {
        didSet {
            (transport as? WebSocketTransport)?.accessToken = accessToken
            if accessToken != oldValue { needsAccessSignIn = false }
        }
    }
    /// Through Cloudflare Access, the sign-in has run out (or was refused): the app should sign in with the identity
    /// provider again. The session stops retrying until a new `accessToken` arrives.
    public private(set) var needsAccessSignIn = false
    /// The address the current connection went to: `endpoint.host`, or one of its alternates.
    public private(set) var reachedAddress: String?
    /// The host told us addresses we didn't know (its Tailscale name, say): save `endpoint` to keep them.
    public var onAddressesChanged: ((HostEndpoint) -> Void)?
    /// The alternate that answered last, tried first next time.
    private var lastGoodAddress: String?

    /// When an Access token stops working, read from the token itself (nil if unreadable).
    public static func accessTokenExpiry(_ token: String?) -> Date? {
        guard let token, case let parts = token.split(separator: "."), parts.count == 3 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
    public let clientID: ClientID
    public let displayName: String
    public let platform: String
    public private(set) var screenSubscribed = false

    private let transport: any HostTransport
    private var receiveTask: Task<Void, Never>?
    private var pending: [CommandID: CheckedContinuation<ReplyBody, Error>] = [:]
    private var reconnectAttempt = 0
    private var wantsConnection = false
    private var screenOptions = ScreenStreamOptions()

    public init(transport: any HostTransport, endpoint: HostEndpoint = .local, token: String? = nil, clientID: ClientID? = nil, displayName: String, platform: String) {
        self.transport = transport
        self.endpoint = endpoint
        self.token = token
        self.clientID = clientID ?? ClientID()
        self.displayName = displayName
        self.platform = platform
    }

    // MARK: Connection lifecycle

    public func connect(to endpoint: HostEndpoint? = nil) {
        if let endpoint { self.endpoint = endpoint }
        wantsConnection = true
        guard receiveTask == nil else { return }
        connection = .connecting
        receiveTask = Task { [weak self] in await self?.runConnectionLoop() }
    }

    public func disconnect() async {
        wantsConnection = false
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        failPending(HostSessionError.notConnected)
        connection = .disconnected
        screenSubscribed = false
        state.clearScreenFrame()
    }

    private func runConnectionLoop() async {
        while wantsConnection, !Task.isCancelled {
            if endpoint.isAccess, accessToken == nil || (Self.accessTokenExpiry(accessToken).map { $0 < Date() } ?? false) {
                needsAccessSignIn = true
                connection = .failed("Sign in again to reach \(endpoint.host).")
                break
            }
            do {
                let inbound = try await openAnyAddress()
                reconnectAttempt = 0
                // Pump inbound traffic before the handshake: hello's reply arrives on this stream.
                let pump = Task { [weak self] in
                    for await item in inbound {
                        guard let self else { return }
                        self.handleInbound(item)
                        if Task.isCancelled { return }
                    }
                }
                try await handshake()
                connection = .connected
                if screenSubscribed { _ = try? await send(.subscribeScreen(screenOptions)) }
                await pump.value
            } catch {
                connection = .failed(String(describing: error))
            }
            failPending(HostSessionError.notConnected)
            await transport.close()
            guard wantsConnection, !Task.isCancelled else { break }
            reconnectAttempt += 1
            connection = .reconnecting(attempt: reconnectAttempt)
            let delay = min(pow(1.6, Double(reconnectAttempt)), 15)
            try? await Task.sleep(for: .seconds(delay))
        }
        receiveTask = nil
        if !wantsConnection { connection = .disconnected }
    }

    /// Every address of this host, the one that worked last first. Alternates only for a pinned host: they must show
    /// the same certificate, pinned for each up front so none can fall back to the unencrypted port.
    func candidateEndpoints() -> [HostEndpoint] {
        guard !endpoint.isAccess, !endpoint.isLoopback, let alternates = endpoint.alternates, !alternates.isEmpty,
              let pin = HostPins.pin(for: endpoint) else { return [endpoint] }
        var all = [endpoint] + alternates.filter { $0 != endpoint.host }.map { endpoint.at($0) }
        if let last = lastGoodAddress, let i = all.firstIndex(where: { $0.host == last }) { all.insert(all.remove(at: i), at: 0) }
        for e in all where e.host != endpoint.host { HostPins.set(pin, for: e) }
        return all
    }

    private func openAnyAddress() async throws -> AsyncStream<TransportInbound> {
        var lastError: Error = HostSessionError.notConnected
        for candidate in candidateEndpoints() {
            do {
                let inbound = try await transport.open(endpoint: candidate)
                reachedAddress = candidate.host
                lastGoodAddress = candidate.host
                return inbound
            } catch let error as TransportError {
                // Someone else answering at an address is a stop, not a reason to try the next one.
                if case .certificateChanged = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            if Task.isCancelled || !wantsConnection { break }
        }
        throw lastError
    }

    /// Addresses for this host from elsewhere (its connect code), kept like the ones it announces.
    public func rememberAddresses(_ addresses: [String]) {
        learnAddresses((endpoint.alternates ?? []) + addresses)
    }

    /// Keeps the host's other addresses (from its welcome) with the endpoint.
    private func learnAddresses(_ addresses: [String]?) {
        guard let addresses, !endpoint.isAccess, !endpoint.isLoopback else { return }
        var seen: Set<String> = [endpoint.host]
        let others = addresses.filter { seen.insert($0).inserted }
        guard !others.isEmpty, others != endpoint.alternates else { return }
        endpoint.alternates = others
        onAddressesChanged?(endpoint)
    }

    private func handshake() async throws {
        let hello = ClientHello(clientID: clientID, displayName: displayName, platform: platform, appVersion: PennantVersion.string, lastEventSeq: state.lastEventSeq,
                                token: endpoint.isAccess ? nil : token, accessToken: endpoint.isAccess ? accessToken : nil)
        let reply = try await send(.hello(hello))
        if case .error(let code, let message) = reply, code == "access_denied" {
            needsAccessSignIn = true
            wantsConnection = false
            throw HostSessionError.hostError(code: code, message: message)
        }
        guard case .welcome(let snapshot) = reply else { throw HostSessionError.unexpectedReply }
        state.apply(snapshot: snapshot)
        learnAddresses(snapshot.host.addresses)
        // Replay anything missed while disconnected.
        var after = min(state.lastEventSeq, snapshot.latestEventSeq)
        if after < snapshot.latestEventSeq {
            while true {
                let r = try await send(.listEvents(afterSeq: after, limit: 500))
                guard case .events(let events) = r, !events.isEmpty else { break }
                for e in events { state.apply(event: e) }
                after = events.last!.seq
                if events.count < 500 { break }
            }
        }
        // Cards waiting anywhere, for the approvals bubble (a host without the command just has none).
        Task { try? await loadPendingApprovals(); try? await loadReports() }
    }

    public func loadReports() async throws {
        let r = try await send(.listReports, timeout: 30)
        guard case .reports(let list) = r else { throw HostSessionError.unexpectedReply }
        state.setReports(list)
    }

    public func loadPendingApprovals() async throws {
        let r = try await send(.listPendingApprovals, timeout: 30)
        guard case .pendingApprovals(let list) = r else { throw HostSessionError.unexpectedReply }
        state.setPendingApprovals(list)
    }

    private func handleInbound(_ item: TransportInbound) {
        switch item {
        case .message(let m): handle(m)
        case .screenFrame(let h, let d): state.setScreenFrame(h, d)
        case .closed(let reason): connection = .failed(reason)
        }
    }

    private func handle(_ message: WireMessage) {
        switch message {
        case .reply(let reply):
            if let c = pending.removeValue(forKey: reply.commandID) { c.resume(returning: reply.result) }
        case .event(let event):
            state.apply(event: event)
        case .command:
            break
        }
    }

    private func failPending(_ error: Error) {
        let all = pending
        pending = [:]
        for c in all.values { c.resume(throwing: error) }
    }

    // MARK: Commands

    @discardableResult
    public func send(_ body: CommandBody, timeout: TimeInterval = 60) async throws -> ReplyBody {
        let command = ClientCommand(body: body)
        let result: ReplyBody = try await withCheckedThrowingContinuation { continuation in
            pending[command.id] = continuation
            Task {
                do { try await transport.send(.command(command)) }
                catch {
                    if let c = pending.removeValue(forKey: command.id) { c.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let c = pending.removeValue(forKey: command.id) { c.resume(throwing: HostSessionError.timeout) }
            }
        }
        if case .error(let code, let message) = result { throw HostSessionError.hostError(code: code, message: message) }
        return result
    }

    // MARK: Convenience

    public func sendMessage(to agentID: AgentID, conversationID: ConversationID? = nil, text: String, attachments: [Attachment] = []) async throws -> (MessageID, ConversationID, TaskID) {
        let r = try await send(.sendMessage(agentID: agentID, conversationID: conversationID, text: text, attachments: attachments))
        guard case .messageAccepted(let m, let c, let t) = r else { throw HostSessionError.unexpectedReply }
        return (m, c, t)
    }

    public func loadMessages(conversationID: ConversationID, before: MessageID? = nil, limit: Int = 50) async throws -> Bool {
        let r = try await send(.listMessages(conversationID: conversationID, beforeMessageID: before, limit: limit))
        guard case .messages(let page) = r else { throw HostSessionError.unexpectedReply }
        state.setMessages(page.items, for: conversationID, prepend: before != nil)
        return page.hasMore
    }

    public func loadToolRecords(taskID: TaskID) async throws {
        let r = try await send(.getToolRecords(taskID))
        guard case .toolRecords(let records) = r else { throw HostSessionError.unexpectedReply }
        state.setToolRecords(records, for: taskID)
    }

    public func updateAgent(_ agent: AgentProfile) async throws {
        _ = try await send(.updateAgent(agent))
    }

    public func pauseTask(_ id: TaskID, reason: String = "Paused by user") async throws { _ = try await send(.pauseTask(id, reason: reason)) }
    public func resumeTask(_ id: TaskID) async throws { _ = try await send(.resumeTask(id)) }
    public func cancelTask(_ id: TaskID, reason: String = "Cancelled by user") async throws { _ = try await send(.cancelTask(id, reason: reason)) }
    public func answerQuestion(taskID: TaskID, text: String) async throws { _ = try await send(.answerQuestion(taskID: taskID, text: text)) }

    public func takeoverDesktop() async throws { _ = try await send(.takeoverDesktop) }
    public func releaseDesktop() async throws { _ = try await send(.releaseDesktop) }
    public func pauseDesktop() async throws { _ = try await send(.pauseDesktop) }
    public func resumeDesktop() async throws { _ = try await send(.resumeDesktop) }
    public func setPauseOnHumanInput(_ on: Bool) async throws { _ = try await send(.setPauseOnHumanInput(on)) }
    public func sendRemoteInput(_ input: RemoteInput) async throws { _ = try await send(.remoteInput(input), timeout: 10) }

    public func subscribeScreen(_ options: ScreenStreamOptions = ScreenStreamOptions()) async throws {
        screenOptions = options
        screenSubscribed = true
        _ = try await send(.subscribeScreen(options))
    }

    public func unsubscribeScreen() async throws {
        screenSubscribed = false
        state.clearScreenFrame()
        _ = try await send(.unsubscribeScreen)
    }

    /// Views showing the screen right now. The stream stays on while any of them is up, so one view appearing as
    /// another goes (a full-screen cover over the panel) never cuts it off.
    private var screenViewers = 0

    /// A view starts showing the screen: subscribes (with its options, else the current ones) and counts it.
    public func watchScreen(_ options: ScreenStreamOptions? = nil) async {
        screenViewers += 1
        try? await subscribeScreen(options ?? screenOptions)
    }

    /// A view stops showing the screen; the stream ends when the last one goes.
    public func stopWatchingScreen() async {
        screenViewers = max(0, screenViewers - 1)
        if screenViewers == 0 { try? await unsubscribeScreen() }
    }

    public func loadSkills() async throws {
        let r = try await send(.listSkills)
        guard case .skills(let s) = r else { throw HostSessionError.unexpectedReply }
        state.setSkills(s)
    }

    public func loadMemory(kind: MemoryEntityKind? = nil, scope: String? = nil) async throws {
        let e = try await send(.listEntities(kind: kind, scope: scope, limit: 500))
        if case .entities(let items) = e { state.setEntities(items) }
        let p = try await send(.listPreferences(scope: scope))
        if case .preferences(let items) = p { state.setPreferences(items) }
    }

    // MARK: Channels

    public func channels(_ body: CommandBody = .listChannels) async throws -> ChannelsOverview {
        guard case .channels(let o) = try await send(body, timeout: 30) else { throw HostSessionError.unexpectedReply }
        return o
    }

    public func channelLink(_ kind: ChannelKind) async throws -> ChannelLinkCode {
        guard case .channelLink(let l) = try await send(.createChannelLink(kind)) else { throw HostSessionError.unexpectedReply }
        return l
    }

    /// The passages that mention a fact: the evidence behind it.
    public func memoryEvidence(_ id: MemoryEntityID) async throws -> [MemoryPassage] {
        guard case .memoryPassages(let p) = try await send(.memoryEvidence(id)) else { throw HostSessionError.unexpectedReply }
        return p
    }

    public func renameEntity(_ id: MemoryEntityID, to name: String) async throws -> MemoryEntity {
        guard case .entity(let e) = try await send(.renameEntity(id, name: name)) else { throw HostSessionError.unexpectedReply }
        try? await loadMemory()
        return e
    }

    public func mergeEntities(_ from: MemoryEntityID, into: MemoryEntityID) async throws -> MemoryEntity {
        guard case .entity(let e) = try await send(.mergeEntities(from: from, into: into)) else { throw HostSessionError.unexpectedReply }
        try? await loadMemory()
        return e
    }

    /// What Pennant decided on its own to keep memory current, newest first.
    public func memoryUpkeepLog() async throws -> [MemoryUpkeepEntry] {
        guard case .memoryUpkeep(let log) = try await send(.memoryUpkeepLog) else { throw HostSessionError.unexpectedReply }
        return log
    }

    /// Puts back what one of those decisions set aside.
    public func undoMemoryUpkeep(_ id: String) async throws -> [MemoryUpkeepEntry] {
        guard case .memoryUpkeep(let log) = try await send(.undoMemoryUpkeep(id: id)) else { throw HostSessionError.unexpectedReply }
        try? await loadMemory()
        return log
    }

    public func removedMemory() async throws -> [IgnoredMemoryName] {
        guard case .removedMemory(let r) = try await send(.listRemovedMemory) else { throw HostSessionError.unexpectedReply }
        return r
    }

    public func restoreRemovedMemory(_ item: IgnoredMemoryName) async throws -> [IgnoredMemoryName] {
        guard case .removedMemory(let r) = try await send(.restoreRemovedMemory(name: item.name, kind: item.kind)) else { throw HostSessionError.unexpectedReply }
        return r
    }

    public func searchMemory(_ query: MemoryQuery) async throws -> [MemoryHit] {
        let r = try await send(.searchMemory(query))
        guard case .memoryHits(let hits) = r else { throw HostSessionError.unexpectedReply }
        return hits
    }

    public func memoryOverview() async throws -> MemoryOverview {
        let r = try await send(.memoryOverview)
        guard case .memoryOverview(let o) = r else { throw HostSessionError.unexpectedReply }
        return o
    }

    public func relations(for entityID: MemoryEntityID) async throws -> [MemoryRelation] {
        let r = try await send(.listRelations(entityID: entityID))
        guard case .relations(let items) = r else { throw HostSessionError.unexpectedReply }
        return items
    }

    public func diagnostics() async throws -> DiagnosticsReport {
        let r = try await send(.getDiagnostics)
        guard case .diagnostics(let d) = r else { throw HostSessionError.unexpectedReply }
        return d
    }

    public func artifact(_ id: ArtifactID) async throws -> (ArtifactRecord, Data) {
        let r = try await send(.getArtifact(id))
        guard case .artifact(let rec, let b64) = r, let data = Data(base64Encoded: b64) else { throw HostSessionError.unexpectedReply }
        return (rec, data)
    }

    public func retireAgent(_ id: AgentID) async throws { _ = try await send(.retireAgent(id)) }

    // MARK: MCP servers

    public func loadMCPServers() async throws {
        let r = try await send(.listMCPServers)
        guard case .mcpServers(let list) = r else { throw HostSessionError.unexpectedReply }
        state.setMCPServers(list)
    }

    public func addMCPServer(_ config: MCPServerConfig) async throws -> [MCPServerStatus] {
        let r = try await send(.addMCPServer(config), timeout: 90)
        guard case .mcpServers(let list) = r else { throw HostSessionError.unexpectedReply }
        state.setMCPServers(list)
        return list
    }

    /// Returns the browser URL that completes sign-in; the host reports the outcome through status events.
    public func beginMCPAuth(_ id: MCPServerID) async throws -> URL {
        let r = try await send(.beginMCPAuth(id), timeout: 60)
        guard case .mcpAuthStarted(_, let url) = r, let u = URL(string: url) else { throw HostSessionError.unexpectedReply }
        return u
    }

    public func cancelMCPAuth(_ id: MCPServerID) async throws { _ = try await send(.cancelMCPAuth(id)) }

    public func setMCPCredential(_ id: MCPServerID, secret: String) async throws -> [MCPServerStatus] {
        let r = try await send(.setMCPCredential(id, secret: secret), timeout: 90)
        guard case .mcpServers(let list) = r else { throw HostSessionError.unexpectedReply }
        state.setMCPServers(list)
        return list
    }

    public func signOutMCP(_ id: MCPServerID) async throws -> [MCPServerStatus] {
        let r = try await send(.signOutMCP(id), timeout: 60)
        guard case .mcpServers(let list) = r else { throw HostSessionError.unexpectedReply }
        state.setMCPServers(list)
        return list
    }

    // MARK: ChatGPT account

    public func beginChatGPTSignIn() async throws -> URL {
        let r = try await send(.beginChatGPTSignIn, timeout: 60)
        guard case .chatGPTSignInStarted(let url) = r, let u = URL(string: url) else { throw HostSessionError.unexpectedReply }
        return u
    }

    public func importCodexLogin() async throws -> ChatGPTAccount {
        let r = try await send(.importCodexLogin, timeout: 30)
        guard case .chatGPTAccount(let a) = r else { throw HostSessionError.unexpectedReply }
        return a
    }

    public func signOutChatGPT() async throws -> ChatGPTAccount {
        let r = try await send(.signOutChatGPT, timeout: 30)
        guard case .chatGPTAccount(let a) = r else { throw HostSessionError.unexpectedReply }
        return a
    }

    public func chatGPTAccount() async throws -> ChatGPTAccount {
        let r = try await send(.getChatGPTAccount, timeout: 30)
        guard case .chatGPTAccount(let a) = r else { throw HostSessionError.unexpectedReply }
        return a
    }

    public func chatGPTModels() async throws -> [ChatGPTModel] {
        let r = try await send(.listChatGPTModels, timeout: 30)
        guard case .chatGPTModels(let m) = r else { throw HostSessionError.unexpectedReply }
        return m
    }

    public func mcpCatalog() async throws -> [MCPCatalogEntry] {
        let r = try await send(.listMCPCatalog)
        guard case .mcpCatalog(let entries) = r else { throw HostSessionError.unexpectedReply }
        return entries
    }

    /// Ask the host for a short-lived pairing code to show to a new device.
    /// Your own name and email; on the Mac itself, the owner's account.
    public func updateMyAccount(name: String, email: String) async throws {
        applyAccount(try await send(.updateMyAccount(name: name, email: email)))
    }

    /// Sets or changes your password.
    public func setMyPassword(current: String?, new: String) async throws {
        applyAccount(try await send(.setMyPassword(current: current, new: new), timeout: 30))
    }

    /// The people list after an account change, with "me" brought up to date from it.
    private func applyAccount(_ reply: ReplyBody) {
        guard case .people(let d) = reply else { return }
        state.setPeople(d)
        if let id = state.me?.id, let updated = d.people.first(where: { $0.id == id }) { state.me = updated }
    }

    public func getConfig() async throws -> (config: HostConfig, restartRequired: Bool) {
        let r = try await send(.getConfig)
        guard case .config(let c, let restart) = r else { throw HostSessionError.unexpectedReply }
        return (c, restart)
    }

    /// Save a new host configuration. `restartRequired` is true when the host must restart to apply it.
    public func updateConfig(_ config: HostConfig) async throws -> (config: HostConfig, restartRequired: Bool) {
        let r = try await send(.updateConfig(config))
        guard case .config(let c, let restart) = r else { throw HostSessionError.unexpectedReply }
        return (c, restart)
    }

    /// Ask the host to trigger macOS permission prompts. Empty targets requests everything.
    @discardableResult
    public func requestPermissions(_ targets: [String]) async throws -> DesktopStatus {
        let r = try await send(.requestPermissions(targets: targets), timeout: 120)
        guard case .desktop(let d) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .desktopStatus(d)))
        return d
    }

    /// Models the inference endpoint reports, for the settings picker.
    public func listModels(baseURL: String, apiKey: String?, apiKeyVault: String? = nil) async throws -> [ModelInfo] {
        let r = try await send(.listModels(baseURL: baseURL, apiKey: apiKey, apiKeyVault: apiKeyVault), timeout: 30)
        guard case .models(let models) = r else { throw HostSessionError.unexpectedReply }
        return models
    }

    /// Re-read desktop status (owner, permissions) and apply it to the cached state.
    /// Clear the host's entry for one permission so macOS prompts again.
    public func resetPermission(_ target: String) async throws -> DesktopStatus {
        let r = try await send(.resetPermission(target: target), timeout: 30)
        guard case .desktop(let d) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .desktopStatus(d)))
        return d
    }

    /// Ask the host to re-evaluate permissions right now and apply the result.
    public func recheckPermissions() async throws -> DesktopStatus {
        let r = try await send(.recheckPermissions, timeout: 30)
        guard case .desktop(let d) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .desktopStatus(d)))
        return d
    }

    public func refreshDesktopStatus() async throws {
        let r = try await send(.getDesktopStatus, timeout: 15)
        guard case .desktop(let d) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .desktopStatus(d)))
    }

    /// Compact the conversation now. Returns the updated latest task; a checkpoint event follows.
    public func compactConversation(_ id: ConversationID) async throws -> TaskRecord {
        let r = try await send(.compactConversation(id), timeout: 300)
        guard case .task(let task) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .taskUpserted(task)))
        return task
    }

    /// Points a coding thread at another project on the host. A Claude Code session starts over there.
    public func setConversationFolder(_ id: ConversationID, path: String) async throws {
        _ = try await send(.setConversationFolder(id, path: path))
    }

    /// Deletes conversations for good, with their messages and tasks.
    public func deleteConversations(_ ids: [ConversationID]) async throws {
        _ = try await send(.deleteConversations(ids), timeout: 60)
    }

    /// Closes every open conversation idle for `idleDays`; returns how many.
    // MARK: Notifications

    public func registerPushDevice(token: String, environment: String, teamID: String?, name: String, bundleID: String) async throws {
        _ = try await send(.registerPushDevice(token: token, environment: environment, teamID: teamID, name: name, bundleID: bundleID))
    }

    public func pushStatus() async throws -> PushStatus {
        guard case .pushStatus(let s) = try await send(.getPushStatus) else { throw HostSessionError.unexpectedReply }
        return s
    }

    public func setPushKey(keyID: String, teamID: String?, p8: String) async throws -> PushStatus {
        guard case .pushStatus(let s) = try await send(.setPushKey(keyID: keyID, teamID: teamID, p8: p8)) else { throw HostSessionError.unexpectedReply }
        return s
    }

    public func sendTestPush() async throws -> PushStatus {
        guard case .pushStatus(let s) = try await send(.sendTestPush, timeout: 30) else { throw HostSessionError.unexpectedReply }
        return s
    }

    public func pruneConversations(idleDays: Int) async throws -> Int {
        guard case .pruned(let n) = try await send(.pruneConversations(idleDays: idleDays), timeout: 60) else { throw HostSessionError.unexpectedReply }
        return n
    }

    /// Closes a conversation as done (its running task stops), or reopens it.
    public func closeConversation(_ id: ConversationID, closed: Bool = true) async throws {
        _ = try await send(.closeConversation(id, closed: closed))
    }

    /// A coding conversation's mode and model, from its next message on.
    public func setConversationCoding(_ id: ConversationID, mode: CodingMode?, model: String?) async throws {
        _ = try await send(.setConversationCoding(id, mode: mode, model: model))
    }

    /// Answers a choice card: question text → the chosen label(s) or the person's own words.
    public func answerChoices(taskID: TaskID, questionID: String, answers: [String: String]) async throws {
        _ = try await send(.answerChoices(taskID: taskID, questionID: questionID, answers: answers))
    }

    /// Folders on the host a coding run could work in: the Coding projects, then git projects, most recently changed
    /// first.
    public func listProjects() async throws -> [String] {
        let r = try await send(.listProjects, timeout: 30)
        guard case .projects(let paths) = r else { throw HostSessionError.unexpectedReply }
        return paths
    }

    /// Has the host mint a GitHub token for `identity`; throws with what GitHub or the Vault refused.
    public func checkGitHubApp(_ identity: GitHubAppIdentity) async throws {
        _ = try await send(.checkGitHubApp(identity), timeout: 30)
    }

    public func conversationCheckpoints(_ id: ConversationID) async throws -> [Checkpoint] {
        let r = try await send(.getConversationCheckpoints(id))
        guard case .checkpoints(let items) = r else { throw HostSessionError.unexpectedReply }
        return items
    }

    // MARK: Schedules and skill import

    public func loadSchedules() async throws {
        let r = try await send(.listSchedules)
        guard case .schedules(let jobs) = r else { throw HostSessionError.unexpectedReply }
        state.setSchedules(jobs)
    }

    // MARK: Goals

    public func loadGoals() async throws {
        let r = try await send(.listGoals)
        guard case .goals(let goals) = r else { throw HostSessionError.unexpectedReply }
        for g in goals { state.apply(event: HostEvent(seq: 0, payload: .goalUpserted(g))) }
    }

    @discardableResult
    public func setGoalStatus(_ id: GoalID, _ status: Goal.Status) async throws -> Goal {
        let r = try await send(.setGoalStatus(id, status))
        guard case .goal(let goal) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .goalUpserted(goal)))
        return goal
    }

    public func deleteGoal(_ id: GoalID) async throws {
        let r = try await send(.deleteGoal(id))
        guard case .ok = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .goalRemoved(id)))
    }

    @discardableResult
    public func saveGoal(_ goal: Goal) async throws -> Goal {
        let r = try await send(.upsertGoal(goal))
        guard case .goal(let saved) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .goalUpserted(saved)))
        return saved
    }

    public func loadGoalItems(_ goal: GoalID) async throws {
        let r = try await send(.listGoalItems(goal))
        guard case .goalItems(let items) = r else { throw HostSessionError.unexpectedReply }
        state.setGoalItems(items, for: goal)
    }

    @discardableResult
    public func saveGoalItem(_ item: GoalItem) async throws -> GoalItem {
        let r = try await send(.upsertGoalItem(item))
        guard case .goalItem(let saved) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .goalItemUpserted(saved)))
        return saved
    }

    @discardableResult
    public func commentGoalItem(_ id: GoalItemID, text: String) async throws -> GoalItem {
        let r = try await send(.commentGoalItem(id, text: text))
        guard case .goalItem(let saved) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .goalItemUpserted(saved)))
        return saved
    }

    public func upsertSchedule(_ job: ScheduledJob) async throws -> ScheduledJob {
        let r = try await send(.upsertSchedule(job))
        guard case .schedule(let saved) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .scheduleUpserted(saved)))
        return saved
    }

    public func deleteSchedule(_ id: ScheduleID) async throws {
        _ = try await send(.deleteSchedule(id))
        state.apply(event: HostEvent(seq: 0, payload: .scheduleRemoved(id)))
    }

    public func runScheduleNow(_ id: ScheduleID) async throws -> ScheduledJob {
        let r = try await send(.runScheduleNow(id), timeout: 120)
        guard case .schedule(let job) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .scheduleUpserted(job)))
        return job
    }

    /// Next run times for an expression, or the host's parse error.
    public func previewSchedule(_ expression: String, timeZone: String, count: Int = 3) async throws -> ([Date], String?) {
        let r = try await send(.previewSchedule(expression: expression, timeZone: timeZone, count: count), timeout: 15)
        guard case .schedulePreview(let dates, let error) = r else { throw HostSessionError.unexpectedReply }
        return (dates, error)
    }

    public func importSkills(path: String, only: [String]? = nil) async throws -> ([Skill], [String]) {
        let r = try await send(.importSkills(path: path, only: only), timeout: 180)
        guard case .importedSkills(let skills, let warnings) = r else { throw HostSessionError.unexpectedReply }
        return (skills, warnings)
    }

    public func previewSkillImport(path: String) async throws -> SkillImportPreview {
        let r = try await send(.previewSkillImport(path: path), timeout: 180)
        guard case .skillPreview(let preview) = r else { throw HostSessionError.unexpectedReply }
        return preview
    }

    // MARK: Approvals

    /// Answers an approval card; the waiting task resumes with the decision.
    public func decideApproval(_ decision: ApprovalDecision) async throws {
        _ = try await send(.decideApproval(decision), timeout: 30)
    }

    // MARK: Attachments

    /// Uploads a file for the next message; send the returned attachment with `sendMessage`.
    public func uploadAttachment(_ data: Data, fileName: String, mimeType: String) async throws -> Attachment {
        let r = try await send(.uploadAttachment(fileName: fileName, mimeType: mimeType, base64: data.base64EncodedString()), timeout: 120)
        guard case .attachment(let a) = r else { throw HostSessionError.unexpectedReply }
        return a
    }

    // MARK: Prompt inspector

    /// What the agent's model received on its latest turn, or a preview for a new task.
    public func inspectPrompt(_ agentID: AgentID) async throws -> PromptInspection {
        let r = try await send(.inspectPrompt(agentID), timeout: 60)
        guard case .promptInspection(let p) = r else { throw HostSessionError.unexpectedReply }
        return p
    }

    // MARK: Library

    public func listLibrary() async throws -> LibraryIndex { try await libraryReply(.listLibrary) }

    @discardableResult
    public func uploadLibraryAsset(_ data: Data, collection: String, fileName: String, mimeType: String, name: String = "", notes: String = "") async throws -> LibraryIndex {
        try await libraryReply(.uploadLibraryAsset(collection: collection, fileName: fileName, mimeType: mimeType, base64: data.base64EncodedString(), name: name, notes: notes), timeout: 180)
    }

    @discardableResult
    public func updateLibraryAsset(_ asset: LibraryAsset) async throws -> LibraryIndex { try await libraryReply(.updateLibraryAsset(asset)) }
    @discardableResult
    public func deleteLibraryAsset(id: String) async throws -> LibraryIndex { try await libraryReply(.deleteLibraryAsset(id: id)) }
    @discardableResult
    public func saveLibraryCollection(_ collection: LibraryCollection) async throws -> LibraryIndex { try await libraryReply(.saveLibraryCollection(collection)) }
    @discardableResult
    public func deleteLibraryCollection(name: String) async throws -> LibraryIndex { try await libraryReply(.deleteLibraryCollection(name: name)) }

    public func libraryPreview(id: String) async throws -> Data {
        let r = try await send(.libraryPreview(id: id), timeout: 60)
        guard case .libraryPreview(_, let base64) = r, let data = Data(base64Encoded: base64) else { throw HostSessionError.unexpectedReply }
        return data
    }

    private func libraryReply(_ command: CommandBody, timeout: TimeInterval = 30) async throws -> LibraryIndex {
        let r = try await send(command, timeout: timeout)
        guard case .library(let index) = r else { throw HostSessionError.unexpectedReply }
        return index
    }

    // MARK: Vault

    public func listVault() async throws -> [VaultItem] { try await vaultReply(.listVault) }
    /// Saves an entry. Secret fields left nil keep what is stored; empty strings clear them.
    @discardableResult
    public func saveVaultItem(_ item: VaultItem, secret: VaultSecret?) async throws -> [VaultItem] { try await vaultReply(.saveVaultItem(item, secret: secret)) }
    @discardableResult
    public func deleteVaultItem(id: String) async throws -> [VaultItem] { try await vaultReply(.deleteVaultItem(id: id)) }

    // MARK: Models

    public func testModel(_ inference: HostConfig.Inference) async throws -> ModelTestResult {
        let r = try await send(.testModel(inference), timeout: 120)
        guard case .modelTest(let t) = r else { throw HostSessionError.unexpectedReply }
        return t
    }

    // MARK: People

    public func loadPeople() async throws {
        guard case .people(let directory) = try await send(.listPeople) else { throw HostSessionError.unexpectedReply }
        state.setPeople(directory)
    }

    public func peopleCommand(_ body: CommandBody) async throws {
        guard case .people(let directory) = try await send(body) else { throw HostSessionError.unexpectedReply }
        state.setPeople(directory)
    }

    /// Model usage summed per task and model between two dates.
    public func usageReport(from: Date, to: Date) async throws -> [UsageRow] {
        let r = try await send(.usageReport(from: from, to: to), timeout: 60)
        guard case .usage(let rows) = r else { throw HostSessionError.unexpectedReply }
        return rows
    }

    /// Exports this host's data into a new folder under `folder` (default ~/Documents on the host).
    public func exportData(folder: String? = nil, passphrase: String? = nil) async throws -> PennantExportResult {
        let r = try await send(.exportData(folder: folder, passphrase: passphrase), timeout: 600)
        guard case .exported(let result) = r else { throw HostSessionError.unexpectedReply }
        return result
    }

    /// Stages an export on the host; the host then restarts and swaps it in.
    public func importData(folder: String, passphrase: String? = nil) async throws {
        _ = try await send(.importData(folder: folder, passphrase: passphrase), timeout: 600)
    }

    public func azureStatus() async throws -> AzureStatus { try await azureStatusReply(.azureStatus, timeout: 60) }
    /// Runs `az login` on the host; its browser opens there. Waits up to 5 minutes.
    public func azureLogin() async throws -> AzureStatus { try await azureStatusReply(.azureLogin, timeout: 320) }

    private func azureStatusReply(_ command: CommandBody, timeout: TimeInterval) async throws -> AzureStatus {
        let r = try await send(command, timeout: timeout)
        guard case .azureStatus(let s) = r else { throw HostSessionError.unexpectedReply }
        return s
    }

    public func azureSubscriptions() async throws -> [AzureSubscription] {
        let r = try await send(.azureSubscriptions, timeout: 60)
        guard case .azureSubscriptions(let s) = r else { throw HostSessionError.unexpectedReply }
        return s
    }

    public func azureResources(subscription: String) async throws -> [AzureResource] {
        let r = try await send(.azureResources(subscription: subscription), timeout: 120)
        guard case .azureResources(let s) = r else { throw HostSessionError.unexpectedReply }
        return s
    }

    public func azureDeployments(subscription: String, resourceGroup: String, resource: String) async throws -> [AzureDeployment] {
        let r = try await send(.azureDeployments(subscription: subscription, resourceGroup: resourceGroup, resource: resource), timeout: 120)
        guard case .azureDeployments(let s) = r else { throw HostSessionError.unexpectedReply }
        return s
    }

    public func chromeProfiles() async throws -> [ChromeProfile] {
        let r = try await send(.listChromeProfiles, timeout: 30)
        guard case .chromeProfiles(let p) = r else { throw HostSessionError.unexpectedReply }
        return p
    }

    public func chromeSites(profile: String) async throws -> [ChromeSite] {
        let r = try await send(.listChromeSites(profile: profile), timeout: 60)
        guard case .chromeSites(let s) = r else { throw HostSessionError.unexpectedReply }
        return s
    }

    /// Copies the sites' sign-ins from the user's Chrome into Pennant's browser. macOS may ask to allow Keychain access.
    public func importChromeSignIns(profile: String, sites: [String]) async throws -> ChromeImportResult {
        let r = try await send(.importChromeSignIns(profile: profile, sites: sites), timeout: 240)
        guard case .chromeImport(let result) = r else { throw HostSessionError.unexpectedReply }
        return result
    }

    public func browserSignIns() async throws -> [BrowserSignIn] {
        let r = try await send(.listBrowserSignIns, timeout: 30)
        guard case .browserSignIns(let list) = r else { throw HostSessionError.unexpectedReply }
        return list
    }

    /// Deletes a site's cookies from Pennant's browser, so scripts are signed out there.
    public func removeBrowserSignIn(site: String) async throws -> [BrowserSignIn] {
        let r = try await send(.removeBrowserSignIn(site: site), timeout: 180)
        guard case .browserSignIns(let list) = r else { throw HostSessionError.unexpectedReply }
        return list
    }

    private func vaultReply(_ command: CommandBody) async throws -> [VaultItem] {
        let r = try await send(command, timeout: 30)
        guard case .vault(let items) = r else { throw HostSessionError.unexpectedReply }
        return items
    }

    // MARK: Teach mode

    @discardableResult
    public func startTeaching(goal: String) async throws -> TeachingSession? {
        try await teachingReply(.startTeaching(goal: goal))
    }

    @discardableResult
    public func stopTeaching() async throws -> TeachingSession? { try await teachingReply(.stopTeaching) }

    public func cancelTeaching() async throws { _ = try await teachingReply(.cancelTeaching) }

    @discardableResult
    public func addTeachingNote(_ text: String) async throws -> TeachingSession? { try await teachingReply(.addTeachingNote(text)) }

    @discardableResult
    public func removeTeachingEvents(_ ids: [Int]) async throws -> TeachingSession? { try await teachingReply(.removeTeachingEvents(ids)) }

    @discardableResult
    public func loadTeaching() async throws -> TeachingSession? { try await teachingReply(.getTeaching) }

    /// Drafts a provisional skill from the stopped demonstration; the model call can take a while.
    public func draftSkillFromTeaching(goal: String? = nil) async throws -> Skill {
        let r = try await send(.draftSkillFromTeaching(goal: goal), timeout: 300)
        guard case .skill(let skill) = r else { throw HostSessionError.unexpectedReply }
        state.apply(event: HostEvent(seq: 0, payload: .skillUpserted(skill)))
        return skill
    }

    private func teachingReply(_ command: CommandBody) async throws -> TeachingSession? {
        let r = try await send(command, timeout: 30)
        guard case .teaching(let t) = r else { throw HostSessionError.unexpectedReply }
        state.teaching = t
        return t
    }

    public func deleteSkills(_ ids: [SkillID]) async throws {
        _ = try await send(.deleteSkills(ids), timeout: 60)
        try await loadSkills()
    }

    public func addSkillFolder(_ path: String) async throws -> [SkillLocation] {
        let r = try await send(.addSkillFolder(path: path), timeout: 60)
        guard case .skillLocations(let locations) = r else { throw HostSessionError.unexpectedReply }
        return locations
    }

    public func removeSkillFolder(_ path: String) async throws -> [SkillLocation] {
        let r = try await send(.removeSkillFolder(path: path), timeout: 60)
        guard case .skillLocations(let locations) = r else { throw HostSessionError.unexpectedReply }
        return locations
    }

    public func scanSkillLocations() async throws -> [SkillLocation] {
        let r = try await send(.scanSkillLocations, timeout: 60)
        guard case .skillLocations(let locations) = r else { throw HostSessionError.unexpectedReply }
        return locations
    }

    public func screenshot(maxWidth: Int = 1440) async throws -> Data {
        let r = try await send(.captureScreenshot(maxWidth: maxWidth))
        guard case .screenshot(_, let b64) = r, let data = Data(base64Encoded: b64) else { throw HostSessionError.unexpectedReply }
        return data
    }
}
