import PennantCore
import Foundation
import Network
import Observation

/// A host found on the local network via Bonjour.
public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public var id: String { serviceName }
    public var serviceName: String
    /// Resolved address, once the service has been looked up.
    public var endpoint: HostEndpoint?
    public var isResolving: Bool

    public init(serviceName: String, endpoint: HostEndpoint? = nil, isResolving: Bool = false) {
        self.serviceName = serviceName
        self.endpoint = endpoint
        self.isResolving = isResolving
    }
}

/// Browses for `_pennant._tcp` hosts on the local network and resolves them to host/port endpoints.
@MainActor
@Observable
public final class HostDiscovery {
    public private(set) var hosts: [DiscoveredHost] = []
    public private(set) var isBrowsing = false
    public private(set) var lastError: String?

    private var browser: NWBrowser?
    private var resolveTasks: [String: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "dev.pennant.client.discovery")

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PennantVersion.bonjourServiceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready: self.isBrowsing = true; self.lastError = nil
                case .failed(let error): self.isBrowsing = false; self.lastError = "\(error)"
                case .cancelled: self.isBrowsing = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries: [(String, String, NWEndpoint, String?, Int?, String?)] = results.compactMap { result in
                guard case .service(let name, _, let domain, _) = result.endpoint else { return nil }
                var advertisedIPv4: String?, tlsPort: Int?, fingerprint: String?
                if case .bonjour(let txt) = result.metadata {
                    if case .string(let value)? = txt.getEntry(for: "ipv4") { advertisedIPv4 = value }
                    if case .string(let value)? = txt.getEntry(for: "tls") { tlsPort = Int(value) }
                    if case .string(let value)? = txt.getEntry(for: "fp") { fingerprint = value }
                }
                return (name, domain, result.endpoint, advertisedIPv4, tlsPort, fingerprint)
            }
            Task { @MainActor [weak self] in
                self?.apply(entries)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for task in resolveTasks.values { task.cancel() }
        resolveTasks.removeAll()
        isBrowsing = false
    }

    private func apply(_ entries: [(name: String, domain: String, endpoint: NWEndpoint, advertisedIPv4: String?, tlsPort: Int?, fingerprint: String?)]) {
        let names = Set(entries.map(\.name))
        hosts.removeAll { !names.contains($0.serviceName) }
        for task in resolveTasks where !names.contains(task.key) {
            task.value.cancel()
            resolveTasks[task.key] = nil
        }
        for entry in entries where !hosts.contains(where: { $0.serviceName == entry.name }) {
            hosts.append(DiscoveredHost(serviceName: entry.name, isResolving: true))
            resolve(name: entry.name, endpoint: entry.endpoint, advertisedIPv4: entry.advertisedIPv4, tlsPort: entry.tlsPort, fingerprint: entry.fingerprint)
        }
        hosts.sort { $0.serviceName < $1.serviceName }
    }

    private func resolve(name: String, endpoint: NWEndpoint, advertisedIPv4: String?, tlsPort: Int?, fingerprint: String?) {
        resolveTasks[name]?.cancel()
        resolveTasks[name] = Task { [weak self] in
            var resolved = await Self.resolve(service: endpoint, name: name, advertisedIPv4: advertisedIPv4)
            // The encrypted port and certificate the host advertised: checked on the first encrypted connection.
            resolved?.tlsPort = tlsPort
            resolved?.fingerprint = fingerprint
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let index = self.hosts.firstIndex(where: { $0.serviceName == name }) else { return }
                self.hosts[index].endpoint = resolved
                self.hosts[index].isResolving = false
                self.resolveTasks[name] = nil
            }
        }
    }

    /// Resolves a Bonjour service to a concrete host/port by opening a short-lived TCP connection
    /// and reading the remote endpoint of the chosen path. Prefers an IPv4 path: link-local IPv6
    /// (the usual fallback pick) is not a reliably connectable endpoint for a longer-lived socket.
    public nonisolated static func resolve(service endpoint: NWEndpoint, name: String, advertisedIPv4: String? = nil, timeout: TimeInterval = 5) async -> HostEndpoint? {
        let v4Params = NWParameters.tcp
        if let ip = v4Params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        if let v4 = await connect(service: endpoint, name: name, params: v4Params, timeout: timeout) { return v4 }
        let probed = await connect(service: endpoint, name: name, params: .tcp, timeout: timeout)
        // Only link-local IPv6 was reachable by probing; take the IPv4 the host advertised in its
        // TXT record, keeping the real port from the probe.
        if let probed, probed.host.lowercased().hasPrefix("fe80"), let advertisedIPv4 {
            return HostEndpoint(host: advertisedIPv4, port: probed.port, name: name)
        }
        return probed
    }

    private nonisolated static func connect(service endpoint: NWEndpoint, name: String, params: NWParameters, timeout: TimeInterval) async -> HostEndpoint? {
        let connection = NWConnection(to: endpoint, using: params)
        let once = OnceFlag()
        let queue = DispatchQueue(label: "dev.pennant.client.resolve")
        return await withCheckedContinuation { (continuation: CheckedContinuation<HostEndpoint?, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.trip() else { return }
                    var result: HostEndpoint?
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        result = HostEndpoint(host: Self.hostString(host), port: Int(port.rawValue), name: name)
                    }
                    connection.cancel()
                    continuation.resume(returning: result)
                case .failed, .cancelled:
                    if once.trip() { continuation.resume(returning: nil) }
                case .waiting:
                    if once.trip() {
                        connection.cancel()
                        continuation.resume(returning: nil)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.trip() {
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func hostString(_ host: NWEndpoint.Host) -> String {
        // Link-local IPv6 arrives with an interface zone ("fe80::1%en0") that must be kept for the
        // address to be routable ("HostEndpoint.url" brackets and escapes it). An IPv4 zone is
        // cosmetic only, so drop it to keep stored endpoints clean.
        func stripZone(_ text: String) -> String { text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text }
        switch host {
        case .ipv4(let address):
            return stripZone("\(address)")
        case .ipv6(let address):
            return "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
