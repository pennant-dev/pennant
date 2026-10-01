import PennantClientKit
import PennantCore
import SwiftUI

/// Work the agent hands off, drawn in the chat as what it is: a coding run in a thread of its own (`code`), and
/// helpers it splits a job across (`delegate_task`). They sit outside the folded tool group so you can see the work
/// change hands.
enum DelegatedWork {
    static let coding = "code"
    static let delegation = "delegate_task"
    static func isDelegated(_ name: String) -> Bool { name == coding || name == delegation }

    /// The task a call started, read from its result ("Coding run started (task <id>…").
    static func taskID(from activity: ToolActivity) -> TaskID? {
        guard let text = activity.result?.textContent,
              let m = text.firstMatch(of: /[Tt]ask ([0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27})/) else { return nil }
        return TaskID(String(m.1))
    }

    /// Where a delegated task stands, in words and colours.
    static func phase(_ task: TaskRecord?, call: ToolActivityStatus) -> (word: String, color: Color, live: Bool) {
        if let task {
            switch task.state {
            case .completed: return ("Done", PennantTheme.success, false)
            case .failed: return ("Failed", PennantTheme.danger, false)
            case .cancelled: return ("Cancelled", PennantTheme.inkTertiary, false)
            case .waitingForUser: return ("Needs you", PennantTheme.color(for: AgentStatus.waitingForUser), false)
            case .paused: return ("Paused", PennantTheme.warning, false)
            case .queued: return ("Queued", PennantTheme.inkSecondary, false)
            case .running, .waitingForTool, .waitingForDesktop: return ("Working", PennantTheme.info, true)
            }
        }
        switch call {
        case .running, .pending: return ("Working", PennantTheme.info, true)
        case .failed, .denied: return ("Failed", PennantTheme.danger, false)
        default: return ("Done", PennantTheme.success, false)
        }
    }
}

private struct OpenChatKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (AgentID, ConversationID?) -> Void)? = nil
}

private struct OpenInNewWindowKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (AgentID, ConversationID) -> Void)? = nil
}

public extension EnvironmentValues {
    /// Opens a conversation in a window of its own (the Mac sets it; elsewhere menus don't offer it).
    var openInNewWindow: (@MainActor @Sendable (AgentID, ConversationID) -> Void)? {
        get { self[OpenInNewWindowKey.self] }
        set { self[OpenInNewWindowKey.self] = newValue }
    }
}

public extension EnvironmentValues {
    /// Opens a conversation. The Mac window sets it; where it is nil, coding-run rows don't offer the link.
    var openChat: (@MainActor @Sendable (AgentID, ConversationID?) -> Void)? {
        get { self[OpenChatKey.self] }
        set { self[OpenChatKey.self] = newValue }
    }
}

/// A line that carries work from the agent to where it went; while that works, a spinner sits on it.
struct BatonLine: View {
    var active: Bool
    var color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(PennantTheme.border).frame(height: 2)
            if active {
                // Still line with the system spinner on it: animated by AppKit/UIKit, not redrawn every frame.
                Capsule().fill(color.opacity(0.35)).frame(height: 2)
                ProgressView().controlSize(.mini).frame(maxWidth: .infinity)
            } else {
                Capsule().fill(color.opacity(0.55)).frame(height: 2)
            }
        }
        .frame(width: 40, height: 2)
        .accessibilityHidden(true)
    }
}

/// A coding run the agent started (the `code` tool): the request, where it stands, what came back, and a link to its
/// own thread.
struct CodingRunRow: View {
    @Environment(\.hostSession) private var session
    @Environment(\.openChat) private var openChat
    var activity: ToolActivity
    var from: AgentProfile?
    @State private var expanded = false

    private var request: String { activity.arguments["request"]?.stringValue ?? "" }
    private var task: TaskRecord? { DelegatedWork.taskID(from: activity).flatMap { session.state.task($0) } }
    /// Where the run works: its thread's folder once it has one, else the project or folder asked for.
    private var folder: String {
        let path = task.flatMap { session.state.conversation($0.conversationID)?.workingDirectory } ?? activity.arguments["folder"]?.stringValue
        return path.map { ($0 as NSString).lastPathComponent } ?? "the default project"
    }
    /// The run's summary once it finishes.
    private var answer: String? {
        guard let task, task.state.isTerminal, let s = task.resultSummary, !s.isEmpty else { return nil }
        return s
    }

    var body: some View {
        let phase = DelegatedWork.phase(task, call: answer == nil ? activity.status : .done)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if let from { AgentAvatar(agent: from, size: 20) }
                BatonLine(active: phase.live, color: PennantTheme.info)
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.info)
                Text("Coding in \(folder)")
                    .font(.zoomed(.subheadline).weight(.semibold))
                    .foregroundStyle(PennantTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(phase.word).font(.zoomed(.caption).weight(.semibold)).foregroundStyle(phase.color)
            }
            if !request.isEmpty {
                Text(request)
                    .font(.zoomed(.callout))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .onTapGesture { expanded.toggle() }
            }
            if let answer {
                PennantMarkdown(answer)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(PennantTheme.assistantBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let openChat, let task, let from {
                Button { openChat(from.id, task.conversationID) } label: {
                    Label("Open the coding thread", systemImage: "arrow.up.right")
                }
                .buttonStyle(.pennantGhostCompact)
            }
        }
        .padding(12)
        .frame(maxWidth: 720, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous)
            .strokeBorder(PennantTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .animation(.easeOut(duration: 0.3), value: answer)
        .accessibilityElement(children: .contain)
    }
}

/// The workers a lead split a job across, live: what each is doing, where it stands, how much it has used.
struct WorkersCard: View {
    @Environment(\.hostSession) private var session
    var activities: [ToolActivity]
    var lead: AgentProfile?

    private var rows: [(activity: ToolActivity, task: TaskRecord?)] {
        activities.map { a in (a, DelegatedWork.taskID(from: a).flatMap { session.state.task($0) }) }
    }

    var body: some View {
        let rows = rows
        let done = rows.filter { $0.task?.state == .completed }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let lead { AgentAvatar(agent: lead, size: 20) }
                Text(rows.count == 1 ? "1 worker" : "\(rows.count) workers")
                    .font(.zoomed(.subheadline).weight(.semibold))
                    .foregroundStyle(PennantTheme.ink)
                Text("\(done) of \(rows.count) done")
                    .font(.zoomed(.caption).monospacedDigit())
                    .foregroundStyle(PennantTheme.inkSecondary)
                Spacer(minLength: 8)
                let tokens = rows.compactMap { $0.task.map { $0.usage.inputTokens + $0.usage.outputTokens } }.reduce(0, +)
                if tokens > 0 {
                    Text(Self.tokens(tokens)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.activity.id) { row in
                    WorkerRow(activity: row.activity, task: row.task, accent: lead.map { Color(hex: $0.accentColorHex) } ?? PennantTheme.info)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(PennantTheme.border).frame(width: 2) }
        }
        .padding(12)
        .frame(maxWidth: 720, alignment: .leading)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).strokeBorder(PennantTheme.border))
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM tokens", Double(n) / 1_000_000)
            : n >= 1_000 ? "\(n / 1_000)k tokens" : "\(n) tokens"
    }
}

private struct WorkerRow: View {
    @Environment(\.hostSession) private var session
    var activity: ToolActivity
    var task: TaskRecord?
    var accent: Color
    @State private var expanded = false
    /// What the finished worker ran on and cost, from the usage ledger.
    @State private var cost: RunCost.Summary?

    private var title: String { activity.arguments["title"]?.stringValue ?? task?.title ?? "Worker" }

    var body: some View {
        let phase = DelegatedWork.phase(task, call: activity.status)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(phase.word).font(.zoomed(.caption).weight(.semibold)).foregroundStyle(phase.color)
            }
            HStack(spacing: 8) {
                WorkerProgress(live: phase.live, finished: task?.state == .completed, color: accent)
                if let task {
                    Text(meta(task)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1).fixedSize()
                }
            }
            if let cost, !cost.models.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "cpu").font(.zoomed(size: 9, weight: .semibold))
                    Text(cost.models.joined(separator: ", ")).lineLimit(1)
                    Text("·")
                    Text(cost.cost.map(RunCost.money) ?? "no price set")
                }
                .font(.zoomed(.caption2).monospacedDigit())
                .foregroundStyle(PennantTheme.inkTertiary)
                .help(cost.help)
            }
            if let summary = task?.resultSummary, task?.state.isTerminal == true, !summary.isEmpty {
                Text(summary)
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .onTapGesture { expanded.toggle() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(PennantTheme.cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: task?.state) { if let task, task.state.isTerminal { cost = await RunCost.summary(for: task, session: session) } }
    }

    private func meta(_ task: TaskRecord) -> String {
        var parts: [String] = []
        if task.usage.steps > 0 { parts.append(task.usage.steps == 1 ? "1 step" : "\(task.usage.steps) steps") }
        let tokens = task.usage.inputTokens + task.usage.outputTokens
        if tokens > 0 { parts.append(WorkersCard.tokens(tokens)) }
        if let start = task.usage.startedAt {
            let secs = Int((task.finishedAt ?? Date()).timeIntervalSince(start))
            parts.append(secs < 60 ? "\(secs) s" : "\(secs / 60) min")
        }
        return parts.joined(separator: " · ")
    }
}

/// A thin bar: a light sweeping along while the worker runs, full when it's done.
private struct WorkerProgress: View {
    var live: Bool
    var finished: Bool
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PennantTheme.cardBackground)
                if finished {
                    Capsule().fill(PennantTheme.success)
                } else if live {
                    Capsule().fill(color.opacity(0.5)).frame(width: geo.size.width * 0.5)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
