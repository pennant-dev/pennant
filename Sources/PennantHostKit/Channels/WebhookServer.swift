import PennantCore
import Foundation
import Network

/// A small HTTP server for webhooks (Teams), on this Mac's loopback only: a tunnel (Tailscale Funnel) forwards the
/// one public path to it, so nothing else Pennant serves is exposed. One request per connection, 1 MB at most.
actor WebhookServer {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
        var query: String = ""
        func header(_ name: String) -> String? { headers[name.lowercased()] }
        /// A query parameter, percent-decoded.
        func parameter(_ name: String) -> String? {
            URLComponents(string: "x:/?" + query)?.queryItems?.first { $0.name == name }?.value
        }
    }

    struct Response: Sendable {
        var status: Int
        var body: Data = Data()
        var headers: [String: String] = [:]
        static let ok = Response(status: 200)
        static let notFound = Response(status: 404)
        static let unauthorized = Response(status: 401)
    }

    typealias Handler = @Sendable (Request) async -> Response

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.pennant.host.webhooks")
    static let maxBody = 1 << 20

    /// Starts on 127.0.0.1:`port`; returns the bound port.
    @discardableResult
    func start(port: UInt16, handler: @escaping Handler) async throws -> UInt16 {
        // The old listener must have let go of the port first: a new one started while it's still closing
        // sits in .waiting (address in use) and never becomes ready.
        await stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task { await WebhookServer.serve(connection, handler: handler) }
        }
        let once = OnceGate()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.open() { c.resume() }
                case .failed(let e), .waiting(let e):
                    if once.open() { listener.cancel(); c.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        return listener.port?.rawValue ?? port
    }

    /// Stops listening; returns once the port is released.
    func stop() async {
        guard let old = listener else { return }
        listener = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = OnceGate()
            old.stateUpdateHandler = { state in
                if case .cancelled = state, once.open() { c.resume() }
            }
            old.cancel()
        }
    }

    private static func serve(_ connection: NWConnection, handler: Handler) async {
        defer { connection.cancel() }
        var buffer = Data()
        // Headers first.
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard buffer.count < 64 * 1024, let chunk = await receive(connection), !chunk.isEmpty else { return }
            buffer.append(chunk)
        }
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)), let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { return }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBody else { await respond(connection, Response(status: 413)); return }
        var body = Data(buffer[split.upperBound...])
        while body.count < length {
            guard let chunk = await receive(connection), !chunk.isEmpty else { return }
            body.append(chunk)
        }
        let target = String(requestLine[1])
        let path = target.components(separatedBy: "?").first ?? "/"
        let query = target.contains("?") ? String(target[target.index(after: target.firstIndex(of: "?")!)...]) : ""
        let response = await handler(Request(method: String(requestLine[0]), path: path, headers: headers, body: body.prefix(length), query: query))
        await respond(connection, response)
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                c.resume(returning: error == nil ? data : nil)
            }
        }
    }

    private static func respond(_ connection: NWConnection, _ r: Response) async {
        let reason = [200: "OK", 202: "Accepted", 302: "Found", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large"][r.status] ?? "Status"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        if !r.body.isEmpty, r.headers["Content-Type"] == nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in r.headers.sorted(by: { $0.key < $1.key }) where !k.contains("\r") && !v.contains("\r") && !v.contains("\n") { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { _ in c.resume() })
        }
    }
}

/// Lets a continuation resume once.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func open() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
