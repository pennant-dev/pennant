import Network
import PennantCore
import Foundation

/// The link to Pennant's extension in the owner's Chrome: a WebSocket on this Mac only (127.0.0.1:7339) that takes one
/// connection, and only from the extension itself (its fixed id, in the Origin header Chrome sets and web pages can't).
/// The host sends actions ("open this page", "click element 12"), the extension does them in Pennant's own tabs with
/// Chrome's own input (never the owner's pointer), and answers. It also says where it's working on screen, so Pennant's
/// cursor is drawn there.
/// What the web tools need of the link (a stand-in in tests).
public protocol BrowserLinking: Sendable {
    func request(_ action: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue
}

extension BrowserLinking {
    func request(_ action: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await request(action, params, timeout: 60)
    }
}

public actor BrowserLink: BrowserLinking {
    public static let port: UInt16 = 7339
    /// The extension's id, fixed by the public key in its manifest.
    public static let extensionID = "dlfbggnpfmflkimllpinbaddpppjocba"
    static let origin = "chrome-extension://\(extensionID)"

    public struct Status: Sendable, Equatable {
        public var connected: Bool
        /// "Chrome 141", from the extension's hello.
        public var browser: String?
        public var version: String?
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private(set) var status = Status(connected: false)
    /// The copy of the extension Chrome should load, and the build it was stamped with.
    private(set) var installed: (folder: URL, build: String)?
    /// The out-of-date build last asked to reload, so a copy that can't pick up the new files isn't asked forever.
    private var reloadAsked: String?
    private let queue = DispatchQueue(label: "dev.pennant.browserlink")
    /// Where the extension is working on screen: Pennant's cursor goes there.
    private let onCursor: @Sendable (Double, Double, Bool) async -> Void

    public init(onCursor: @escaping @Sendable (Double, Double, Bool) async -> Void) {
        self.onCursor = onCursor
    }

    public func currentStatus() -> Status { status }

    func setInstalled(folder: URL, build: String) { installed = (folder, build) }

    public func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 32 * 1024 * 1024
        // Only Pennant's extension: Chrome sets the Origin of an extension's socket, and pages can't pose as one.
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value
            return NWProtocolWebSocket.Response(status: origin == Self.origin ? .accept : .reject, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                Task { await self.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { log.warn("Chrome link stopped listening: \(error)", category: "browser") }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log.warn("Chrome link couldn't listen on \(Self.port): \(error)", category: "browser")
        }
    }

    public func stop() {
        listener?.cancel()
        connection?.cancel()
        listener = nil
        connection = nil
        failAll(ToolError.failed("Pennant stopped"))
    }

    /// One action in the extension; its result, or why it failed.
    public func request(_ action: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard let connection, status.connected else { throw BrowserLinkError.notConnected }
        let id = UUID().uuidString
        let data = try JSONEncoder().encode(JSONValue.object(["id": .string(id), "action": .string(action), "params": params]))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.resolve(id, .failure(BrowserLinkError.timedOut(action)))
        }
        return try await withCheckedThrowingContinuation { continuation in
            Task { await self.register(id, continuation, send: data, on: connection) }
        }
    }

    private func register(_ id: String, _ continuation: CheckedContinuation<JSONValue, Error>, send data: Data, on connection: NWConnection) {
        pending[id] = continuation
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { Task { await self?.resolve(id, .failure(error)) } }
        })
    }

    private func resolve(_ id: String, _ result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending = [:]
        for (_, c) in all { c.resume(throwing: error) }
    }

    // MARK: Connection

    private func accept(_ new: NWConnection) {
        // One extension at a time: a new one (Chrome restarted, the extension reloaded) takes over.
        connection?.cancel()
        failAll(BrowserLinkError.notConnected)
        connection = new
        new.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.closed(new) }
            default: break
            }
        }
        new.start(queue: queue)
        Task { await receive(on: new) }
    }

    private func closed(_ old: NWConnection) {
        guard old === connection else { return }
        connection = nil
        status = Status(connected: false)
        failAll(BrowserLinkError.notConnected)
        log.info("Chrome extension disconnected", category: "browser")
    }

    private func receive(on conn: NWConnection) async {
        while true {
            let data: Data? = await withCheckedContinuation { continuation in
                conn.receiveMessage { content, _, _, error in
                    continuation.resume(returning: error == nil ? (content ?? Data()) : nil)
                }
            }
            guard let data, conn === connection else { closed(conn); return }
            guard !data.isEmpty, let message = try? JSONValue.from(data) else { continue }
            await handle(message)
        }
    }

    private func handle(_ message: JSONValue) async {
        if let event = message["event"]?.stringValue {
            switch event {
            case "hello":
                status = Status(connected: true, browser: message["browser"]?.stringValue, version: message["version"]?.stringValue)
                log.info("Chrome extension connected (\(status.browser ?? "Chrome"), extension \(status.version ?? "?") build \(message["build"]?.stringValue ?? "?"))", category: "browser")
                // Pennant was updated since Chrome loaded its copy: Chrome starts it again from the new files.
                if let build = message["build"]?.stringValue, build != "source", let installed, build != installed.build, reloadAsked != build {
                    reloadAsked = build
                    log.info("Chrome extension \(build) is out of date; reloading it as \(installed.build)", category: "browser")
                    Task { _ = try? await self.request("reload", .object([:]), timeout: 3) }
                }
            case "cursor":
                if let x = message["x"]?.doubleValue, let y = message["y"]?.doubleValue {
                    await onCursor(x, y, message["click"]?.boolValue ?? false)
                }
            default:
                break
            }
            return
        }
        guard let id = message["id"]?.stringValue else { return }
        if message["ok"]?.boolValue == true {
            resolve(id, .success(message["result"] ?? .null))
        } else {
            resolve(id, .failure(BrowserLinkError.failed(message["error"]?.stringValue ?? "The extension couldn't do that")))
        }
    }
}

public enum BrowserLinkError: Error, CustomStringConvertible {
    case notConnected, timedOut(String), failed(String)
    public var description: String {
        switch self {
        case .notConnected: return "Pennant's Chrome extension isn't connected: Chrome isn't open, or the extension isn't added (Settings › Pennant › Chrome)."
        case .timedOut(let action): return "Chrome didn't answer \(action) in time."
        case .failed(let why): return why
        }
    }
}
