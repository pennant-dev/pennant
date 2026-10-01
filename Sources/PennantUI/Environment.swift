import PennantClientKit
import PennantCore
import SwiftUI

/// A transport that never connects. Used as the environment default and in previews.
public final class NoopTransport: HostTransport, @unchecked Sendable {
    public init() {}
    public func open(endpoint: HostEndpoint) async throws -> AsyncStream<TransportInbound> {
        throw ProtocolError.notConnected
    }
    public func send(_ message: WireMessage) async throws { throw ProtocolError.notConnected }
    public func close() async {}
}

private struct HostSessionKey: EnvironmentKey {
    static let defaultValue: HostSession = {
        MainActor.assumeIsolated {
            HostSession(transport: NoopTransport(), displayName: "Preview", platform: "preview")
        }
    }()
}

public extension EnvironmentValues {
    /// The app's connection to the host. Set once at the root with `.hostSession(_:)`.
    var hostSession: HostSession {
        get { self[HostSessionKey.self] }
        set { self[HostSessionKey.self] = newValue }
    }
}

public extension View {
    func hostSession(_ session: HostSession) -> some View {
        environment(\.hostSession, session).environment(session)
    }
}
