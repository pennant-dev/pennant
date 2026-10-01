import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Channels › iPhone notifications: the APNs key (from the Apple Developer account), the iPhones that
/// asked for notifications, and a test.
struct NotificationsSettingsCard: View {
    @Environment(\.hostSession) private var session
    @State private var status: PushStatus?
    @State private var choosing = false
    @State private var teamID = ""
    @State private var busy = false
    @State private var note: String?
    @State private var error: String?

    var body: some View {
        SettingsCard("iPhone notifications") {
            if let status {
                HStack(spacing: 6) {
                    Circle().fill(ready(status) ? SettingsTone.success : SettingsTone.warning).frame(width: 8, height: 8)
                    Text(summary(status)).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                }
                if !status.keyConfigured {
                    SettingsNote("Pennant sends notifications through Apple. It needs a push key from your Apple Developer account, once: in Certificates, IDs & Profiles › Keys, add a key, tick Apple Push Notifications service (APNs), download the .p8 file, and choose it here.")
                    if status.teamID == nil {
                        HStack(spacing: 8) {
                            Text("Team ID").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                            TextField("10 characters, top right of the developer site", text: $teamID).textFieldStyle(.plain).pennantField()
                        }
                    }
                    Button(busy ? "Saving…" : "Choose .p8 file…") { choosing = true }.buttonStyle(.pennantPrimaryCompact).disabled(busy)
                } else {
                    ForEach(status.devices) { d in
                        HStack(spacing: 8) {
                            Image(systemName: "iphone").foregroundStyle(PennantTheme.inkSecondary)
                            Text(d.name).font(.zoomed(.callout))
                            Text(d.environment == "development" ? "test build" : "").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                            Spacer()
                            Text(relativeTime(d.registeredAt)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        }
                    }
                    if status.devices.isEmpty {
                        SettingsNote("No iPhone yet: open Pennant on the iPhone, signed in, and allow notifications when it asks.")
                    }
                    HStack(spacing: 8) {
                        Button(busy ? "Sending…" : "Send a test notification") { test() }.buttonStyle(.pennantCompact).disabled(busy || status.devices.isEmpty)
                        Button("Replace key…") { choosing = true }.buttonStyle(.pennantCompact)
                    }
                }
                if let note { SettingsNote(note, tone: SettingsTone.success) }
                if let e = error ?? status.lastError { SettingsNote(e, tone: SettingsTone.danger) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            importKey(url)
        }
    }

    private func ready(_ s: PushStatus) -> Bool { s.keyConfigured && !s.devices.isEmpty }

    private func summary(_ s: PushStatus) -> String {
        if !s.keyConfigured { return "Not set up: needs your APNs key" }
        if s.devices.isEmpty { return "Key added (\(s.keyID ?? "")) · waiting for an iPhone" }
        return "On · \(s.devices.count) iPhone\(s.devices.count == 1 ? "" : "s")"
    }

    private func load() async {
        do { status = try await session.pushStatus(); error = nil } catch { self.error = HostSessionError.message(error) }
    }

    /// Reads AuthKey_<Key ID>.p8; the Key ID comes from the file name.
    private func importKey(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { error = "Couldn't read that file."; return }
        let name = url.deletingPathExtension().lastPathComponent
        let keyID = name.hasPrefix("AuthKey_") ? String(name.dropFirst("AuthKey_".count)) : name
        busy = true
        Task {
            defer { busy = false }
            do {
                status = try await session.setPushKey(keyID: keyID, teamID: teamID.isEmpty ? nil : teamID, p8: text)
                note = "Key \(keyID) added."
                error = nil
            } catch { self.error = HostSessionError.message(error) }
        }
    }

    private func test() {
        busy = true
        Task {
            defer { busy = false }
            do {
                status = try await session.sendTestPush()
                note = status?.lastError == nil ? "Sent. It should arrive in a few seconds." : nil
                error = nil
            } catch { self.error = HostSessionError.message(error) }
        }
    }
}
