import PennantCore
import Foundation
import MCP
import System

/// Owns MCP server processes and connections. Tools are registered with the broker as they connect
/// and removed when a server disconnects. Credentials for HTTP servers come from the Keychain.
public actor MCPManager {
    struct Connection {
        var client: Client
        var process: Process?
        var status: MCPServerStatus
        /// The in-process server of a built-in connector.
        var server: Server? = nil
    }

    let store: any StoreProtocol
    let eventBus: EventBus
    let broker: ToolBroker
    let credentials: any MCPCredentialStore
    /// Stateless OAuth helper (discovery, registration, token endpoint); flows live in `pendingAuths`.
    let oauth: MCPOAuthClient
    var connections: [MCPServerID: Connection] = [:]
    var statuses: [MCPServerID: MCPServerStatus] = [:]
    /// One browser flow per server; a new `beginAuth` replaces the old one.
    var pendingAuths: [MCPServerID: PendingAuth] = [:]
    /// In-flight token refreshes, so concurrent 401s share one refresh.
    var refreshTasks: [MCPServerID: Task<AccessToken?, Never>] = [:]
    /// Connections that failed for a moment (offline, a provider's bad minute), waiting to try again by themselves.
    var retries: [MCPServerID: Task<Void, Never>] = [:]
    var retryCounts: [MCPServerID: Int] = [:]
    /// The first retry's wait; each one after waits twice as long, up to five minutes.
    let retryBase: TimeInterval
    static let maxRetries = 8

    public init(store: any StoreProtocol, eventBus: EventBus, broker: ToolBroker, credentials: any MCPCredentialStore = InMemoryCredentialStore(), retryBase: TimeInterval = 30) {
        self.retryBase = retryBase
        self.store = store
        self.eventBus = eventBus
        self.broker = broker
        self.credentials = credentials
        self.oauth = MCPOAuthClient()
    }

    // Authentication (beginAuth, completeAuth, cancelAuth, setCredential, signOut) lives in MCPManager+Auth.swift.

    public func start() async {
        let configs = (try? await store.listMCPServers()) ?? []
        for config in configs {
            let (authState, authDetail) = derivedAuth(for: config)
            statuses[config.id] = MCPServerStatus(config: config, authState: authState, authDetail: authDetail)
            if config.enabled { await connect(config) }
        }
    }

    public func stop() async {
        for id in Array(retries.keys) { cancelRetry(id) }
        for id in Array(pendingAuths.keys) { clearPending(id) }
        for id in Array(connections.keys) { await disconnect(id) }
    }

    public func allStatuses() -> [MCPServerStatus] { statuses.values.sorted { $0.config.name < $1.config.name } }

    public func add(_ config: MCPServerConfig) async throws {
        try await store.upsertMCPServer(config)
        let (authState, authDetail) = derivedAuth(for: config)
        statuses[config.id] = MCPServerStatus(config: config, authState: authState, authDetail: authDetail)
        await publishStatus(config.id)
        if config.enabled { await connect(config) }
    }

    public func remove(_ id: MCPServerID) async throws {
        cancelRetry(id)
        clearPending(id)
        refreshTasks[id]?.cancel()
        refreshTasks[id] = nil
        await disconnect(id)
        if let config = statuses[id]?.config { forgetCredentials(config) }
        try await store.removeMCPServer(id)
        statuses[id] = nil
    }

    public func reconnect(_ id: MCPServerID) async {
        guard let config = statuses[id]?.config else { return }
        retryCounts[id] = nil
        await disconnect(id)
        await connect(config)
    }

    /// Drops trailing whitespace (typed or percent-encoded) from a server URL; a path ending in spaces is never intended.
    static func sanitized(_ url: URL) -> URL {
        var text = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("%20") || text.hasSuffix("%09") { text = String(text.dropLast(3)) }
        return URL(string: text) ?? url
    }

    // MARK: Connection lifecycle

    func connect(_ config: MCPServerConfig) async {
        cancelRetry(config.id)
        var status = statuses[config.id] ?? MCPServerStatus(config: config)
        status.state = .connecting
        status.lastError = nil
        statuses[config.id] = status
        await publishStatus(config.id)

        var client = Client(name: "Pennant", version: PennantVersion.string)
        var process: Process?
        var builtinServer: Server?
        var outcome: (state: MCPConnectionState, toolCount: Int, serverInfo: String?, error: String?)
        do {
            let result: Initialize.Result
            switch config.transport {
            case .builtin(let connectorID):
                guard let connector = NativeConnectors.make(connectorID) else {
                    throw MCPAuthError.discoveryFailed("this version of Pennant has no \(connectorID) connector")
                }
                if case .oauth = config.auth {
                    guard await accessTokenForConnect(config) != nil else { throw NeedsSignIn() }
                }
                let id = config.id
                let api = ConnectorAPI(
                    token: { [weak self] in try await self?.connectorToken(id) },
                    refresh: { [weak self] rejected in await self?.refreshAccessToken(id, rejected: rejected)?.token },
                    settings: config.settings
                )
                let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
                builtinServer = try await NativeConnectorServer.start(connector, api: api, transport: serverTransport)
                let c = client
                result = try await withTimeout(seconds: 30) { try await c.connect(transport: clientTransport) }
            case .stdio(let command, let arguments, let environment):
                let (p, t) = try Self.spawn(command: command, arguments: arguments, environment: environment)
                process = p
                let c = client
                result = try await withTimeout(seconds: 30) { try await c.connect(transport: t) }
            case .http(let rawURL):
                let url = Self.sanitized(rawURL)
                let makeTransport: @Sendable (Bool) -> HTTPClientTransport
                switch config.auth {
                case .none:
                    makeTransport = { streaming in HTTPClientTransport(endpoint: url, streaming: streaming) }
                case .apiKey(let header, let prefix):
                    guard let secret = credentialLookup(config) else {
                        await setAuth(config.id, .signedOut, nil)
                        throw NeedsSignIn()
                    }
                    makeTransport = { streaming in
                        HTTPClientTransport(endpoint: url, streaming: streaming, requestModifier: { request in
                            var r = request
                            r.setValue(prefix + secret, forHTTPHeaderField: header)
                            return r
                        })
                    }
                case .oauth:
                    // Refreshes first when the token is about to expire; a 401 mid-session refreshes once more.
                    guard let access = await accessTokenForConnect(config) else { throw NeedsSignIn() }
                    let authorizer = makeAuthorizer(for: config, token: access.token, expiresAt: access.expiresAt)
                    makeTransport = { streaming in HTTPClientTransport(endpoint: url, streaming: streaming, authorizer: authorizer) }
                }
                // Try with the server-to-client event stream first. A 405 on that GET is allowed by the spec (the SDK
                // reports it as "does not support streaming"), so fall back to plain request/response.
                do {
                    let c = client
                    let t = makeTransport(true)
                    result = try await withTimeout(seconds: 30) { try await c.connect(transport: t) }
                } catch let error where String(describing: error).localizedCaseInsensitiveContains("does not support streaming") {
                    log.info("MCP server \(config.name) has no event stream; connecting without one", category: "mcp")
                    await client.disconnect()
                    client = Client(name: "Pennant", version: PennantVersion.string)
                    let c = client
                    let t = makeTransport(false)
                    result = try await withTimeout(seconds: 30) { try await c.connect(transport: t) }
                }
            }
            let connected = client
            let (tools, _) = try await withTimeout(seconds: 30) { try await connected.listTools() }
            let wrapped = tools.map { MCPTool(serverID: config.id, serverName: config.name, tool: $0, client: client) }
            await broker.registerMCPTools(wrapped, server: config.id)
            outcome = (.connected, tools.count, "\(result.serverInfo.name) \(result.serverInfo.version)", nil)
            log.info("MCP server \(config.name) connected with \(tools.count) tools", category: "mcp")
        } catch is NeedsSignIn {
            // The SDK starts its receive loop before `initialize`; a client whose connect failed must be torn down
            // or that loop keeps re-reading a finished stream at full CPU.
            await client.disconnect()
            await builtinServer?.stop()
            process?.terminate()
            outcome = (.disconnected, 0, nil, nil)
            if statuses[config.id]?.authState != .signedIn { log.info("MCP server \(config.name) needs sign-in before it can connect", category: "mcp") }
        } catch {
            await client.disconnect()
            await builtinServer?.stop()
            process?.terminate()
            outcome = (.failed, 0, nil, String(describing: error))
            log.warn("MCP server \(config.name) failed: \(error)", category: "mcp")
        }
        // Re-read the status: a refresh during the connection may have changed the auth fields.
        var final = statuses[config.id] ?? status
        final.state = outcome.state
        final.toolCount = outcome.toolCount
        final.serverInfo = outcome.serverInfo
        final.lastError = outcome.error
        if outcome.state == .connected { connections[config.id] = Connection(client: client, process: process, status: final, server: builtinServer) }
        statuses[config.id] = final
        await publishStatus(config.id)
        scheduleRetry(config, final)
    }

    /// After a connection attempt: one that failed, or couldn't renew a sign-in that's still good, tries again by
    /// itself, after 30 s and then twice as long each time up to five minutes, eight times in all. A connection that
    /// needs the user to sign in waits for them.
    private func scheduleRetry(_ config: MCPServerConfig, _ status: MCPServerStatus) {
        let id = config.id
        let passing = status.state == .failed || (status.state == .disconnected && status.authState == .signedIn)
        guard config.enabled, passing else { retryCounts[id] = nil; return }
        let count = (retryCounts[id] ?? 0) + 1
        guard count <= Self.maxRetries else { return }
        retryCounts[id] = count
        let delay = min(retryBase * pow(2, Double(count - 1)), 300)
        log.info("MCP server \(config.name): trying again in \(Int(delay)) s (\(count) of \(Self.maxRetries))", category: "mcp")
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.retry(id)
        }
    }

    private func retry(_ id: MCPServerID) async {
        retries[id] = nil
        guard let config = statuses[id]?.config, config.enabled, connections[id] == nil, pendingAuths[id] == nil else { return }
        await connect(config)
    }

    func cancelRetry(_ id: MCPServerID) {
        retries.removeValue(forKey: id)?.cancel()
    }

    func disconnect(_ id: MCPServerID) async {
        guard let conn = connections.removeValue(forKey: id) else { return }
        await broker.unregisterMCPTools(server: id)
        await conn.client.disconnect()
        await conn.server?.stop()
        conn.process?.terminate()
        var status = statuses[id] ?? conn.status
        status.state = .disconnected
        status.toolCount = 0
        statuses[id] = status
        await publishStatus(id)
    }

    private static func spawn(command: String, arguments: [String], environment: [String: String]) throws -> (Process, StdioTransport) {
        let process = Process()
        let resolved = Self.resolveExecutable(command)
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        for (k, v) in environment { env[k] = v }
        process.environment = env
        let toChild = Pipe(), fromChild = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.standardError
        try process.run()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromChild.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toChild.fileHandleForWriting.fileDescriptor)
        )
        return (process, transport)
    }

    static func resolveExecutable(_ command: String) -> String {
        if command.hasPrefix("/") { return command }
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/env"
    }

    func publishStatus(_ id: MCPServerID) async {
        guard let status = statuses[id] else { return }
        if let event = try? await store.appendEvent(.mcpServerStatus(status)) { await eventBus.publish(event) }
    }
}

/// An MCP server tool exposed to the model. Names are prefixed with the server name to stay unique.
struct MCPTool: Tool {
    let serverID: MCPServerID
    let serverName: String
    let tool: MCP.Tool
    let client: Client

    var spec: ToolSpec {
        let safeServer = ToolBroker.connectionPrefix(serverName)
        let schema = (try? JSONValue.from(encodable: tool.inputSchema)) ?? JSONSchema.object([:])
        let destructive = tool.annotations.destructiveHint ?? true
        let readOnly = tool.annotations.readOnlyHint ?? false
        return ToolSpec(name: "\(safeServer)__\(tool.name)", description: "[\(serverName)] \(tool.description ?? tool.name)", inputSchema: schema, isConsequential: !readOnly && destructive, needsDesktop: false, source: "mcp:\(serverID.rawValue)")
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let args: [String: Value]? = try {
            guard case .object(let o) = arguments else { return nil }
            var converted: [String: Value] = [:]
            for (k, v) in o { converted[k] = try v.decode(Value.self) }
            return converted
        }()
        let client = self.client
        let toolName = tool.name
        let (content, isError) = try await withTimeout(seconds: 300) { try await client.callTool(name: toolName, arguments: args) }
        var parts: [ContentPart] = []
        for item in content {
            switch item {
            case .text(let text, _, _):
                parts.append(.text(text))
            case .image(let data, let mimeType, _, _):
                if let bytes = Data(base64Encoded: data) {
                    let record = ArtifactRecord(kind: "mcp-image", mimeType: mimeType, byteCount: bytes.count, fileName: "\(tool.name).img", taskID: context.taskID, agentID: context.agentID, caption: "Image from \(serverName)/\(tool.name)")
                    try await context.store.putArtifact(record, data: bytes)
                    parts.append(.image(ImageRef(artifactID: record.id, mimeType: mimeType, caption: record.caption)))
                }
            case .audio(_, let mimeType, _, _):
                parts.append(.text("[audio content \(mimeType) omitted]"))
            case .resource(let resource, _, _):
                parts.append(.text("[resource] " + JSONCodec.string(resource)))
            case .resourceLink(let uri, let name, _, let description, _, _):
                parts.append(.text("[resource link] \(name): \(uri) \(description ?? "")"))
            }
        }
        if parts.isEmpty { parts = [.text("(no content)")] }
        return ToolResult(callID: ToolCallID("pending"), name: spec.name, content: parts, isError: isError ?? false)
    }
}

/// Secrets for MCP servers, keyed by `MCPServerConfig.credentialKey`.
public protocol MCPCredentialStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, value: String) throws
    func delete(_ key: String)
}

public final class InMemoryCredentialStore: MCPCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ key: String, value: String) throws { lock.lock(); values[key] = value; lock.unlock() }
    public func delete(_ key: String) { lock.lock(); values[key] = nil; lock.unlock() }
}

public struct KeychainCredentialStore: MCPCredentialStore {
    let keychain: KeychainStore
    public init(keychain: KeychainStore) { self.keychain = keychain }
    public func get(_ key: String) -> String? { keychain.get(account: key) }
    public func set(_ key: String, value: String) throws { try keychain.set(account: key, value: value) }
    public func delete(_ key: String) { keychain.delete(account: key) }
}

public enum MCPAuthError: Error, Sendable, CustomStringConvertible {
    case notImplemented
    case notFound
    case notHTTP
    case noAuthConfigured
    case discoveryFailed(String)
    case registrationFailed(String)
    case tokenExchangeFailed(String)
    case stateMismatch
    case cancelled
    case listenerFailed(String)
    /// `completeAuth` was called with no flow in progress.
    case notPending
    case emptyCredential
    /// The authorization server sent the browser back with an `error`.
    case authorizationDenied(String)

    public var description: String {
        switch self {
        case .notImplemented: return "MCP authentication is not available in this build"
        case .notFound: return "MCP server not found"
        case .notHTTP: return "Only HTTP MCP servers can sign in"
        case .noAuthConfigured: return "This server has no sign-in method configured"
        case .discoveryFailed(let why): return "Could not discover the authorization server: \(why)"
        case .registrationFailed(let why): return "Client registration failed: \(why)"
        case .tokenExchangeFailed(let why): return "Token exchange failed: \(why)"
        case .stateMismatch: return "The sign-in reply did not match the request (state mismatch)"
        case .cancelled: return "Sign-in was cancelled"
        case .listenerFailed(let why): return "Could not listen for the browser redirect: \(why)"
        case .notPending: return "No sign-in is in progress for this server"
        case .emptyCredential: return "The secret is empty"
        case .authorizationDenied(let why): return "The authorization server refused the sign-in: \(why)"
        }
    }
}

