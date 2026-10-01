import PennantClientKit
import PennantCore
import SwiftUI

/// A coding thread's setup, as pills above the composer: the project it works in, how it asks (mode), and the model
/// it runs on (one of Claude Code's, or for the Pennant engine one of the Settings › Models profiles). A new folder
/// starts a Claude Code session over; mode and model apply from the next message.
struct CodingBar: View {
    @Environment(\.hostSession) private var session
    var conversationID: ConversationID
    @State private var projects: [String] = []
    /// The Pennant engine's models, and what "Default" runs on: the Coding setting's model, else the host's.
    @State private var profiles: [InferenceProfile] = []
    @State private var defaultModel: String?
    @State private var askingPath = false
    @State private var typedPath = ""
    @State private var error: String?
    @State private var askingModel = false
    @State private var typedModel = ""

    private var conversation: Conversation? { session.state.conversation(conversationID) }
    private var engine: CodingEngine { conversation?.engine ?? .claudeCode }
    private var folder: String? { conversation?.workingDirectory }
    private var mode: CodingMode { conversation?.engineMode ?? .acceptEdits }
    private var model: String? { conversation?.engineModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { folderMenu; modeMenu; modelMenu; path; Spacer(minLength: 0) }
                HStack(spacing: 6) { folderMenu; modeMenu; modelMenu; Spacer(minLength: 0) }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { folderMenu; modeMenu; modelMenu } }
            }
            if let error { Text(error).font(.zoomed(.caption2)).foregroundStyle(ShellPalette.danger).lineLimit(2) }
        }
        .task(id: conversationID) {
            projects = (try? await session.listProjects()) ?? []
            if engine == .pennant, let config = try? await session.getConfig().config {
                profiles = config.inferenceProfiles
                defaultModel = (config.profile(config.coding?.modelProfileID) ?? config.defaultProfile)?.name
            }
        }
        .alert("Project folder", isPresented: $askingPath) {
            TextField("~/Code/app", text: $typedPath)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Use folder") { chooseFolder(typedPath.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A folder on the Mac that runs Pennant.")
        }
        .alert("Model", isPresented: $askingModel) {
            TextField("claude-opus-5-5", text: $typedModel)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Use model") {
                let id = typedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                apply(mode: mode, model: id.isEmpty ? nil : id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any model name \(engine.title) accepts. Names it doesn't know fall back to its default.")
        }
    }

    // MARK: Pills

    private var folderMenu: some View {
        Menu {
            if !projects.isEmpty {
                Section("Projects on the Mac") {
                    ForEach(projects.prefix(20), id: \.self) { p in
                        Button { chooseFolder(p) } label: { Label(Self.name(p), systemImage: p == folder ? "checkmark" : "folder") }
                    }
                }
            }
            Button("Other folder…") {
                typedPath = folder.map(Self.tilde) ?? "~/"
                askingPath = true
            }
        } label: {
            pill(symbol: "folder", text: folder.map(Self.name) ?? "Home folder", accent: true)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help(folder.map { "\(engine.title) works in \(Self.tilde($0))" } ?? "")
        .accessibilityLabel("Project folder: \(folder.map(Self.name) ?? "home")")
    }

    private var modeMenu: some View {
        Menu {
            ForEach(CodingMode.allCases) { m in
                Button {
                    apply(mode: m, model: model)
                } label: {
                    Label { Text(m.title); Text(m.detail) } icon: { Image(systemName: m == mode ? "checkmark" : m.symbol) }
                }
            }
        } label: {
            pill(symbol: mode.symbol, text: mode.title, accent: mode != .acceptEdits)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("\(mode.detail). Applies from the next message.")
        .accessibilityLabel("Mode: \(mode.title)")
    }

    @ViewBuilder private var modelMenu: some View {
        switch engine {
        case .claudeCode: claudeModelMenu
        case .pennant: profileMenu
        }
    }

    private var profileMenu: some View {
        let chosen = profiles.first { $0.id == model }
        return Menu {
            Button {
                apply(mode: mode, model: nil)
            } label: {
                Label { Text("Default"); if let defaultModel { Text(defaultModel) } } icon: { Image(systemName: chosen == nil ? "checkmark" : "cpu") }
            }
            if !profiles.isEmpty {
                Section("Models") {
                    ForEach(profiles) { p in
                        Button { apply(mode: mode, model: p.id) } label: { Label(p.name, systemImage: p.id == chosen?.id ? "checkmark" : "cpu") }
                    }
                }
            }
        } label: {
            pill(symbol: "cpu", text: chosen?.name ?? defaultModel ?? "Default model", accent: false)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("The model Pennant codes with in this thread, from Settings › Models. Applies from the next message.")
        .accessibilityLabel("Model: \(chosen?.name ?? "default")")
    }

    private var claudeModelMenu: some View {
        Menu {
            if let first = engine.models.first, first.id == nil { modelButton(first) }
            ForEach(engine.modelFamilies, id: \.family) { group in
                Section(group.family) {
                    ForEach(group.models) { m in modelButton(m) }
                }
            }
            Divider()
            Button("Other model…") {
                typedModel = model ?? ""
                askingModel = true
            }
        } label: {
            pill(symbol: "cpu", text: engine.modelTitle(model), accent: false)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("The model \(engine.title) runs. Applies from the next message.")
        .accessibilityLabel("Model: \(engine.modelTitle(model))")
    }

    private func modelButton(_ m: CodingModel) -> some View {
        Button {
            apply(mode: mode, model: m.id)
        } label: {
            if m.note.isEmpty {
                Label(m.title, systemImage: m.id == model ? "checkmark" : "cpu")
            } else {
                Label { Text(m.title); Text(m.note) } icon: { Image(systemName: m.id == model ? "checkmark" : "cpu") }
            }
        }
    }

    @ViewBuilder private var path: some View {
        if let folder {
            Text(Self.tilde(folder))
                .font(.zoomed(.caption2).monospaced())
                .foregroundStyle(PennantTheme.inkTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(-1)
        }
    }

    private func pill(symbol: String, text: String, accent: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.zoomed(size: 10, weight: .semibold))
            Text(text).fontWeight(.medium)
            Image(systemName: "chevron.up.chevron.down").font(.zoomed(size: 8, weight: .semibold))
                .foregroundStyle(PennantTheme.inkTertiary)
        }
        .font(.zoomed(.caption))
        .foregroundStyle(accent ? PennantTheme.brandInk : PennantTheme.inkSecondary)
        .lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(accent ? PennantTheme.brandSoft : PennantTheme.cardBackground, in: Capsule())
    }

    // MARK: Changes

    private func chooseFolder(_ path: String) {
        guard !path.isEmpty else { return }
        error = nil
        Task {
            do { try await session.setConversationFolder(conversationID, path: path) }
            catch { self.error = String(describing: error) }
        }
    }

    private func apply(mode: CodingMode, model: String?) {
        error = nil
        let storedMode: CodingMode? = mode == .acceptEdits ? nil : mode
        Task {
            do { try await session.setConversationCoding(conversationID, mode: storedMode, model: model) }
            catch { self.error = String(describing: error) }
        }
    }

    static func name(_ path: String) -> String {
        let n = (path as NSString).lastPathComponent
        return n.isEmpty ? path : n
    }

    /// The path with the host user's home written as `~` (the host's home, which isn't this device's on a phone).
    static func tilde(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[1] == "Users" { return "~" + (parts.count > 3 ? "/" + parts[3...].joined(separator: "/") : "") }
        return path
    }
}
