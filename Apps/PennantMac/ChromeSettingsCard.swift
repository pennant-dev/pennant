import AppKit
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Settings › Pennant › Chrome: Pennant's extension, which lets it work in tabs of its own in the owner's Chrome. Whether
/// it's connected, a button that has Pennant add it (or the steps to do it by hand), and the sites the owner let
/// Pennant use there.
struct ChromeSettingsCard: View {
    @Environment(\.hostSession) private var session
    @State private var status: ChromeStatus?
    @State private var settingUp = false
    @State private var showSteps = false
    @State private var copied = false
    @State private var asksForNewSites: Bool?
    @State private var error: String?

    private var connected: Bool { status?.connected ?? false }
    /// The folder Chrome loads the extension from: the host's copy, kept current as Pennant updates.
    private var folder: URL? { status?.folder.map { URL(fileURLWithPath: $0) } }

    var body: some View {
        SettingsCard("Chrome") {
            HStack(spacing: 6) {
                Circle().fill(connected ? SettingsTone.success : PennantTheme.inkTertiary).frame(width: 8, height: 8)
                Text(connected ? "Connected · \(status?.browser ?? "Chrome")" : (status == nil ? "Checking…" : "Not added yet"))
                    .font(.zoomed(.callout))
                    .foregroundStyle(PennantTheme.inkSecondary)
            }
            SettingsNote("Pennant works on the web in tabs of its own, in a Chrome window of its own behind yours, with your sign-ins. It clicks and types with Chrome's own input, so your pointer, keyboard and tabs stay yours. Sending, publishing, deleting and paying still wait for your OK.")
            if !connected, status != nil {
                if settingUp {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Pennant is adding itself to Chrome. Chrome comes to the front for a moment while it picks the folder.")
                            .font(.zoomed(.callout))
                            .foregroundStyle(PennantTheme.inkSecondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Set it up for me") { setUp() }
                            .buttonStyle(.pennantPrimaryCompact)
                            .disabled(folder == nil)
                        Button(showSteps ? "Hide the steps" : "I'll do it myself") { showSteps.toggle() }
                            .buttonStyle(.pennantCompact)
                    }
                    SettingsNote("Chrome only adds extensions from its store or by hand, so Pennant does it by hand for you: it turns on Developer mode on Chrome's Extensions page and loads its extension from the Pennant folder.")
                }
                if showSteps && !settingUp { manualSteps }
            }
            if let asks = asksForNewSites {
                Toggle("Ask before Pennant uses a site for the first time", isOn: Binding(get: { asks }, set: { setAsks($0) }))
                    .font(.zoomed(.callout))
            }
            if asksForNewSites == true, !(status?.sites.isEmpty ?? true) {
                Text("Sites Pennant may use").font(.zoomed(.callout).weight(.medium)).padding(.top, 4)
                ForEach(status?.sites ?? [], id: \.self) { site in
                    HStack {
                        Text(site).font(.zoomed(.callout))
                        Spacer()
                        Button { forget(site) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PennantTheme.inkTertiary) }
                            .buttonStyle(.plain)
                            .help("Pennant asks again before it uses \(site)")
                            .accessibilityLabel("Remove \(site)")
                    }
                }
            }
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
        .task {
            asksForNewSites = try? await session.getConfig().config.chromeAsksForNewSites
            // Kept current while the page is open: the extension connects as soon as it's added.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var manualSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("1. In Chrome, open the Extensions page and turn on Developer mode (top right).")
                Text("2. Click “Load unpacked” and choose Pennant's extension folder.")
                Text("It connects by itself whenever Chrome and Pennant are both open.")
            }
            .font(.zoomed(.callout))
            .foregroundStyle(PennantTheme.inkSecondary)
            HStack(spacing: 8) {
                Button("Open Chrome's Extensions page") { openExtensionsPage() }
                    .buttonStyle(.pennantCompact)
                Button("Show the folder") { if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
                    .buttonStyle(.pennantCompact)
                    .disabled(folder == nil)
                Button(copied ? "Copied" : "Copy its path") {
                    guard let folder else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(folder.path, forType: .string)
                    copied = true
                }
                .buttonStyle(.pennantCompact)
                .disabled(folder == nil)
            }
        }
    }

    private func setAsks(_ on: Bool) {
        asksForNewSites = on
        Task {
            do {
                var c = try await session.getConfig().config
                guard c.chromeAsksForNewSites != on else { return }
                c.chromeAsksForNewSites = on
                _ = try await session.updateConfig(c)
            } catch {
                self.error = HostSessionError.message(error)
                asksForNewSites = !on
            }
        }
    }

    private func setUp() {
        settingUp = true
        error = nil
        Task {
            do {
                status = try await session.chromeSetup()
            } catch {
                self.error = HostSessionError.message(error)
                showSteps = true
            }
            settingUp = false
        }
    }

    private func load() async {
        do {
            status = try await session.chromeStatus()
            if !settingUp, status?.connected == true { error = nil }
        } catch {
            if status == nil { status = ChromeStatus(connected: false, extensionID: "") }
            self.error = HostSessionError.message(error)
        }
    }

    private func forget(_ site: String) {
        Task {
            do { status?.sites = try await session.chromeForgetSite(site) } catch { self.error = HostSessionError.message(error) }
        }
    }

    private func openExtensionsPage() {
        guard let url = URL(string: "chrome://extensions"),
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            error = "Chrome isn't installed on this Mac."
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }
}
