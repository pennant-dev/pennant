import Foundation
import Network

/// The loopback redirect endpoint for OAuth sign-ins (RFC 8252 §7.3): an HTTP listener on 127.0.0.1 that answers
/// `GET <path>?code=…&state=…` with a small page and hands the query to `onCallback`. The path is `/callback` for MCP
/// servers and `/auth/callback` for the ChatGPT (Codex) sign-in, whose redirect URI is registered with OpenAI. Every
/// other path gets a 404 so a browser's favicon request cannot complete a flow. The first callback wins; later ones
/// see a "done" page. The listener stops when the manager finishes or cancels the flow.
final class LoopbackRedirectListener: @unchecked Sendable {
    struct Callback: Sendable, Equatable {
        var code: String?
        var state: String?
        var error: String?
        var errorDescription: String?

        init(code: String? = nil, state: String? = nil, error: String? = nil, errorDescription: String? = nil) {
            self.code = code; self.state = state; self.error = error; self.errorDescription = errorDescription
        }

        /// Reads the OAuth response parameters from a redirect URL's query.
        init(url: URL) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            self.init(code: value("code"), state: value("state"), error: value("error"), errorDescription: value("error_description"))
        }
    }

    /// The path MCP sign-ins use; other flows pass their own.
    static let defaultPath = "/callback"

    let serverName: String
    let path: String
    private let onCallback: @Sendable (Callback) -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.pennant.host.mcp.redirect")
    private let lock = NSLock()
    private var delivered = false
    private var stopped = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private(set) var port: UInt16 = 0

    /// - Parameters:
    ///   - port: A fixed port (the one a registered client was given), or nil for an ephemeral one.
    ///   - path: The request path that completes the flow; anything else is answered with a 404.
    ///   - serverName: Shown on the page the browser lands on.
    /// The host name written into the redirect URL ("127.0.0.1" or "localhost"); the socket is on 127.0.0.1 either way.
    let hostName: String

    init(port: UInt16?, path: String = LoopbackRedirectListener.defaultPath, hostName: String = "127.0.0.1", serverName: String, onCallback: @escaping @Sendable (Callback) -> Void) throws {
        self.hostName = hostName
        self.serverName = serverName
        self.path = path
        self.onCallback = onCallback
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPAuthError.listenerFailed(String(describing: error))
        }
    }

    var redirectURI: URL { URL(string: "http://\(hostName):\(port)\(path)")! }

    /// Binds the port; returns once the listener is ready.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); readyContinuation = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port?.rawValue ?? 0
                    self.resumeReady(nil)
                case .failed(let error):
                    self.resumeReady(MCPAuthError.listenerFailed(String(describing: error)))
                    self.listener.cancel()
                case .cancelled:
                    self.resumeReady(MCPAuthError.listenerFailed("listener cancelled"))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    private func resumeReady(_ error: Error?) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    /// Stops accepting connections. A reply still being written to the browser gets a moment to finish.
    func stop() {
        lock.lock()
        stopped = true
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        listener.cancel()
        queue.asyncAfter(deadline: .now() + 2) { for c in open { c.cancel() } }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if stopped { lock.unlock(); connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.forget(connection) }
            if case .cancelled = state { self?.forget(connection) }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(connection)] = nil; lock.unlock()
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.handle(requestHead: head, on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func handle(requestHead: String, on connection: NWConnection) {
        let requestLine = requestHead.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { respond(connection, status: "400 Bad Request", html: page(title: "Bad request", body: "")); return }
        let method = String(parts[0])
        let target = String(parts[1])
        guard let url = URL(string: "http://127.0.0.1" + target), url.path == path else {
            respond(connection, status: "404 Not Found", html: page(title: "Not found", body: "Nothing lives here."))
            return
        }
        guard method == "GET" else {
            respond(connection, status: "405 Method Not Allowed", html: page(title: "Not allowed", body: ""))
            return
        }
        let callback = Callback(url: url)
        lock.lock()
        let first = !delivered
        delivered = true
        lock.unlock()
        let name = Self.escape(serverName)
        if !first {
            respond(connection, status: "200 OK", html: page(title: "Already signed in", body: "<h1>This sign-in has already completed.</h1><p>You can close this tab and go back to Pennant.</p>"))
            return
        }
        if let error = callback.error {
            let detail = Self.escape(callback.errorDescription ?? error)
            respond(connection, status: "200 OK", html: page(title: "Sign-in did not complete", body: "<h1>Sign-in to \(name) did not complete.</h1><p>\(detail)</p><p>You can close this tab and try again from Pennant.</p>"))
        } else {
            respond(connection, status: "200 OK", html: page(title: "Signed in", body: "<h1>You are signed in to \(name).</h1><p>You can close this tab and go back to Pennant.</p>"))
        }
        onCallback(callback)
    }

    private func respond(_ connection: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.forget(connection)
        })
    }

    private func page(title: String, body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(Self.escape(title)) · Pennant</title>
        <style>body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;background:#f4f2ee;color:#1d1c1a;display:flex;min-height:100vh;align-items:center;justify-content:center}
        main{max-width:32rem;padding:2.5rem;background:#fff;border-radius:16px;box-shadow:0 8px 30px rgba(0,0,0,.08)}h1{font-size:1.4rem;margin:0 0 .75rem}p{margin:0 0 .5rem;line-height:1.5;color:#4a4744}
        @media (prefers-color-scheme:dark){body{background:#14130f;color:#f0ede6}main{background:#1f1d18}p{color:#b9b4aa}}</style></head><body><main>\(body)</main></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
