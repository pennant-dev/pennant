import PennantClientKit
import PennantCore
import SwiftUI

/// The words for the inference provider ids, shared by Settings, the model chip, and the Connections card.
public enum InferenceProviderLabel {
    public static func title(for provider: String) -> String {
        switch provider {
        case HostConfig.Inference.chatGPTProvider: return "ChatGPT account"
        case HostConfig.Inference.appleProvider: return "Apple on-device"
        case HostConfig.Inference.azureProvider: return "Azure AI Foundry"
        case HostConfig.Inference.openAIProvider: return "OpenAI-compatible endpoint"
        default: return provider
        }
    }

    /// A small symbol for each provider, for the model chip.
    public static func symbol(for provider: String) -> String {
        switch provider {
        case HostConfig.Inference.chatGPTProvider: return "bubble.left.and.text.bubble.right"
        case HostConfig.Inference.appleProvider: return "apple.logo"
        case HostConfig.Inference.azureProvider: return "cloud"
        default: return "cpu"
        }
    }

    /// "ChatGPT account", "On this Mac", or "DeepSeek · https://…" for an endpoint whose base URL is a known preset
    /// (the plain URL otherwise).
    public static func endpointLine(provider: String, endpoint: String, preset: String? = nil) -> String {
        switch provider {
        case HostConfig.Inference.chatGPTProvider:
            return title(for: provider)
        case HostConfig.Inference.appleProvider:
            return "On this Mac"
        default:
            let p = InferencePresets.preset(for: endpoint) ?? preset.flatMap(InferencePresets.preset(id:))
            if let p, !endpoint.isEmpty { return "\(p.name) · \(endpoint)" }
            return endpoint
        }
    }
}

/// The model a conversation's agent runs on, as a compact pill: the agent's own model, or the default model when
/// it has none. When the agent's last reply came from a fallback (its model refused, a quota ran out), the pill
/// says so. Clicking opens the list of models to pick from for this agent. Without an agent (home, sidebar) the
/// pill shows and sets the default model. Models themselves are managed in Settings › Models.
public struct ModelChip: View {
    @Environment(\.hostSession) private var session
    var conversationID: ConversationID?
    var agentID: AgentID?
    @State private var showPopover = false
    @State private var config: HostConfig?

    public init(conversationID: ConversationID? = nil, agentID: AgentID? = nil) {
        self.conversationID = conversationID
        self.agentID = agentID
    }

    private var agent: AgentProfile? { agentID.flatMap { session.state.agent($0) } }

    /// The profile this chip's agent (or the host) is set to use.
    private var configured: InferenceProfile? {
        guard let config else { return nil }
        return config.profile(agent?.modelProfileID) ?? config.defaultProfile
    }

    private var modelName: String {
        if let p = configured { return p.name }
        let name = session.state.host?.inferenceModel ?? ""
        return name.isEmpty ? "Model" : name
    }

    /// The model the agent's latest reply in this conversation actually came from, when it isn't the configured one.
    private var fellBackTo: String? {
        guard let conversationID, let configured else { return nil }
        let last = (session.state.messages[conversationID] ?? []).last { $0.role == .assistant && $0.stats?.model != nil }
        guard let used = last?.stats?.model, used != configured.name else { return nil }
        return used
    }

    public var body: some View {
        let connected = session.connection.isConnected
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: fellBackTo == nil ? InferenceProviderLabel.symbol(for: configured?.inference.provider ?? session.state.host?.inferenceProvider ?? "") : "arrow.uturn.down")
                    .font(.zoomed(size: 11, weight: .medium))
                    .foregroundStyle(fellBackTo == nil ? PennantTheme.ink : PennantTheme.warning)
                Text(fellBackTo.map { "\(modelName) → \($0)" } ?? modelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.zoomed(size: 9, weight: .semibold))
                    .foregroundStyle(PennantTheme.inkTertiary)
            }
            .font(.zoomed(.caption).weight(.medium))
            .foregroundStyle(connected ? PennantTheme.ink : PennantTheme.disabledButtonText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(connected ? (fellBackTo == nil ? PennantTheme.fieldBackground : PennantTheme.warning.opacity(0.14)) : PennantTheme.disabledButton.opacity(0.5), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!connected)
        .help(help)
        .accessibilityLabel("Model \(modelName)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ModelPopover(conversationID: conversationID, agentID: agentID, onChange: { config = $0 })
                .presentationCompactAdaptation(.popover)
        }
        .task(id: session.connection.isConnected) { await load() }
        .onChange(of: showPopover) { _, open in if !open { Task { await load() } } }
        .onChange(of: session.state.host?.inferenceModel) { _, _ in Task { await load() } }
    }

    private var help: String {
        guard session.connection.isConnected else { return "Connect to the host to see the model" }
        if let fellBackTo { return "\(agent?.name ?? "The agent") is set to \(modelName), but its last reply came from \(fellBackTo) (a fallback). Click to change." }
        return agent == nil ? "Default model: \(modelName). Click to change." : "\(agent?.name ?? "Agent") uses \(modelName). Click to change."
    }

    private func load() async {
        guard session.connection.isConnected else { return }
        config = try? await session.getConfig().config
    }
}

/// The chip's popover: the models to choose from for this agent (or the default model), its reasoning effort,
/// a note when the last reply came from a fallback, the context window, and a way to manage models.
public struct ModelPopover: View {
    @Environment(\.hostSession) private var session
    var conversationID: ConversationID?
    var agentID: AgentID?
    var onChange: (HostConfig) -> Void = { _ in }
    @State private var config: HostConfig?
    @State private var saving: String?
    @State private var error: String?

    public init(conversationID: ConversationID?, agentID: AgentID?, onChange: @escaping (HostConfig) -> Void = { _ in }) {
        self.conversationID = conversationID
        self.agentID = agentID
        self.onChange = onChange
    }

    private var agent: AgentProfile? { agentID.flatMap { session.state.agent($0) } }
    private var profiles: [InferenceProfile] { config?.inferenceProfiles ?? [] }

    /// Which row is selected: the agent's own profile, or nil for "the default model". Without an agent, the default.
    private var selectedID: String? { agent != nil ? agent?.modelProfileID : config?.defaultProfileID }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(agent.map { "Model for \($0.name)" } ?? "Default model").font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
                Spacer()
                if config == nil || saving != nil { ProgressView().controlSize(.mini) }
            }
            if let config {
                VStack(alignment: .leading, spacing: 3) {
                    if agent != nil {
                        row(id: nil, title: "Default model", subtitle: config.defaultProfile?.name, symbol: "star")
                    }
                    ForEach(profiles) { p in
                        row(id: p.id, title: p.name, subtitle: Self.where_(p.inference), symbol: InferenceProviderLabel.symbol(for: p.inference.provider))
                    }
                }
                fallbackNote(config)
                ShellHairline()
                effortRow
            }
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).fixedSize(horizontal: false, vertical: true) }
            contextLine
            #if os(macOS)
            HStack {
                Spacer()
                SettingsLink { Label("Manage models…", systemImage: "gearshape").font(.zoomed(.caption).weight(.medium)) }
                    .buttonStyle(.pennantGhostCompact)
                    .padding(.trailing, -12)
            }
            #endif
        }
        .padding(14)
        .frame(width: 340)
        .background(PennantTheme.windowBackground)
        .task { config = try? await session.getConfig().config }
    }

    static func where_(_ i: HostConfig.Inference) -> String {
        switch i.provider {
        case HostConfig.Inference.azureProvider: return "Azure · \(i.azure?.resource ?? "")"
        case HostConfig.Inference.chatGPTProvider: return "ChatGPT account"
        case HostConfig.Inference.appleProvider: return "On this Mac"
        default: return InferencePresets.preset(for: i.baseURL)?.name ?? URL(string: i.baseURL)?.host ?? i.baseURL
        }
    }

    private func row(id: String?, title: String, subtitle: String?, symbol: String) -> some View {
        let selected = selectedID == id
        return SelectableRow(selected: selected, action: { choose(id) }) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).frame(width: 16)
                Text(title).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let subtitle { Text(subtitle).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1) }
                if saving == (id ?? "default") { ProgressView().controlSize(.mini) } else {
                    Image(systemName: "checkmark").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.brandInk).opacity(selected ? 1 : 0)
                }
            }
        }
        .disabled(saving != nil)
    }

    @ViewBuilder private func fallbackNote(_ config: HostConfig) -> some View {
        let configured = config.profile(agent?.modelProfileID) ?? config.defaultProfile
        if let conversationID, let configured,
           let used = (session.state.messages[conversationID] ?? []).last(where: { $0.role == .assistant && $0.stats?.model != nil })?.stats?.model,
           used != configured.name {
            Label("The last reply came from \(used): \(configured.name) wasn't available (a used-up quota or a refused request), so the task fell back.", systemImage: "arrow.uturn.down")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.warning).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effortRow: some View {
        let current: String? = agent != nil ? agent?.reasoningEffort : config?.defaultProfile?.inference.reasoningEffort
        return HStack(spacing: 8) {
            Text("Reasoning").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
            ChipRow(selection: Binding(get: { current }, set: { setEffort($0) }), options: [
                ChoiceOption<String?>(nil, title: "Auto"), ChoiceOption<String?>("low", title: "Low"),
                ChoiceOption<String?>("medium", title: "Med"), ChoiceOption<String?>("high", title: "High"),
            ])
        }
        .help(agent == nil ? "How long the default model thinks before acting." : "How long \(agent?.name ?? "this agent")'s model thinks before acting. Auto uses the model's own setting.")
    }

    private var contextLine: some View {
        let usage: ContextUsage = {
            if let agentID { return ContextUsage.forConversation(conversationID, agentID: agentID, in: session.state) }
            return ContextUsage(usedTokens: 0, windowTokens: session.state.host?.contextWindowTokens ?? 0, compactions: 0, lastCompactedAt: nil)
        }()
        return HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(PennantTheme.inkTertiary)
            if usage.windowTokens > 0 {
                Text("\(formatTokens(usage.windowTokens)) context window")
                if agentID != nil, conversationID != nil, let f = usage.fraction {
                    Text("·")
                    Text("this conversation \(formatTokens(usage.usedTokens)) · \(Int((f * 100).rounded()))%").foregroundStyle(usage.color)
                }
            } else {
                Text("Context window size unknown")
            }
        }
        .font(.zoomed(.caption).monospacedDigit())
        .foregroundStyle(PennantTheme.inkSecondary)
        .lineLimit(1)
    }

    // MARK: Changes

    private func choose(_ id: String?) {
        guard id != selectedID else { return }
        if var a = agent {
            a.modelProfileID = id
            saving = id ?? "default"
            Task {
                defer { saving = nil }
                do { try await session.updateAgent(a) } catch { self.error = Self.describe(error) }
            }
        } else if var c = config, let id {
            c.defaultProfileID = id
            save(c, marker: id)
        }
    }

    private func setEffort(_ effort: String?) {
        if var a = agent {
            a.reasoningEffort = effort
            Task { do { try await session.updateAgent(a) } catch { self.error = Self.describe(error) } }
        } else if var c = config, let i = c.inferenceProfiles.firstIndex(where: { $0.id == c.defaultProfileID }) {
            c.inferenceProfiles[i].inference.reasoningEffort = effort
            save(c, marker: "effort")
        }
    }

    private func save(_ c: HostConfig, marker: String) {
        saving = marker
        Task {
            defer { saving = nil }
            do {
                let saved = try await session.updateConfig(c).config
                config = saved
                onChange(saved)
            } catch { self.error = Self.describe(error) }
        }
    }

    private static func describe(_ error: Error) -> String {
        if case HostSessionError.hostError(_, let message) = error { return message }
        return String(describing: error)
    }
}
