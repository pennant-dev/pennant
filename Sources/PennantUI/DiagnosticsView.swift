import PennantClientKit
import PennantCore
import SwiftUI

/// Raw host details for troubleshooting. Kept out of the main flow on purpose.
public struct DiagnosticsView: View {
    @Environment(\.hostSession) private var session
    @State private var report: DiagnosticsReport?
    @State private var error: String?
    @State private var loading = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection("Connection") {
                    Button { Task { await load() } } label: { Label(loading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.pennantCompact)
                        .disabled(loading)
                } content: {
                    InspectorListCard(connectionRows) { InspectorKeyValueRow(item: $0) }
                }
                if let r = report {
                    InspectorSection("Host") {
                        InspectorListCard(hostRows(r)) { InspectorKeyValueRow(item: $0) }
                    }
                    InspectorSection("Inference") {
                        InspectorListCard(inferenceRows(r)) { InspectorKeyValueRow(item: $0) }
                    }
                    InspectorSection("Storage") {
                        InspectorListCard(storageRows(r)) { InspectorKeyValueRow(item: $0) }
                    }
                    InspectorSection("Desktop") {
                        InspectorListCard(desktopRows) { InspectorKeyValueRow(item: $0) }
                    }
                    InspectorSection("Recent tool records") {
                        InspectorListCard(r.recentToolRecords, emptyText: "No tool calls yet") { rec in toolRecordRow(rec) }
                    }
                    InspectorSection("Tools (\(r.toolSpecs.count))") {
                        InspectorListCard(r.toolSpecs, emptyText: "No tools") { spec in toolSpecRow(spec) }
                    }
                } else if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading the host report…").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    }
                }
                InspectorSection("Notices") {
                    InspectorListCard(Array(session.state.notices.reversed()), emptyText: "Nothing yet") { n in noticeRow(n) }
                }
                if let error {
                    Text(error).font(.zoomed(.caption)).foregroundStyle(InspectorTint.danger).textSelection(.enabled)
                }
            }
            .padding(16)
        }
        .background(PennantTheme.panelBackground)
        .task { await load() }
    }

    // MARK: Rows

    private var connectionRows: [InspectorKeyValue] {
        var rows = [
            InspectorKeyValue(label: "Client", value: session.connectionLabel.capitalizedFirst),
            InspectorKeyValue(label: "Endpoint", value: "\(session.endpoint.host):\(session.endpoint.port)", style: .mono),
            InspectorKeyValue(label: "Last event", value: "#\(session.state.lastEventSeq)"),
        ]
        if let t = session.state.lastUpdateAt {
            rows.append(InspectorKeyValue(label: "Last update", value: t.formatted(date: .omitted, time: .standard)))
        }
        return rows
    }

    private func hostRows(_ r: DiagnosticsReport) -> [InspectorKeyValue] {
        [
            InspectorKeyValue(label: "Name", value: r.host.hostName),
            InspectorKeyValue(label: "Version", value: r.host.version),
            InspectorKeyValue(label: "Mode", value: r.host.mode.rawValue.capitalizedFirst),
            InspectorKeyValue(label: "Started", value: r.host.startedAt.formatted()),
            InspectorKeyValue(label: "Active tasks", value: "\(r.host.activeTaskCount)"),
            InspectorKeyValue(label: "Clients", value: "\(r.host.connectedClients)"),
        ]
    }

    private func inferenceRows(_ r: DiagnosticsReport) -> [InspectorKeyValue] {
        [
            InspectorKeyValue(label: "Endpoint", value: r.host.inferenceEndpoint, style: .mono),
            InspectorKeyValue(label: "Model", value: r.host.inferenceModel, style: .mono),
            InspectorKeyValue(label: "Status", value: r.host.inferenceReachable ? "Reachable" : "Unreachable", style: .chip(r.host.inferenceReachable ? InspectorTint.success : InspectorTint.danger)),
        ]
    }

    private func storageRows(_ r: DiagnosticsReport) -> [InspectorKeyValue] {
        [
            InspectorKeyValue(label: "Database", value: r.databasePath, style: .mono),
            InspectorKeyValue(label: "Artifacts", value: r.artifactDirectory, style: .mono),
            InspectorKeyValue(label: "Config", value: r.configPath, style: .mono),
            InspectorKeyValue(label: "Log", value: r.logPath, style: .mono),
            InspectorKeyValue(label: "Events", value: "\(r.eventCount)"),
            InspectorKeyValue(label: "Memory", value: "\(r.memory.entityCount) facts, \(r.memory.relationCount) relations, \(r.memory.preferenceCount) preferences, \(r.memory.messageCount) messages"),
        ]
    }

    private var desktopRows: [InspectorKeyValue] {
        let d = session.state.desktop
        func grant(_ ok: Bool) -> InspectorKeyValue.Style { .chip(ok ? InspectorTint.success : InspectorTint.warning) }
        return [
            InspectorKeyValue(label: "Accessibility", value: d.permissions.accessibility ? "Granted" : "Missing", style: grant(d.permissions.accessibility)),
            InspectorKeyValue(label: "Screen Recording", value: d.permissions.screenRecording ? "Granted" : "Missing", style: grant(d.permissions.screenRecording)),
            InspectorKeyValue(label: "Display", value: "\(d.displayWidth) × \(d.displayHeight) pt"),
            InspectorKeyValue(label: "Streaming clients", value: "\(d.streamingClients)"),
        ]
    }

    private func toolRecordRow(_ rec: ToolRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(rec.call.name).font(.zoomed(.caption).monospaced().weight(.medium)).foregroundStyle(PennantTheme.ink)
                Chip(rec.status.rawValue, color: rec.isError ? InspectorTint.danger : PennantTheme.inkSecondary)
                Spacer()
                Text(rec.startedAt.formatted(date: .omitted, time: .standard)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
            }
            Text(rec.call.arguments.compactText).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
            if !rec.resultSummary.isEmpty { Text(rec.resultSummary).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.ink).lineLimit(2) }
        }
    }

    private func toolSpecRow(_ spec: ToolSpec) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.description).font(.zoomed(.caption)).foregroundStyle(PennantTheme.ink)
                Text(spec.inputSchema.compactText).font(.zoomed(.caption2).monospaced()).foregroundStyle(PennantTheme.inkSecondary).textSelection(.enabled)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(spec.name).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.ink)
                Chip(spec.source)
                if spec.needsDesktop { Chip("desktop", color: InspectorTint.warning) }
                if spec.isConsequential { Chip("consequential", color: InspectorTint.danger) }
            }
        }
        .tint(PennantTheme.inkSecondary)
    }

    private func noticeRow(_ n: ClientState.Notice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: n.level == .error ? "xmark.octagon" : n.level == .warning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(n.level == .error ? InspectorTint.danger : n.level == .warning ? InspectorTint.warning : PennantTheme.inkSecondary)
                .frame(width: 16)
            Text(n.text).font(.zoomed(.caption)).foregroundStyle(PennantTheme.ink)
            Spacer()
            Text(n.at.formatted(date: .omitted, time: .standard)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { report = try await session.diagnostics(); error = nil } catch { self.error = String(describing: error) }
    }
}

public extension HostSession {
    var connectionLabel: String {
        switch connection {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .reconnecting(let n): return "reconnecting (\(n))"
        case .failed(let why): return "failed: \(why)"
        case .disconnected: return "disconnected"
        }
    }
}

private extension String {
    /// "connected" → "Connected"; leaves the rest of the string alone.
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
