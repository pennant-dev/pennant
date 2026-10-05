import PennantClientKit
import PennantCore
import SwiftUI

// MARK: - Voice and tools

/// Tone traits. The `style` string on the profile is composed from these ("concise, warm, confirms before acting")
/// and parsed back into chips; anything that does not match a trait stays as free text.
enum VoiceTrait: String, CaseIterable, Identifiable, Hashable {
    case concise, warm, formal, playful, cautious, citesSources, confirmsBeforeActing, dry
    var id: String { rawValue }

    var title: String {
        switch self {
        case .concise: return "Concise"
        case .warm: return "Warm"
        case .formal: return "Formal"
        case .playful: return "Playful"
        case .cautious: return "Cautious"
        case .citesSources: return "Cites sources"
        case .confirmsBeforeActing: return "Confirms before acting"
        case .dry: return "Dry"
        }
    }

    /// The phrase written into the profile's `style`.
    var phrase: String { title.lowercased() }

    /// Older wordings that should still light up the chip when a profile is opened for editing.
    var aliases: [String] {
        switch self {
        case .concise: return ["brief", "direct and brief", "direct", "short", "to the point"]
        case .warm: return ["friendly", "kind"]
        case .formal: return ["professional", "businesslike"]
        case .playful: return ["light", "fun", "witty"]
        case .cautious: return ["careful", "flags uncertainty"]
        case .citesSources: return ["cites evidence", "cites its sources", "with sources"]
        case .confirmsBeforeActing: return ["confirms before acting", "asks before acting", "checks twice before acting", "double-checks", "double checks"]
        case .dry: return ["deadpan", "no filler"]
        }
    }

    static func match(_ segment: String) -> VoiceTrait? {
        let s = segment.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.phrase == s || $0.aliases.contains(s) }
    }

    /// Splits a stored style into recognised traits and the leftover free text.
    static func parse(_ style: String) -> (traits: Set<VoiceTrait>, extra: String) {
        var traits: Set<VoiceTrait> = []
        var leftovers: [String] = []
        let separators = CharacterSet(charactersIn: ",;.\n")
        for raw in style.components(separatedBy: separators) {
            let segment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            if let t = match(segment) { traits.insert(t) } else { leftovers.append(segment) }
        }
        return (traits, leftovers.joined(separator: ", "))
    }

    /// Composes the style string: traits in catalogue order, then the free text.
    static func compose(_ traits: Set<VoiceTrait>, extra: String) -> String {
        var parts = allCases.filter { traits.contains($0) }.map(\.phrase)
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { parts.append(e) }
        return parts.joined(separator: ", ")
    }
}

/// A group of host tools, as the host names them. There is no client API that lists tool names, so this mirrors
/// the specs in PennantHostKit; an unknown name in an existing allowlist is kept and shown under "Other".
struct ToolGroup: Identifiable {
    var name: String
    var tools: [String]
    var id: String { name }

    static let catalogue: [ToolGroup] = [
        ToolGroup(name: "Desktop", tools: ["screenshot", "ui_tree", "ui_action", "ui_set_value", "click", "double_click", "right_click", "move_mouse", "type_text", "press_key", "scroll", "drag", "wait", "open_app", "activate_app", "list_apps", "run_applescript", "run_jxa"]),
        ToolGroup(name: "Files", tools: ["read_file", "write_file", "edit_file", "list_directory", "shell"]),
        ToolGroup(name: "Browser", tools: ["open_url", "browser_read_page", "browser_fill"]),
        ToolGroup(name: "Memory", tools: ["memory_search", "memory_remember", "remember_instruction"]),
        ToolGroup(name: "Skills", tools: ["find_skill", "use_skill", "learn_skill", "import_skills"]),
        ToolGroup(name: "Helpers and coding", tools: ["delegate_task", "await_task", "ask_user", "code"]),
        ToolGroup(name: "Scheduling", tools: ["schedule_job", "list_schedules", "cancel_schedule"]),
    ]

    static var allNames: [String] { catalogue.flatMap(\.tools) }
}

// MARK: - Editor

/// Edits the agent: its look, name, role, voice, model, tools and standing instructions. Personality shapes voice and
/// role, never permissions. A sheet on the Mac, a full screen on iOS. Choose first, type second: traits and tools are chips.
public struct AgentEditorView: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    private let existing: AgentProfile
    var onSaved: (AgentProfile) -> Void

    @State private var name: String
    @State private var role: String
    @State private var instructions: String
    @State private var glyph: AgentGlyph
    @State private var hex: String
    @State private var traits: Set<VoiceTrait>
    @State private var voiceExtra: String
    @State private var limitTools: Bool
    @State private var tools: Set<String>
    @State private var showInstructions: Bool
    @State private var saving = false
    @State private var error: String?
    /// The saved profile the agent runs on; nil is the host's model.
    @State private var modelProfileID: String?
    @State private var defaultName: String?
    /// "low", "medium", "high"; nil is the model's own setting.
    @State private var effort: String?
    @State private var chatEffort: String?
    @State private var alwaysLoaded: Set<MCPServerID>
    @State private var profiles: [InferenceProfile] = []

    private static let formWidth: CGFloat = 520

    public init(agent: AgentProfile, onSaved: @escaping (AgentProfile) -> Void = { _ in }) {
        existing = agent
        self.onSaved = onSaved
        _name = State(initialValue: agent.name)
        _role = State(initialValue: agent.role)
        _instructions = State(initialValue: agent.instructions)
        _showInstructions = State(initialValue: !agent.instructions.isEmpty)
        _glyph = State(initialValue: AgentGlyph.resolve(avatar: agent.avatar, name: agent.name, role: agent.role))
        _hex = State(initialValue: PennantPalette.nearest(to: agent.accentColorHex).hex)
        let parsed = VoiceTrait.parse(agent.style)
        _traits = State(initialValue: parsed.traits)
        _voiceExtra = State(initialValue: parsed.extra)
        _limitTools = State(initialValue: !agent.toolAllowlist.isEmpty)
        _tools = State(initialValue: Set(agent.toolAllowlist))
        _modelProfileID = State(initialValue: agent.modelProfileID)
        _effort = State(initialValue: agent.reasoningEffort)
        _chatEffort = State(initialValue: agent.chatReasoningEffort)
        _alwaysLoaded = State(initialValue: Set(agent.alwaysLoadedServers ?? []))
    }

    private var title: String { "Edit \(existing.name)" }

    private var canSave: Bool {
        !saving
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !role.trimmingCharacters(in: .whitespaces).isEmpty
            && (!limitTools || !tools.isEmpty)
    }

    /// Names in an existing allowlist that the catalogue does not know (MCP sources, renamed tools). Kept so saving never drops them.
    private var otherTools: [String] {
        let known = Set(ToolGroup.allNames)
        return tools.filter { !known.contains($0) }.sorted()
    }

    public var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            header
            Divider().overlay(PennantTheme.divider)
            scroller
        }
        .background(PennantTheme.windowBackground)
        .frame(minWidth: 560, minHeight: 640)
        #else
        NavigationStack {
            scroller
                .background(PennantTheme.windowBackground)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentTile(glyph: glyph, hex: hex, size: 22)
            Text(title).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var scroller: some View {
        ScrollView {
            form.frame(maxWidth: Self.formWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .onChange(of: voiceExtra) { _, _ in error = nil }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            look
            PennantTextField("Name", placeholder: "Name", text: $name)
            roleSection
            voiceSection
            modelSection
            toolsSection
            instructionsSection
            Text("Personality changes how the agent talks and works. It does not change what it is allowed to do on this Mac.")
                .font(.zoomed(.caption))
                .foregroundStyle(PennantTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(Color(hex: "#E5484D")).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
    }

    private var look: some View {
        VStack(spacing: 18) {
            AgentTile(glyph: glyph, hex: hex, size: 120)
                .animation(.snappy(duration: 0.25), value: glyph)
                .animation(.snappy(duration: 0.25), value: hex)
            fitOrScroll { ColorDots(hex: $hex) }
            GlyphPicker(glyph: $glyph, hex: hex).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    /// Centred when the row fits, horizontally scrollable on narrow screens.
    private func fitOrScroll<Row: View>(@ViewBuilder _ row: () -> Row) -> some View {
        let r = row()
        return ViewThatFits(in: .horizontal) {
            r
            ScrollView(.horizontal, showsIndicators: false) { r.padding(.horizontal, 4) }
        }
    }

    private var roleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Role")
            PennantTextField(placeholder: "What this agent is for", text: $role, lines: 1 ... 3)
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Voice")
            MultiChipRow(selection: $traits, options: VoiceTrait.allCases.map { ChoiceOption($0, title: $0.title) })
            PennantTextField("More about the voice", placeholder: "Anything the chips do not cover", text: $voiceExtra, lines: 1 ... 2)
                .font(.zoomed(.callout))
        }
    }

    // MARK: Model

    private var hostModel: String { session.state.host?.inferenceModel ?? "the host's model" }

    private var modelOptions: [ChoiceOption<String?>] {
        [ChoiceOption<String?>(nil, title: "Default model", subtitle: defaultName ?? hostModel, symbol: "star")]
            + profiles.map { ChoiceOption<String?>($0.id, title: $0.name, subtitle: InferenceProfile.suggestedName(for: $0.inference), symbol: InferenceProviderLabel.symbol(for: $0.inference.provider)) }
    }

    private static let effortOptions: [ChoiceOption<String?>] = [
        ChoiceOption<String?>(nil, title: "Auto"),
        ChoiceOption<String?>("low", title: "Low"),
        ChoiceOption<String?>("medium", title: "Medium"),
        ChoiceOption<String?>("high", title: "High"),
    ]

    private static let chatEffortOptions: [ChoiceOption<String?>] = [
        ChoiceOption<String?>(nil, title: "Low"),
        ChoiceOption<String?>("medium", title: "Medium"),
        ChoiceOption<String?>("high", title: "High"),
    ]

    private var connectedServers: [MCPServerStatus] {
        session.state.mcpServers.filter { $0.config.enabled }.sorted { $0.config.name < $1.config.name }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel("Model")
            ChoiceMenu(selection: $modelProfileID, options: modelOptions, placeholder: "Default model")
            if profiles.isEmpty {
                Text("Add models in Settings › Models to give this agent its own model.")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Reasoning effort").font(.zoomed(.subheadline)).foregroundStyle(PennantTheme.inkSecondary)
                ChipRow(selection: $effort, options: Self.effortOptions)
                Text("Higher effort thinks longer before acting: slower, but better at multi-step work. Applies to reasoning models (GPT-5 family, o-series, DeepSeek R, Qwen thinking).")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if existing.kind == .persistent {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reasoning effort in the chat").font(.zoomed(.subheadline)).foregroundStyle(PennantTheme.inkSecondary)
                    ChipRow(selection: $chatEffort, options: Self.chatEffortOptions)
                    Text("The chat answers quickly and hands longer work to threads, which use the effort above.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !connectedServers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Always load").font(.zoomed(.subheadline)).foregroundStyle(PennantTheme.inkSecondary)
                    MultiChipRow(selection: $alwaysLoaded, options: connectedServers.map { ChoiceOption($0.id, title: $0.config.name) })
                    Text("Services this agent uses on most tasks. Others load when it asks for them, which keeps each turn small.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            if let (config, _) = try? await session.getConfig() { profiles = config.inferenceProfiles; defaultName = config.defaultProfile?.name }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel("Tools")
            Toggle(isOn: $limitTools.animation(.snappy(duration: 0.2))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Limit tools").foregroundStyle(PennantTheme.ink)
                    Text(limitTools ? "Only the tools chosen below." : "Every tool the host offers.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(PennantTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pennantField()
            if limitTools {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ToolGroup.catalogue) { group in
                        toolGroup(group.name, group.tools)
                    }
                    if !otherTools.isEmpty { toolGroup("Other", otherTools) }
                    if tools.isEmpty {
                        Text("Pick at least one tool, or turn off Limit tools.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    }
                }
                .padding(.leading, 2)
            }
        }
    }

    private func toolGroup(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionLabel(title)
                Spacer(minLength: 0)
                let allOn = names.allSatisfy { tools.contains($0) }
                Button(allOn ? "None" : "All") {
                    if allOn { names.forEach { tools.remove($0) } } else { names.forEach { tools.insert($0) } }
                }
                .buttonStyle(.plain)
                .font(.zoomed(.caption).weight(.medium))
                .foregroundStyle(PennantTheme.inkSecondary)
            }
            MultiChipRow(selection: $tools, options: names.map { ChoiceOption($0, title: $0) })
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showInstructions.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.zoomed(.caption).weight(.semibold))
                        .rotationEffect(.degrees(showInstructions ? 90 : 0))
                    Text("Standing instructions")
                    if !showInstructions, !instructions.isEmpty {
                        Chip("set")
                    }
                    Spacer(minLength: 0)
                }
                .font(.zoomed(.subheadline))
                .foregroundStyle(PennantTheme.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showInstructions {
                PennantTextField(placeholder: "Rules this agent always follows", text: $instructions, lines: 3 ... 8)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost)
            Button("Save changes") { save() }
                .buttonStyle(.pennantPrimary)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: Saving

    private var composedStyle: String { VoiceTrait.compose(traits, extra: voiceExtra) }

    private var allowlist: [String] {
        guard limitTools else { return [] }
        return ToolGroup.allNames.filter { tools.contains($0) } + otherTools
    }

    private func applyModel(to agent: inout AgentProfile) {
        agent.modelProfileID = modelProfileID
        agent.reasoningEffort = effort
        agent.chatReasoningEffort = chatEffort
        let known = Set(connectedServers.map(\.id))
        // Keep choices for servers that are offline right now; drop none silently.
        let kept = (agent.alwaysLoadedServers ?? []).filter { !known.contains($0) }
        let chosen = kept + alwaysLoaded.filter { known.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        agent.alwaysLoadedServers = chosen.isEmpty ? nil : chosen
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                var agent = existing
                agent.name = name.trimmingCharacters(in: .whitespaces)
                agent.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
                agent.style = composedStyle
                agent.instructions = instructions
                agent.avatar = glyph.token
                agent.accentColorHex = hex
                agent.toolAllowlist = allowlist
                applyModel(to: &agent)
                agent.updatedAt = Date()
                try await session.updateAgent(agent)
                onSaved(agent)
                dismiss()
            } catch { self.error = String(describing: error) }
        }
    }
}
