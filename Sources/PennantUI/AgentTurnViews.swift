import PennantClientKit
import PennantCore
import SwiftUI

// How an agent's side of the conversation reads: its words as plain text in a comfortable column, and every
// stretch of work between them (reasoning, tool calls, their results, across however many model turns) folded
// into one quiet line that opens into a compact list.

/// One step inside a stretch of work.
enum WorkItem: Identifiable {
    case reasoning(id: String, text: String, streaming: Bool)
    case activity(ToolActivity)
    case thinking(id: String)
    /// What the agent said while working ("Let me check the draft passes."): narration, not its answer.
    case note(id: String, text: String)

    var id: String {
        switch self {
        case .reasoning(let id, _, _): return id
        case .note(let id, _): return id
        case .activity(let a): return "tool-" + a.id.rawValue
        case .thinking(let id): return id
        }
    }

    var activity: ToolActivity? { if case .activity(let a) = self { return a } else { return nil } }
}

/// A stretch of work as one line: what is happening now (while live) or what was done, and how long it took.
/// Opens into the steps; each tool step opens into its input and output.
struct WorkGroupView: View {
    @Environment(\.hostSession) private var session
    var items: [WorkItem]
    /// The agent is still in this stretch (the task runs and nothing has followed it yet).
    var live: Bool
    /// The user's own choice; groups start closed.
    @State private var choice: Bool?

    init(items: [WorkItem], live: Bool, initiallyOpen: Bool = false) {
        self.items = items
        self.live = live
        _choice = State(initialValue: initiallyOpen ? true : nil)
    }

    private var open: Bool { choice ?? false }
    private var activities: [ToolActivity] { items.compactMap(\.activity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { choice = !open }
            } label: { header }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        switch item {
                        case .activity(let a): ToolActivityCard(activity: a, compact: true)
                        case .reasoning(_, let text, let streaming): ReasoningStep(text: text, streaming: streaming)
                        case .thinking: EmptyView()
                        case .note(_, let text):
                            Text(text)
                                .font(.zoomed(.callout))
                                .foregroundStyle(PennantTheme.inkSecondary)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(PennantTheme.border).frame(width: 1).padding(.leading, 8) }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var header: some View {
        let failed = activities.filter { $0.status.isFailure }.count
        let running = activities.last { $0.status == .running }
        let naming = ToolNaming.from(session.state)
        return HStack(spacing: 8) {
            Group {
                if live || running != nil {
                    ProgressView().controlSize(.mini)
                } else if failed > 0 {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PennantTheme.danger)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(PennantTheme.inkTertiary)
                }
            }
            .font(.zoomed(size: 13))
            .frame(width: 16, height: 16)
            Text(headline(running: running, naming: naming))
                .font(.zoomed(.callout))
                .foregroundStyle(PennantTheme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if failed > 0 {
                Text("\(failed) failed").font(.zoomed(.caption).weight(.medium)).foregroundStyle(PennantTheme.danger)
            }
            glyphs
            if let seconds = totalSeconds, !live {
                Text(formatDuration(seconds)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.zoomed(.caption2).weight(.semibold))
                .foregroundStyle(PennantTheme.inkTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// "Searching mail…" while a step runs; "Used 3 tools" or "Thought it through" once done.
    private func headline(running: ToolActivity?, naming: ToolNaming) -> String {
        if let running { return ToolPresentation.title(for: running, naming: naming).text + "…" }
        if live {
            // The agent's latest word on what it is doing reads better than a generic "Working…".
            if case .note(_, let text)? = items.last(where: { if case .note = $0 { return true } else { return false } }) {
                return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            }
            return activities.isEmpty ? "Thinking…" : "Working…"
        }
        switch activities.count {
        case 0: return "Thought it through"
        case 1: return ToolPresentation.title(for: activities[0], naming: naming).text
        default: return "Used \(activities.count) tools"
        }
    }

    /// The families of tools used (mail, shell, browser…), as small tinted glyphs, at most four.
    private var glyphs: some View {
        var seen = Set<String>()
        let unique = activities.map { ToolPresentation.glyph(for: $0.name) }.filter { seen.insert($0.symbol).inserted }.prefix(4)
        return HStack(spacing: 3) {
            ForEach(Array(unique.enumerated()), id: \.offset) { _, g in
                Image(systemName: g.symbol)
                    .font(.zoomed(size: 9, weight: .semibold))
                    .foregroundStyle(g.tint)
                    .frame(width: 18, height: 18)
                    .background(g.tint.opacity(0.12), in: Circle())
            }
        }
    }

    private var totalSeconds: TimeInterval? {
        let durations = activities.compactMap(\.duration)
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }
}

/// A reasoning step inside a work group: one line that opens into the model's own words.
struct ReasoningStep: View {
    var text: String
    var streaming: Bool
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.zoomed(size: 10, weight: .medium)).foregroundStyle(PennantTheme.inkTertiary).frame(width: 18, height: 18)
                    Text(streaming ? "Thinking…" : "Reasoning").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    if !open {
                        Text(text.replacingOccurrences(of: "\n", with: " "))
                            .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                    .padding(.leading, 6)
            }
        }
    }
}

/// The agent's words: plain text on the page, no bubble, in a column narrow enough to read.
/// What an agent says, in a bubble tinted with its flag's colour so you know who's talking at a glance. The first
/// bubble of a turn carries the agent's flag and name.
struct AgentText: View {
    var text: String
    var agent: AgentProfile? = nil
    var showsName = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsName, let agent {
                HStack(spacing: 6) {
                    AgentAvatar(agent: agent, size: 18)
                    Text(agent.name).font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                }
            }
            PennantMarkdown(text)
                .tint(PennantTheme.brandInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint, in: RoundedRectangle(cornerRadius: PennantTheme.bubbleRadius, style: .continuous))
        .frame(maxWidth: 720, alignment: .leading)
    }

    /// The agent's accent, faint enough for body text to stay crisp on it in either appearance.
    private var tint: Color {
        guard let agent else { return PennantTheme.assistantBubble }
        return Color(hex: agent.accentColorHex).opacity(scheme == .dark ? 0.18 : 0.09)
    }
}
