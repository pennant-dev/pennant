import PennantClientKit
import PennantCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What an agent's model received on its latest turn: the system prompt by section, the history, and the tool
/// definitions, with estimated tokens for each so it is clear where the context goes.
public struct PromptInspectorView: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    var agentID: AgentID
    @State private var inspection: PromptInspection?
    @State private var error: String?
    @State private var loading = false
    @State private var tab: Tab = .prompt
    @State private var open: Set<String> = []
    @State private var copied = false

    enum Tab: Hashable { case prompt, tools }

    public init(agentID: AgentID) { self.agentID = agentID }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(PennantTheme.divider)
            if let inspection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        budget(inspection)
                        ChipRow(selection: $tab, options: [
                            ChoiceOption(Tab.prompt, title: "Prompt · \(Self.format(inspection.systemTokens))", symbol: "text.alignleft"),
                            ChoiceOption(Tab.tools, title: "Tools · \(inspection.tools.count) · \(Self.format(inspection.toolTokens))", symbol: "wrench.and.screwdriver"),
                        ])
                        if tab == .prompt { promptList(inspection) } else { toolList(inspection) }
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 10) {
                    if loading { ProgressView() }
                    Text(error ?? "Reading the agent's latest turn…").font(.zoomed(.callout)).foregroundStyle(error == nil ? PennantTheme.inkSecondary : PennantTheme.danger)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PennantTheme.windowBackground)
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 720)
        #endif
        .task { if inspection == nil { await load() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let agent = session.state.agent(agentID) { AgentAvatar(agent: agent, size: 26) }
            VStack(alignment: .leading, spacing: 1) {
                Text("What \(inspection?.agentName ?? session.state.agent(agentID)?.name ?? "the agent") sees")
                    .font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
                if let i = inspection {
                    Text(i.isPreview ? "Preview of a new task (no turn since the host started)" : "Latest turn · \(i.capturedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                }
            }
            Spacer()
            if let i = inspection {
                Chip(i.model)
                Chip("Effort: \(i.reasoningEffort?.capitalized ?? "Auto")", color: PennantTheme.info)
                Button { copy(i.systemPrompt) } label: { Label(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.pennantCompact)
            }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.pennantIcon)
                .help("Refresh")
                .disabled(loading)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.pennantIcon)
                .help("Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: Token budget

    private static let palette: [Color] = [
        Color(hex: "#2F80ED"), Color(hex: "#8B5CF6"), Color(hex: "#3DB553"), Color(hex: "#F0A93B"),
        Color(hex: "#E5484D"), Color(hex: "#14B8A6"), Color(hex: "#F0762B"), Color(hex: "#6B7280"),
    ]

    private func budget(_ i: PromptInspection) -> some View {
        let parts: [(String, Int, Color)] = [
            ("Instructions", i.systemTokens, Self.palette[0]),
            ("History (\(i.historyMessages) messages)", i.historyTokens, Self.palette[2]),
            ("Tool definitions (\(i.tools.count))", i.toolTokens, Self.palette[3]),
        ]
        let total = max(i.totalTokens, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.format(i.totalTokens)).font(.zoomed(.title2).weight(.semibold).monospacedDigit()).foregroundStyle(PennantTheme.ink)
                Text("tokens sent on this turn (estimate)").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        part.2.frame(width: max(2, geo.size.width * CGFloat(part.1) / CGFloat(total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 10)
            HStack(spacing: 16) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.2).frame(width: 8, height: 8)
                        Text("\(part.0) \(Self.format(part.1))").font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkSecondary)
                    }
                }
            }
            if !i.unloadedServices.isEmpty {
                Text("Not loaded on this turn (free until the agent calls find_tools): \(i.unloadedServices.joined(separator: ", ")).")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
    }

    // MARK: Prompt

    private func promptList(_ i: PromptInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(i.sections) { section in
                let isOpen = open.contains(section.title)
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.snappy(duration: 0.15)) { if isOpen { open.remove(section.title) } else { open.insert(section.title) } }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.zoomed(.caption).weight(.semibold))
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .foregroundStyle(PennantTheme.inkTertiary)
                            Text(section.title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                            if section.title == "How to work" { Chip("House rules", color: PennantTheme.info) }
                            Spacer()
                            Text(Self.format(section.tokens)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isOpen {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.zoomed(.caption, design: .monospaced))
                                .foregroundStyle(PennantTheme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let hint = Self.editHint(section.title) {
                                Text(hint).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// Where each section comes from, and so where to change it.
    static func editHint(_ title: String) -> String? {
        switch title {
        case "How to work": return "Edit in Settings › Host settings › House rules. Applies to every agent."
        case "Identity and the agent's own instructions": return "Edit in the agent's settings: role, voice and standing instructions."
        case "Connected services": return "Connections decides what is listed; the agent's settings choose what always loads."
        case "Coding projects": return "Edit in Settings › Pennant › Coding."
        case "Environment": return "Filled in by the host on every turn."
        case "Standing instructions from the user (govern all work)": return "Edit in Memory › Preferences. Agents add these when you say \"always…\"."
        default:
            if title.hasPrefix("Relevant memory") { return "Chosen from memory for this task; edit entries in Memory." }
            if title.hasPrefix("Relevant learned skills") { return "Chosen from Skills for this task." }
            if title.hasPrefix("Checkpoint") { return "The summary of older history, written at compaction." }
            if title == "Current task" { return "The task's goal and budget; limits are in Settings › Task limits." }
            return nil
        }
    }

    // MARK: Tools

    private func toolList(_ i: PromptInspection) -> some View {
        let groups = Dictionary(grouping: i.tools, by: \.service).sorted { a, b in
            a.key == "Built in" ? true : (b.key == "Built in" ? false : a.key < b.key)
        }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.key) { service, tools in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(service).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        Text("\(tools.count) tools").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                        Spacer()
                        Text(Self.format(tools.reduce(0) { $0 + $1.tokens })).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkSecondary)
                    }
                    ForEach(tools.sorted { $0.tokens > $1.tokens }) { tool in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(tool.name).font(.zoomed(.caption, design: .monospaced)).foregroundStyle(PennantTheme.ink)
                            Text(tool.description.replacingOccurrences(of: "[\(service)] ", with: ""))
                                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Self.format(tool.tokens)).font(.zoomed(.caption2).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
                        }
                    }
                }
                .padding(12)
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: Helpers

    static func format(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            inspection = try await session.inspectPrompt(agentID)
        } catch {
            if case HostSessionError.hostError(_, let message) = error { self.error = message } else { self.error = String(describing: error) }
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
    }
}
