import AppKit
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Pennant › Coding: what writes the code (Claude Code, or Pennant itself on one of your models), the
/// project folders it may change, how it asks, its standing instructions, and the GitHub App it acts as.
struct CodingSettingsCard: View {
    @Environment(\.hostSession) private var session
    @State private var config: HostConfig?
    @State private var error: String?
    /// The project being renamed (by path), and the name typed so far.
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    /// The instructions as typed; saved with their own button.
    @State private var instructions = ""
    @State private var settingUpGitHub = false
    @State private var confirmRemoveGitHub = false

    private var coding: HostConfig.Coding { config?.coding ?? HostConfig.Coding() }
    private var mode: CodingMode { coding.mode ?? .acceptEdits }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let config {
                engineSection(config)
                Divider()
                projectsSection
                Divider()
                asksSection
                Divider()
                instructionsSection
                Divider()
                gitHubSection
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
        .padding(8)
        .task { await load() }
        .sheet(isPresented: $settingUpGitHub) {
            GitHubAppSheet(current: coding.gitHubApp) { identity in change { $0.gitHubApp = identity } }
        }
        .confirmationDialog("Remove the GitHub identity?", isPresented: $confirmRemoveGitHub) {
            Button("Remove", role: .destructive) { change { $0.gitHubApp = nil } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Coding runs won't push or open pull requests until you set one up again. The App's key stays in the Vault.")
        }
    }

    // MARK: Engine

    private static let engineOptions = [
        ChoiceOption(CodingEngine.claudeCode, title: "Claude Code", symbol: "terminal"),
        ChoiceOption(CodingEngine.pennant, title: "Pennant", symbol: "cpu"),
    ]

    private func engineSection(_ c: HostConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Engine")
            ChipRow(selection: Binding(get: { coding.engine }, set: { engine in change { $0.engine = engine } }), options: Self.engineOptions)
            switch coding.engine {
            case .claudeCode:
                SettingsNote("Runs the claude program you installed and signed in to on this Mac, on Claude's models; each coding thread can pick one.")
            case .pennant:
                ChoiceMenu("Model", selection: Binding(get: { coding.modelProfileID ?? "" }, set: { id in change { $0.modelProfileID = id.nilIfEmpty } }),
                           options: modelOptions(c), placeholder: "Default model")
                SettingsNote("Pennant writes the code itself on this model, with file and shell tools in the project folder. A coding thread can switch to another model from Settings › Models.")
            }
        }
    }

    private func modelOptions(_ c: HostConfig) -> [ChoiceOption<String>] {
        [ChoiceOption("", title: "Default model", subtitle: c.defaultProfile?.name, symbol: "star")]
            + c.inferenceProfiles.map { ChoiceOption($0.id, title: $0.name, subtitle: ModelsSettingsView.describe($0.inference), symbol: ModelsSettingsView.symbol($0.inference.provider)) }
    }

    // MARK: Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Project folders")
            if coding.projects.isEmpty {
                SettingsNote("None yet. Add the folders Pennant may change code in; until there is one, it doesn't write code.")
            }
            ForEach(Array(coding.projects.enumerated()), id: \.element.id) { index, project in
                projectRow(project, isDefault: index == 0)
            }
            Button { addFolders() } label: { Label("Add folder…", systemImage: "plus") }.buttonStyle(.pennantCompact)
            SettingsNote("A request goes to the project it names, or to the default one. Removing a folder only takes it off this list.")
        }
    }

    private func projectRow(_ p: CodingProject, isDefault: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(PennantTheme.inkSecondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                if renaming == p.path {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .pennantField(focused: nameFocused)
                        .onSubmit { rename(p) }
                        .onExitCommand { renaming = nil }
                        .onAppear { nameFocused = true }
                } else {
                    HStack(spacing: 6) {
                        Text(p.name).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        if isDefault { Chip("Default", color: PennantTheme.brandInk) }
                    }
                }
                Text((p.path as NSString).abbreviatingWithTildeInPath)
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if renaming == p.path {
                Button("Save") { rename(p) }.buttonStyle(.pennantPrimaryCompact).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { renaming = nil }.buttonStyle(.pennantGhostCompact)
            } else {
                Menu {
                    Button("Make default") { change { $0.addProject(path: p.path, asDefault: true) } }.disabled(isDefault)
                    Button("Rename") { newName = p.name; renaming = p.path }
                    Divider()
                    Button("Remove", role: .destructive) { change { $0.projects.removeAll { $0.path == p.path } } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.pennantIcon).fixedSize()
                    .help("Make default, rename or remove")
            }
        }
        .padding(.vertical, 2)
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Folders Pennant may change code in, usually a git repository each"
        if let last = coding.projects.last { panel.directoryURL = URL(fileURLWithPath: last.path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let paths = panel.urls.map(\.path)
        change { coding in for path in paths { coding.addProject(path: path, asDefault: false) } }
    }

    private func rename(_ p: CodingProject) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != p.name else { return }
        change { coding in
            guard let i = coding.projects.firstIndex(where: { $0.path == p.path }) else { return }
            coding.projects[i].name = coding.uniqueName(name, except: p.path)
        }
    }

    // MARK: Asking, instructions, GitHub

    private var asksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Asks", selection: Binding(get: { mode }, set: { m in change { $0.mode = m == .acceptEdits ? nil : m } })) {
                ForEach(CodingMode.allCases) { m in Text(m.title).tag(m) }
            }
            .help(mode.detail)
            SettingsNote("\(mode.detail). Code changes run in a thread under the one that asked, with the steps and any approvals there; a thread can ask more or less from its own menu, but with Ask for everything every run asks for everything.")
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PennantTextField("Instructions for every run", placeholder: "House style, how to branch and name commits, what never to touch", text: $instructions, lines: 3 ... 8)
            if instructions != coding.instructions {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Revert") { instructions = coding.instructions }.buttonStyle(.pennantGhostCompact)
                    Button("Save") { let text = instructions; change { $0.instructions = text } }.buttonStyle(.pennantPrimaryCompact)
                }
            }
        }
    }

    private var gitHubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("On GitHub")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let app = coding.gitHubApp {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.botLogin).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).textSelection(.enabled)
                        Text("App \(String(app.appID)) · installation \(String(app.installationID)) · key in the Vault as \(app.vaultEntry)")
                            .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No identity: coding runs don't push or open pull requests.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                }
                Spacer(minLength: 8)
                Button(coding.gitHubApp == nil ? "Set up…" : "Change…") { settingUpGitHub = true }.buttonStyle(.pennantCompact)
                if coding.gitHubApp != nil { Button("Remove") { confirmRemoveGitHub = true }.buttonStyle(.pennantGhostCompact) }
            }
            SettingsNote("Coding runs commit, push and open pull requests as a GitHub App of yours, never as you.")
        }
    }

    // MARK: Saving

    private func load() async {
        do {
            config = try await session.getConfig().config
            instructions = config?.coding?.instructions ?? ""
        } catch {
            self.error = HostSessionError.message(error)
        }
    }

    /// Shows an edit to the coding settings at once, then saves it onto the host's latest config, so a change made
    /// elsewhere meanwhile (a model added in Settings › Models) isn't undone.
    private func change(_ edit: @escaping @Sendable (inout HostConfig.Coding) -> Void) {
        error = nil
        if var c = config {
            var coding = c.coding ?? HostConfig.Coding()
            edit(&coding)
            c.coding = coding
            config = c
        }
        Task {
            do {
                var latest = try await session.getConfig().config
                var coding = latest.coding ?? HostConfig.Coding()
                edit(&coding)
                latest.coding = coding
                config = try await session.updateConfig(latest).config
            } catch {
                self.error = HostSessionError.message(error)
            }
        }
    }
}

/// The GitHub App coding runs act as: its ID, slug and installation, and its private key, which goes into the Vault
/// (the settings keep only the entry's name). Check mints a token the way a run does.
private struct GitHubAppSheet: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    var current: GitHubAppIdentity?
    var onSave: (GitHubAppIdentity) -> Void
    @State private var appID: String
    @State private var slug: String
    @State private var installationID: String
    /// The Vault entry with the key: one already there, or `newKey` for a .pem file chosen here.
    @State private var keyEntry: String
    @State private var entries: [VaultItem] = []
    @State private var pem: (file: String, text: String)?
    @State private var busy = false
    @State private var checked: (ok: Bool, text: String)?

    private static let newKey = "\u{0}new"

    init(current: GitHubAppIdentity?, onSave: @escaping (GitHubAppIdentity) -> Void) {
        self.current = current
        self.onSave = onSave
        _appID = State(initialValue: current.map { String($0.appID) } ?? "")
        _slug = State(initialValue: current?.slug ?? "")
        _installationID = State(initialValue: current.map { String($0.installationID) } ?? "")
        _keyEntry = State(initialValue: current?.vaultEntry ?? Self.newKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(current == nil ? "Give coding runs a GitHub identity" : "Change the GitHub identity").font(.zoomed(.title3).weight(.semibold))
                    SettingsNote("Coding runs commit, push and open pull requests as a GitHub App of yours, never as you. Make one in GitHub › Settings › Developer settings › GitHub Apps, with read and write access to Contents, Pull requests and Issues, and install it on the repositories Pennant may change.")
                    field("App ID", $appID, placeholder: "123456", help: "On the App's page in Developer settings › GitHub Apps, under About.")
                    field("App slug", $slug, placeholder: "my-pennant-app", help: "The App's name as its address has it: github.com/apps/<slug>. Commits are by <slug>[bot].")
                    field("Installation ID", $installationID, placeholder: "12345678", help: "Open the installed App (Settings › Applications, or the organisation's Settings › GitHub Apps, then Configure): it's the number at the end of the page's address, …/installations/12345678.")
                    keySection
                    if let checked {
                        Label(checked.text, systemImage: checked.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.zoomed(.callout)).foregroundStyle(checked.ok ? PennantTheme.success : SettingsTone.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            Divider()
            HStack {
                Button("Check") { Task { await check() } }.buttonStyle(.pennantSecondary).disabled(identity == nil || busy)
                    .help("Asks GitHub for a token as this App, as a coding run does")
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost)
                Button("Save") { Task { await save() } }.buttonStyle(.pennantPrimary).disabled(identity == nil || busy)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .background(PennantTheme.windowBackground)
        .task { entries = (try? await session.listVault()) ?? [] }
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PennantTextField(label, placeholder: placeholder, text: text)
            SettingsNote(help)
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChoiceMenu("Private key", selection: $keyEntry, options: keyOptions, placeholder: "Choose the App's key…")
            if keyEntry == Self.newKey {
                HStack(spacing: 8) {
                    Button("Choose .pem file…") { chooseKey() }.buttonStyle(.pennantCompact)
                    if let pem { Label(pem.file, systemImage: "key").font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink) }
                }
                SettingsNote("Generate one on the App's page under Private keys; GitHub downloads it as a .pem file. It goes into the Vault (this Mac's Keychain) as \(newEntryName), and the settings keep only that name.")
            }
        }
    }

    private var keyOptions: [ChoiceOption<String>] {
        entries.filter(\.hasSecret).map { ChoiceOption($0.name, title: $0.name, subtitle: "In the Vault", symbol: "key") }
            + [ChoiceOption(Self.newKey, title: "From a .pem file…", symbol: "plus")]
    }

    /// The Vault entry a new key goes into, named after the App (the Vault keeps names lowercase, with dashes).
    private var newEntryName: String {
        let base = slug.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "github-app"
        return "\(base)-private-key".lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The identity as filled in, or nil while something is missing.
    private var identity: GitHubAppIdentity? {
        let name = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app = Int(appID.trimmingCharacters(in: .whitespaces)), let installation = Int(installationID.trimmingCharacters(in: .whitespaces)), !name.isEmpty else { return nil }
        let entry = keyEntry == Self.newKey ? (pem == nil ? "" : newEntryName) : keyEntry
        guard !entry.isEmpty else { return nil }
        return GitHubAppIdentity(appID: app, installationID: installation, vaultEntry: entry, slug: name)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data]
        panel.prompt = "Use This Key"
        panel.message = "The GitHub App's private key (.pem)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        checked = nil
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("PRIVATE KEY") else {
            checked = (false, "\(url.lastPathComponent) isn't a private key: choose the .pem file GitHub downloaded.")
            return
        }
        pem = (url.lastPathComponent, text)
    }

    /// A key chosen from a file goes into the Vault (replacing an entry of the same name), and is used from there.
    private func storeKey() async throws {
        guard keyEntry == Self.newKey, let pem else { return }
        let name = newEntryName
        var item = entries.first { $0.name == name } ?? VaultItem(name: name, kind: .secret)
        item.notes = "Private key of the GitHub App \(slug.trimmingCharacters(in: .whitespaces)), for coding runs"
        entries = try await session.saveVaultItem(item, secret: VaultSecret(secret: pem.text))
        keyEntry = name
        self.pem = nil
    }

    private func check() async {
        busy = true
        defer { busy = false }
        checked = nil
        do {
            try await storeKey()
            guard let identity else { return }
            try await session.checkGitHubApp(identity)
            checked = (true, "GitHub gave \(identity.botLogin) a token: coding runs can act as it.")
        } catch {
            checked = (false, HostSessionError.message(error))
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await storeKey()
            guard let identity else { return }
            onSave(identity)
            dismiss()
        } catch {
            checked = (false, HostSessionError.message(error))
        }
    }
}
