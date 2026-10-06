import PennantClientKit
import PennantCore
import SwiftUI

/// Context-window usage for one conversation, derived from its most recent task (active first)
/// and falling back to the host's window size before any task has run.
public struct ContextUsage: Hashable, Sendable {
    public var usedTokens: Int
    public var windowTokens: Int
    public var compactions: Int
    public var lastCompactedAt: Date?

    public var fraction: Double? {
        guard windowTokens > 0 else { return nil }
        return min(1, Double(usedTokens) / Double(windowTokens))
    }

    /// The ring: the accent while there is room, amber past 60%, coral past 85%.
    public var ringColor: Color {
        guard let f = fraction else { return PennantTheme.inkTertiary }
        if f < 0.60 { return PennantTheme.info }
        if f < 0.85 { return ShellPalette.caution }
        return ShellPalette.danger
    }

    /// Quiet until the window fills: grey, then amber, then coral.
    public var color: Color {
        guard let f = fraction else { return PennantTheme.inkTertiary }
        if f < 0.60 { return PennantTheme.inkSecondary }
        if f < 0.85 { return ShellPalette.caution }
        return ShellPalette.danger
    }

    @MainActor
    public static func forConversation(_ conversationID: ConversationID?, agentID: AgentID, in state: ClientState) -> ContextUsage {
        let task = latestTask(conversationID: conversationID, agentID: agentID, in: state)
        let window = (task?.usage.contextWindowTokens ?? 0) > 0 ? task!.usage.contextWindowTokens : (state.host?.contextWindowTokens ?? 0)
        return ContextUsage(usedTokens: task?.usage.lastContextTokens ?? 0, windowTokens: window, compactions: task?.usage.compactions ?? 0, lastCompactedAt: task?.usage.lastCompactedAt)
    }

    @MainActor
    public static func latestTask(conversationID: ConversationID?, agentID: AgentID, in state: ClientState) -> TaskRecord? {
        let tasks = state.tasks
            .filter { $0.agentID == agentID && (conversationID == nil || $0.conversationID == conversationID) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return tasks.first { !$0.state.isTerminal } ?? tasks.first
    }

}

/// 950, 12k, 128k, 1.2M
public func formatTokens(_ n: Int) -> String {
    if n < 1000 { return "\(n)" }
    if n < 10_000 { let v = Double(n) / 1000; return v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))k" : String(format: "%.1fk", v) }
    if n < 1_000_000 { return "\(n / 1000)k" }
    if n % 1_000_000 == 0 { return "\(n / 1_000_000)M" }
    return String(format: "%.1fM", Double(n) / 1_000_000)
}

/// One quiet line: a pill with a ring gauge and "23k of 128k 18%", a speed pill and a "compacted 2×" chip. Clearing
/// and compacting are typed in the composer (/clear, /compact).
public struct ContextMeterView: View {
    @Environment(\.hostSession) private var session
    var conversationID: ConversationID?
    var agentID: AgentID

    public init(conversationID: ConversationID?, agentID: AgentID) {
        self.conversationID = conversationID
        self.agentID = agentID
    }

    private var usage: ContextUsage { ContextUsage.forConversation(conversationID, agentID: agentID, in: session.state) }

    /// Token-weighted average speed of the conversation's timed replies (total tokens over total seconds).
    private var averageSpeed: Double? {
        guard let conversationID else { return nil }
        let stats = (session.state.messages[conversationID] ?? []).compactMap(\.stats).filter { $0.tokensPerSecond != nil }
        let seconds = stats.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return nil }
        return Double(stats.reduce(0) { $0 + $1.outputTokens }) / seconds
    }

    public var body: some View {
        let u = usage
        // Everything on a wide window; on a phone, what fits (the speed goes first, then the compaction count). Each
        // piece keeps its one line, and the row never pushes the screen wider than it is.
        ViewThatFits(in: .horizontal) {
            line(u, speed: true, compactions: true)
            line(u, speed: false, compactions: true)
            line(u, speed: false, compactions: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ u: ContextUsage, speed: Bool, compactions: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ContextRing(fraction: u.fraction ?? 0, color: u.fraction == nil ? PennantTheme.inkTertiary : u.ringColor)
                    .frame(width: 14, height: 14)
                if u.windowTokens > 0 {
                    Text("\(formatTokens(u.usedTokens)) of \(formatTokens(u.windowTokens))")
                        .foregroundStyle(PennantTheme.inkSecondary)
                    if let f = u.fraction {
                        Text("\(Int((f * 100).rounded()))%").fontWeight(.medium).foregroundStyle(u.fraction.map { $0 >= 0.6 } == true ? u.ringColor : PennantTheme.inkSecondary)
                    }
                } else {
                    Text("Context size unknown").foregroundStyle(PennantTheme.inkTertiary)
                }
            }
            .font(.zoomed(.caption).monospacedDigit())
            .lineLimit(1)
            .padding(.leading, 6).padding(.trailing, 9).padding(.vertical, 4)
            .background(PennantTheme.cardBackground, in: Capsule())
            .help(u.windowTokens > 0 ? "The model sees \(u.usedTokens.formatted()) of its \(u.windowTokens.formatted()) token context window in this conversation. Type /compact to shrink it, or /clear to start fresh." : "")
            if speed, let speed = averageSpeed {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.zoomed(size: 9))
                    Text("\(Int(speed.rounded())) tok/s")
                }
                .font(.zoomed(.caption).monospacedDigit())
                .foregroundStyle(PennantTheme.inkSecondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(PennantTheme.cardBackground, in: Capsule())
                .help("Average generation speed of the loaded replies in this conversation (output tokens per second, first token to last).")
            }
            if compactions, u.compactions > 0 {
                Chip("compacted \(u.compactions)×", color: PennantTheme.inkSecondary)
                    .lineLimit(1)
                    .help(u.lastCompactedAt.map { "Last compaction \(relativeTime($0))" } ?? "")
            }
        }
        .fixedSize()
    }
}

/// A divider's date: the time today, the day and time this year, the full date before that. Short, so the line fits a
/// phone with large text.
func dividerDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
    return date.formatted(date: .abbreviated, time: .omitted)
}

/// A small ring that fills clockwise with the share of the context window in use.
public struct ContextRing: View {
    var fraction: Double
    var color: Color
    public init(fraction: Double, color: Color) { self.fraction = fraction; self.color = color }
    public var body: some View {
        ZStack {
            Circle().stroke(PennantTheme.border, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction > 0 ? 0.03 : 0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// A checkpoint boundary: a hairline with a small centred label, and the checkpoint contents behind it.
/// The line the latest /clear leaves, with what came before out of view until "Show earlier messages".
struct ClearedDivider: View {
    var checkpoint: Checkpoint
    var showsEarlier: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ShellHairline()
            // On one line when it fits; on a phone with large text the button goes under the label.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { label; button }.fixedSize()
                VStack(spacing: 4) { label.fixedSize(); button.fixedSize() }
            }
            .font(.zoomed(.caption2))
            .foregroundStyle(PennantTheme.inkTertiary)
            .lineLimit(1)
            .layoutPriority(1)
            ShellHairline()
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "eraser")
            Text("Cleared · \(dividerDate(checkpoint.createdAt))")
        }
    }

    private var button: some View {
        Button(showsEarlier ? "Hide earlier messages" : "Show earlier messages", action: toggle)
            .buttonStyle(.plain)
            .foregroundStyle(PennantTheme.brand)
            .help(showsEarlier ? "Put what came before the clear out of view" : "See what was said before the clear. None of it reaches Pennant again.")
    }
}

struct CheckpointDivider: View {
    var checkpoint: Checkpoint
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ShellHairline()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        if checkpoint.startedOver == true {
                            Image(systemName: "eraser")
                            Text("Cleared · \(dividerDate(checkpoint.createdAt))")
                        } else {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                            Text("Compacted · \(dividerDate(checkpoint.createdAt))")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        }
                    }
                    .font(.zoomed(.caption2))
                    .foregroundStyle(PennantTheme.inkTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                }
                .buttonStyle(.plain)
                .disabled(checkpoint.startedOver == true)
                .help(checkpoint.startedOver == true ? "Nothing before this carried over" : expanded ? "Hide the checkpoint" : "Show what the agent kept from before this point")
                ShellHairline()
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !checkpoint.historySummary.isEmpty { section("Summary", [checkpoint.historySummary]) }
                    if !checkpoint.decisions.isEmpty { section("Decisions", checkpoint.decisions) }
                    if !checkpoint.completedWork.isEmpty { section("Completed", checkpoint.completedWork) }
                    if !checkpoint.pendingActions.isEmpty { section("Pending", checkpoint.pendingActions) }
                    if !checkpoint.nextStep.isEmpty { section("Next step", [checkpoint.nextStep]) }
                }
                .font(.zoomed(.caption))
                .foregroundStyle(PennantTheme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .textSelection(.enabled)
            }
        }
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.zoomed(.caption2).weight(.semibold)).foregroundStyle(PennantTheme.inkTertiary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(items.count > 1 ? "• \(item)" : item)
            }
        }
    }
}
