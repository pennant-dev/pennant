import PennantClientKit
import PennantCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// macOS privacy permissions the host needs, with request and deep-link actions.
/// Polls the host every 2 s while visible so grants show up without a restart of the view.
public struct PermissionsView: View {
    @Environment(\.hostSession) private var session
    var readOnly: Bool
    var onRestartHost: (() async -> Void)?
    @State private var busy: Set<String> = []
    @State private var rechecking = false
    @State private var lastChecked: Date?
    @State private var error: String?
    @State private var screenRecordingAtAppear: Bool?
    @State private var restarting = false

    public init(readOnly: Bool = false, onRestartHost: (() async -> Void)? = nil) {
        self.readOnly = readOnly
        self.onRestartHost = onRestartHost
    }

    private var permissions: DesktopPermissions { session.state.desktop.permissions }

    private struct Row: Identifiable {
        var id: String
        var title: String
        var detail: String
        var symbol: String
        var state: PermissionState
        var settingsPane: String
    }

    private var rows: [Row] {
        var out: [Row] = [
            Row(id: "accessibility", title: "Accessibility", detail: "Synthesizes clicks and keystrokes, reads app interfaces.", symbol: "accessibility", state: permissions.accessibility ? .granted : .denied, settingsPane: "Privacy_Accessibility"),
            Row(id: "screenRecording", title: "Screen Recording", detail: "Screenshots and the live computer panel.", symbol: "rectangle.dashed.badge.record", state: permissions.screenRecording ? .granted : .denied, settingsPane: "Privacy_ScreenCapture"),
            Row(id: "inputMonitoring", title: "Input Monitoring", detail: "Detects when you use the mouse or keyboard so agents pause.", symbol: "keyboard", state: permissions.inputMonitoring ? .granted : .denied, settingsPane: "Privacy_ListenEvent"),
        ]
        for (bundleID, state) in permissions.automationTargets.sorted(by: { Self.displayName($0.key) < Self.displayName($1.key) }) {
            out.append(Row(id: bundleID, title: "Automation: \(Self.displayName(bundleID))", detail: bundleID, symbol: "app.connected.to.app.below.fill", state: state, settingsPane: "Privacy_Automation"))
        }
        return out
    }

    static func displayName(_ bundleID: String) -> String {
        switch bundleID.lowercased() {
        case "com.apple.systemevents": return "System Events"
        case "com.apple.safari": return "Safari"
        case "com.apple.finder": return "Finder"
        case "com.google.chrome": return "Google Chrome"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "com.apple.mail": return "Mail"
        case "com.apple.terminal": return "Terminal"
        default: return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            InspectorListCard(rows, rowPadding: 12) { row in permissionRow(row) }
            footer
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(InspectorTint.danger) }
        }
        .onAppear { if screenRecordingAtAppear == nil { screenRecordingAtAppear = permissions.screenRecording } }
        .task {
            // The host re-evaluates grants in a fresh helper process and restarts itself when a grant
            // needs that; this poll just keeps the rows current while the view is visible.
            while !Task.isCancelled {
                if session.connection.isConnected, (try? await session.refreshDesktopStatus()) != nil { lastChecked = Date() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var screenRecordingJustGranted: Bool {
        screenRecordingAtAppear == false && permissions.screenRecording
    }

    // MARK: Pieces

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: summarySymbol).foregroundStyle(summaryTint)
                Text(summaryText).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
            }
            Text("macOS attributes these grants to \(permissions.grantee.isEmpty ? "the host process" : "“\(permissions.grantee)”"), shown in System Settings as “Pennant”. Screen Recording takes effect after the host restarts.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
        }
    }

    private var summarySymbol: String {
        if permissions.allGranted { return "checkmark.seal.fill" }
        if !session.connection.isConnected { return "bolt.slash" }
        return "exclamationmark.triangle.fill"
    }

    private var summaryTint: Color {
        if permissions.allGranted { return InspectorTint.success }
        if !session.connection.isConnected { return PennantTheme.inkTertiary }
        return InspectorTint.warning
    }

    private var summaryText: String {
        if permissions.allGranted { return "All permissions granted. Agents can use this Mac fully." }
        if !session.connection.isConnected { return "Connect to the host to see its permissions." }
        return "Missing: \(permissions.missing.joined(separator: ", "))"
    }

    private func permissionRow(_ row: Row) -> some View {
        HStack(alignment: .center, spacing: 12) {
            InspectorTintedSymbol(symbol: row.symbol, tint: tint(row.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink)
                Text(row.detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Chip(label(row.state), color: tint(row.state))
            if !readOnly {
                if row.state == .granted {
                    Button("Re-check") { recheck() }
                        .buttonStyle(.pennantCompact)
                        .disabled(rechecking || !session.connection.isConnected)
                } else {
                    Button("Grant") { request([row.id]) }
                        .buttonStyle(.pennantCompact)
                        .disabled(busy.contains(row.id) || !session.connection.isConnected)
                }
                if showsMenu(row) {
                    Menu {
                        if row.state != .granted {
                            Button("Reset and ask again") { resetAndRequest(row.id) }
                                .disabled(busy.contains(row.id) || !session.connection.isConnected)
                        }
                        #if os(macOS)
                        Button("Open System Settings…") { openSettings(row.settingsPane) }
                        #endif
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.pennantIcon)
                    .menuIndicator(.hidden)
                    .help(row.state == .granted ? "Open System Settings" : "Clears this host's entry in Privacy & Security so macOS shows the prompt again. Use it when an old entry is stuck or you clicked Deny.")
                    .accessibilityLabel("More options")
                }
            }
        }
    }

    private func showsMenu(_ row: Row) -> Bool {
        #if os(macOS)
        return true
        #else
        return row.state != .granted
        #endif
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Grant all") { request([]) }
                .buttonStyle(.pennantPrimaryCompact)
                .disabled(busy.contains("*") || !session.connection.isConnected || permissions.allGranted)
            Button(rechecking ? "Checking…" : "Re-check") { recheck() }
                .buttonStyle(.pennantCompact)
                .disabled(rechecking || !session.connection.isConnected)
            if screenRecordingJustGranted, let onRestartHost {
                Button("Restart host") {
                    restarting = true
                    Task { await onRestartHost(); restarting = false; screenRecordingAtAppear = true }
                }
                .buttonStyle(.pennantPrimaryCompact)
                .disabled(restarting)
            }
            if let lastChecked {
                Text("Checked \(relativeTime(lastChecked))").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    private func recheck() {
        rechecking = true
        Task {
            do { _ = try await session.recheckPermissions(); error = nil }
            catch { self.error = String(describing: error) }
            lastChecked = Date()
            rechecking = false
        }
    }

    private func resetAndRequest(_ id: String) {
        busy.insert(id)
        Task {
            do {
                _ = try await session.resetPermission(id)
                _ = try await session.requestPermissions([id])
                error = nil
            } catch { self.error = String(describing: error) }
            busy.remove(id)
        }
    }

    private func request(_ targets: [String]) {
        let key = targets.first ?? "*"
        busy.insert(key)
        error = nil
        Task {
            defer { busy.remove(key) }
            do { try await session.requestPermissions(targets) } catch { self.error = String(describing: error) }
        }
    }

    #if os(macOS)
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    #endif

    private func tint(_ s: PermissionState) -> Color {
        switch s {
        case .granted: return InspectorTint.success
        case .denied: return InspectorTint.warning
        case .notDetermined: return PennantTheme.inkSecondary
        case .unknown: return PennantTheme.inkTertiary
        }
    }

    private func label(_ s: PermissionState) -> String {
        switch s {
        case .granted: return "Granted"
        case .denied: return "Missing"
        case .notDetermined: return "Not asked"
        case .unknown: return "Unknown"
        }
    }
}

/// Sheet wrapper with a "Later" action for the automatic first-connect prompt.
public struct PermissionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onRestartHost: (() async -> Void)?
    var onLater: () -> Void

    public init(onRestartHost: (() async -> Void)? = nil, onLater: @escaping () -> Void) {
        self.onRestartHost = onRestartHost
        self.onLater = onLater
    }

    public var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Permissions")
            InspectorHairline(inset: 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pennant needs a few macOS permissions before agents can use this Mac. Grant them now or come back later in Settings › Permissions.")
                        .font(.zoomed(.callout))
                        .foregroundStyle(PennantTheme.inkSecondary)
                    PermissionsView(onRestartHost: onRestartHost)
                }
                .padding(20)
            }
            InspectorHairline(inset: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("Later") { onLater(); dismiss() }
                    .buttonStyle(.pennantSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { dismiss() }
                    .buttonStyle(.pennantPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
        .frame(minWidth: 620, minHeight: 460)
    }
}

/// One dismissible line for the newest warning notice about permissions, with a "Fix" action.
public struct PermissionNoticeLine: View {
    @Environment(\.hostSession) private var session
    var onFix: () -> Void
    @State private var dismissed: Set<UUID> = []

    public init(onFix: @escaping () -> Void) { self.onFix = onFix }

    private var notice: ClientState.Notice? {
        session.state.notices.last { $0.level == .warning && $0.text.localizedCaseInsensitiveContains("permission") && !dismissed.contains($0.id) }
    }

    public var body: some View {
        if let notice {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(InspectorTint.warning)
                Text(notice.text).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).lineLimit(2)
                Spacer()
                Button("Fix") { onFix() }.buttonStyle(.pennantPrimaryCompact)
                Button { dismissed.insert(notice.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.pennantIcon)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(InspectorTint.warning.opacity(0.10))
        }
    }
}
