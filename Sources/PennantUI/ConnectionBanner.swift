import PennantClientKit
import PennantCore
import SwiftUI

/// Honest connection state. A rounded inset banner at the top of the content when anything is off.
public struct ConnectionBanner: View {
    @Environment(\.hostSession) private var session
    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: Clock.anchor, by: 5)) { _ in
            if let (text, color, symbol) = descriptor {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                    Text(text).font(.zoomed(.callout)).lineLimit(2)
                    Spacer(minLength: 8)
                    if case .failed = session.connection {
                        Button("Retry") { session.connect() }.buttonStyle(.pennantCompact)
                    }
                }
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    /// Why it isn't connected, in words: a connection the system dropped (the app slept, the network changed) says so
    /// rather than showing the socket's error code.
    static func failure(_ why: String) -> String {
        let dropped = ["receive error", "POSIXErrorCode", "Socket is not connected", "connection abort", "Connection reset", "host closed the connection", "end of stream"]
        if dropped.contains(where: { why.localizedCaseInsensitiveContains($0) }) { return "The connection to your Mac dropped. It reconnects on its own, or tap Retry." }
        return "Not connected: \(why)"
    }

    private var descriptor: (String, Color, String)? {
        switch session.connection {
        case .connected:
            if session.state.isStale { return ("Connected, but no update from the host for a while. Shown state may be stale.", ShellPalette.warning, "clock.badge.exclamationmark") }
            return nil
        case .connecting: return ("Connecting to \(session.endpoint.name.isEmpty ? session.endpoint.host : session.endpoint.name)…", PennantTheme.inkSecondary, "antenna.radiowaves.left.and.right")
        case .reconnecting(let n): return ("Connection lost. Reconnecting (attempt \(n))… Work continues on the host.", ShellPalette.warning, "arrow.triangle.2.circlepath")
        case .failed(let why): return (Self.failure(why), ShellPalette.danger, "xmark.octagon")
        case .disconnected: return ("Disconnected from the host.", PennantTheme.inkSecondary, "bolt.slash")
        }
    }
}
