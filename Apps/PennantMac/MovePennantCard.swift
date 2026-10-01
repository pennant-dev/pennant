import AppKit
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Settings › Host settings › Move to another Mac: export this host's Pennant into a folder, or import one.
struct MovePennantCard: View {
    @Environment(\.hostSession) private var session
    @State private var passphrase = ""
    @State private var busy: String?
    @State private var result: String?
    @State private var error: String?
    @State private var importFolder: URL?
    @State private var importPassphrase = ""

    var body: some View {
        SettingsCard("Move to another Mac") {
            SettingsNote("Export writes one folder with everything Pennant knows: agents, conversations, skills, schedules, usage, models and settings, the Library (brand files, voice sample) and Vault entries. Vault passwords and connector sign-ins are included only with a passphrase, sealed with it. Browser sign-ins stay on this Mac: copy them again from Chrome on the new one.")
            SettingsSecureField(label: "Passphrase for secrets (optional)", placeholder: "Leave empty to export without secrets", text: $passphrase)
            HStack(spacing: 8) {
                Button(busy == "export" ? "Exporting…" : "Export…") { export() }.buttonStyle(.pennantCompact).disabled(busy != nil)
                Button("Import…") { chooseImport() }.buttonStyle(.pennantCompact).disabled(busy != nil)
                Spacer()
            }
            if let importFolder {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Import \(importFolder.lastPathComponent)? It replaces this Mac's Pennant data; the current data is kept in the Pennant folder as before-import-….")
                        .font(.zoomed(.callout)).fixedSize(horizontal: false, vertical: true)
                    SettingsSecureField(label: "Its passphrase (if it carries secrets)", placeholder: "Passphrase used when exporting", text: $importPassphrase)
                    HStack {
                        Button(busy == "import" ? "Importing…" : "Import and restart") { runImport(importFolder) }.buttonStyle(.pennantPrimaryCompact).disabled(busy != nil)
                        Button("Cancel") { self.importFolder = nil }.buttonStyle(.pennantGhostCompact)
                    }
                }
                .card()
            }
            if let result { SettingsNote(result, tone: PennantTheme.success) }
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the export folder"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = "export"
        error = nil
        result = nil
        Task {
            defer { busy = nil }
            do {
                let r = try await session.exportData(folder: url.path, passphrase: passphrase.isEmpty ? nil : passphrase)
                result = "Exported \(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)) to \(r.path)\(r.secrets > 0 ? ", with \(r.secrets) sealed secret(s)" : ", without secrets")."
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)])
            } catch { self.error = HostSessionError.message(error) }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Export"
        panel.message = "Choose an Pennant Export folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFolder = url
        importPassphrase = ""
    }

    private func runImport(_ folder: URL) {
        busy = "import"
        error = nil
        Task {
            defer { busy = nil }
            do {
                try await session.importData(folder: folder.path, passphrase: importPassphrase.isEmpty ? nil : importPassphrase)
                result = "Imported. Pennant is restarting with the new data."
                importFolder = nil
            } catch { self.error = HostSessionError.message(error) }
        }
    }
}
