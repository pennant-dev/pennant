import PennantCore
import Foundation

public enum ConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    public var isConnected: Bool { self == .connected }
}

/// Endpoint of a host. Discovered via Bonjour, typed, or scanned from the Mac's connect code.
public struct HostEndpoint: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(host):\(port)" }
    public var host: String
    public var port: Int
    public var name: String
    public var useTLS: Bool
    /// The host's encrypted port (from Bonjour); nil means the one beside `port`.
    public var tlsPort: Int?
    /// The certificate fingerprint the host advertised (from Bonjour), checked on first contact. Pins win.
    public var fingerprint: String?
    /// Reached through Cloudflare Access (a tunnel to the host): wss on `port` with the usual certificate checks
    /// instead of pinning, and an Access token that also signs in.
    public var viaAccess: Bool?
    public var isAccess: Bool { viaAccess == true }
    /// Other addresses of the same host (its Tailscale name, its local address), learned from the host. Tried in turn
    /// when this one doesn't answer; each must present the certificate pinned for this one.
    public var alternates: [String]?

    /// This endpoint at another of its addresses.
    public func at(_ address: String) -> HostEndpoint {
        var e = self
        e.host = address
        e.alternates = nil
        return e
    }

    /// A host behind Cloudflare Access at `hostname`.
    public static func access(_ hostname: String) -> HostEndpoint {
        var e = HostEndpoint(host: hostname, port: 443, name: hostname, useTLS: true)
        e.viaAccess = true
        return e
    }

    public init(host: String, port: Int = 7331, name: String = "", useTLS: Bool = false, tlsPort: Int? = nil, fingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.name = name
        self.useTLS = useTLS
        self.tlsPort = tlsPort
        self.fingerprint = fingerprint
    }

    /// This Mac itself: nothing crosses a network, so no encryption is needed.
    public var isLoopback: Bool { ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()) }

    /// IPv6 literals need brackets and the zone id a percent-escape (RFC 6874) to form a valid URL;
    /// IPv4/name scopes carry no routing meaning and are dropped.
    public var url: URL? {
        var authority = host
        if host.contains(":") {
            let halves = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            let zone = halves.count > 1 && !halves[1].isEmpty ? "%25\(halves[1])" : ""
            authority = "[\(halves[0])]\(zone)"
        } else if let index = host.firstIndex(of: "%") {
            authority = String(host[..<index])
        }
        // Behind Cloudflare the app's socket has its own path; the rest of the address serves pages.
        return URL(string: "\(useTLS ? "wss" : "ws")://\(authority):\(port)/\(isAccess ? "socket" : "")")
    }
    public static let local = HostEndpoint(host: "127.0.0.1", port: 7331, name: "This Mac")
}

/// Incoming traffic from the host, already decoded.
public enum TransportInbound: Sendable {
    case message(WireMessage)
    case screenFrame(ScreenFrameHeader, Data)
    /// A piece of speech the host made for Talk mode (`speak`).
    case speech(SpeechChunkHeader, [Float])
    case closed(reason: String)
}

/// Transport-level connection to a host. `WebSocketTransport` implements it over Network.framework.
public protocol HostTransport: Sendable {
    /// Open the socket. Returns a stream of inbound traffic that finishes when the socket closes.
    func open(endpoint: HostEndpoint) async throws -> AsyncStream<TransportInbound>
    func send(_ message: WireMessage) async throws
    func close() async
}

/// The Mac's connect code, shown as a QR code and opened by the phone:
/// `pennant://connect?host=studio.tail1234.ts.net&port=7331&tls=7332&fp=<sha256>&name=Studio&alt=192.168.1.20`.
/// It carries the certificate fingerprint, so the first connection already knows which certificate to trust.
public extension HostEndpoint {
    var connectURL: URL? {
        var c = URLComponents()
        c.scheme = "pennant"
        c.host = "connect"
        var items = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port))]
        if let tlsPort { items.append(URLQueryItem(name: "tls", value: String(tlsPort))) }
        if let fingerprint { items.append(URLQueryItem(name: "fp", value: fingerprint)) }
        if !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        if let alternates, !alternates.isEmpty { items.append(URLQueryItem(name: "alt", value: alternates.joined(separator: ","))) }
        c.queryItems = items
        return c.url
    }

    init?(connectURL url: URL) {
        guard url.scheme == "pennant", url.host == "connect", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
        guard let host = value("host") else { return nil }
        let fingerprint = value("fp")?.lowercased()
        // A fingerprint is a SHA-256 in hex; anything else isn't one of ours.
        if let fingerprint, fingerprint.count != 64 || !fingerprint.allSatisfy(\.isHexDigit) { return nil }
        self.init(host: host, port: value("port").flatMap(Int.init) ?? 7331, name: value("name") ?? host, tlsPort: value("tls").flatMap(Int.init), fingerprint: fingerprint)
        alternates = value("alt")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != host }
    }
}
