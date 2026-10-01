import PennantCore
import CryptoKit
import Foundation
import Network
import Security

/// WebSocket transport over Network.framework. Text frames carry `WireMessage` JSON;
/// binary frames carry `ScreenFrameCodec` payloads. Works on macOS and iOS.
public final class WebSocketTransport: HostTransport, @unchecked Sendable {
    public static let maximumMessageSize = 32 * 1024 * 1024

    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: AsyncStream<TransportInbound>.Continuation?
    private let queue = DispatchQueue(label: "dev.pennant.client.ws", qos: .userInitiated)
    private let connectTimeout: TimeInterval

    private var _accessToken: String?
    /// For hosts behind Cloudflare Access: sent as `cf-access-token` when opening, so Access lets the socket through.
    public var accessToken: String? {
        get { lock.withLock { _accessToken } }
        set { lock.withLock { _accessToken = newValue } }
    }

    public init(connectTimeout: TimeInterval = 15) {
        self.connectTimeout = connectTimeout
    }

    /// Opens the host's encrypted port when it has one, else the plain port. The host's certificate is self-signed:
    /// the first encrypted connection pins its fingerprint (checked against what the host advertised on Bonjour, if
    /// anything), and after that only that certificate is accepted and the plain port is never used again for that
    /// host, so nobody on the network can downgrade or impersonate it. This Mac itself stays on the plain port.
    public func open(endpoint: HostEndpoint) async throws -> AsyncStream<TransportInbound> {
        await close()
        guard !endpoint.isLoopback || endpoint.useTLS else { return try await open(endpoint, tls: nil) }
        // Cloudflare's edge has a public certificate: the system checks it, nothing is pinned.
        if endpoint.isAccess { return try await open(endpoint, tls: nil, systemTLS: true) }
        let pinned = HostPins.pin(for: endpoint)
        var secure = endpoint
        secure.useTLS = true
        secure.port = endpoint.useTLS ? endpoint.port : (endpoint.tlsPort ?? endpoint.port + 1)
        let check = CertificateCheck(expected: pinned ?? endpoint.fingerprint)
        do {
            let stream = try await open(secure, tls: check, timeout: pinned == nil && !endpoint.useTLS ? min(connectTimeout, 6) : connectTimeout)
            if pinned == nil, let seen = check.seen { HostPins.set(seen, for: endpoint) }
            return stream
        } catch {
            if let seen = check.seen, let expected = check.expected, seen != expected { throw TransportError.certificateChanged(host: endpoint.name.isEmpty ? endpoint.host : endpoint.name) }
            // A host from before encryption: the plain port, but only if this device never had an encrypted link to it.
            guard pinned == nil, !endpoint.useTLS else { throw error }
            return try await open(endpoint, tls: nil)
        }
    }

    private func open(_ endpoint: HostEndpoint, tls check: CertificateCheck?, systemTLS: Bool = false, timeout: TimeInterval? = nil) async throws -> AsyncStream<TransportInbound> {
        let params: NWParameters
        if systemTLS {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else if let check {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                let ref = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let leaf = (SecTrustCopyCertificateChain(ref) as? [SecCertificate])?.first else { return complete(false) }
                let seen = HostPins.fingerprint(of: SecCertificateCopyData(leaf) as Data)
                check.seen = seen
                complete(check.expected == nil || check.expected == seen)
            }, queue)
            params = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maximumMessageSize
        if endpoint.isAccess, let token = accessToken, !token.isEmpty { ws.setAdditionalHeaders([("cf-access-token", token)]) }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        // The URL endpoint form is required for a proper WebSocket handshake (host:port fails against IP literals).
        guard let url = endpoint.url else { throw TransportError.badEndpoint(endpoint.host) }
        let connection = NWConnection(to: .url(url), using: params)
        setConnection(connection)

        let once = OnceFlag()
        let timeout = timeout ?? connectTimeout
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.trip() { ready.resume() }
                case .failed(let error):
                    if once.trip() { ready.resume(throwing: error) }
                case .cancelled:
                    if once.trip() { ready.resume(throwing: CancellationError()) }
                case .waiting(let error):
                    // No route yet (host asleep, network down). Surface it instead of waiting forever.
                    if once.trip() {
                        connection.cancel()
                        ready.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.trip() {
                    connection.cancel()
                    ready.resume(throwing: TransportError.timeout)
                }
            }
        }

        let (stream, continuation) = AsyncStream<TransportInbound>.makeStream(bufferingPolicy: .unbounded)
        setContinuation(continuation)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.finish(reason: "connection failed: \(error)")
            case .cancelled:
                self?.finish(reason: "connection cancelled")
            case .waiting(let error):
                self?.finish(reason: "connection lost: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        continuation.onTermination = { [weak self] _ in
            self?.finish(reason: "consumer stopped")
        }
        receiveNext(on: connection)
        return stream
    }

    public func send(_ message: WireMessage) async throws {
        guard let connection = currentConnection(), connection.state == .ready else { throw ProtocolError.notConnected }
        let data = try message.encoded()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func close() async {
        takeConnection()?.cancel()
        finish(reason: "closed")
    }

    // MARK: Private

    private func setConnection(_ connection: NWConnection) {
        lock.withLock { self.connection = connection }
    }

    private func currentConnection() -> NWConnection? {
        lock.withLock { connection }
    }

    private func takeConnection() -> NWConnection? {
        lock.withLock {
            let current = connection
            connection = nil
            return current
        }
    }

    private func setContinuation(_ continuation: AsyncStream<TransportInbound>.Continuation) {
        lock.withLock { self.continuation = continuation }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(reason: "receive error: \(error)")
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .close:
                self.finish(reason: "host closed the connection")
                return
            case .binary:
                if let content, let (header, jpeg) = try? ScreenFrameCodec.decode(content) {
                    self.yield(.screenFrame(header, jpeg))
                }
            case .text:
                if let content, let message = try? WireMessage.decode(content) {
                    self.yield(.message(message))
                }
            case .ping, .pong, .cont:
                break
            default:
                if content == nil, isComplete {
                    self.finish(reason: "end of stream")
                    return
                }
                if let content, let message = try? WireMessage.decode(content) {
                    self.yield(.message(message))
                }
            }
            self.receiveNext(on: connection)
        }
    }

    private func yield(_ item: TransportInbound) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(item)
    }

    private func finish(reason: String) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }
}

public enum TransportError: Error, Sendable, CustomStringConvertible {
    case timeout
    case badEndpoint(String)
    /// The host answered with a different certificate than the one this device trusted before.
    case certificateChanged(host: String)
    public var description: String {
        switch self {
        case .timeout: return "Connection timed out"
        case .badEndpoint(let host): return "The host address “\(host)” is not a valid endpoint"
        case .certificateChanged(let host): return "\(host) presented a different security certificate than before, so Pennant didn't connect. If you reinstalled Pennant on that Mac, forget the host on this device and pair again; otherwise someone on this network may be impersonating it."
        }
    }
}

/// What one encrypted connection expects of the host's certificate, and what it saw.
final class CertificateCheck: @unchecked Sendable {
    let expected: String?
    private let lock = NSLock()
    private var _seen: String?
    var seen: String? {
        get { lock.lock(); defer { lock.unlock() }; return _seen }
        set { lock.lock(); _seen = newValue; lock.unlock() }
    }
    init(expected: String?) { self.expected = expected }
}

/// Certificate fingerprints this device trusts, one per host address, pinned on the first encrypted connection.
public enum HostPins {
    private static let key = "pennant.hostCertificatePins"

    public static func pin(for endpoint: HostEndpoint) -> String? { all()[endpoint.id] }

    public static func set(_ fingerprint: String, for endpoint: HostEndpoint) {
        var pins = all()
        pins[endpoint.id] = fingerprint
        UserDefaults.standard.set(pins, forKey: key)
    }

    /// Forgets a host's certificate (after the host was reinstalled and paired again).
    public static func forget(_ endpoint: HostEndpoint) {
        var pins = all()
        pins[endpoint.id] = nil
        UserDefaults.standard.set(pins, forKey: key)
    }

    static func all() -> [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// Resume-once guard for continuations driven by state handlers that may fire repeatedly.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}
