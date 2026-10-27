import PennantClientKit
import PennantCore
import SwiftUI

// The Pennant chat: the one conversation people have with Pennant. Pennant starts threads for the work; their
// results, questions and cards come back to the chat as updates. Threads can be read, but talking happens here.

/// Text on its way into the Pennant chat's message box: "Talk to Pennant about it" in a thread puts the thread's name
/// there, and the chat picks it up when it shows.
@MainActor
@Observable
public final class ChatDraft {
    public static let shared = ChatDraft()
    public var pending: String?
}

private struct OpenPennantChatKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

public extension EnvironmentValues {
    /// Opens the Pennant chat. The apps set it; where it's nil, threads don't offer the way back.
    var openPennantChat: (@MainActor @Sendable () -> Void)? {
        get { self[OpenPennantChatKey.self] }
        set { self[OpenPennantChatKey.self] = newValue }
    }
}

extension WorkUpdate.Kind {
    var symbol: String {
        switch self {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .question: return "questionmark.bubble.fill"
        case .approval: return "checkmark.seal.fill"
        case .unfinished: return "pause.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .finished: return PennantTheme.success
        case .failed: return PennantTheme.danger
        case .question: return ShellPalette.violet
        case .approval: return PennantTheme.attention
        case .unfinished: return PennantTheme.warning
        }
    }
}

/// News from a thread in the Pennant chat. Finished work reads as Pennant telling you, with a line saying which work it
/// was (it opens); a question Pennant asked in its own words gets just that line, with the thread's own words a click
/// away; a card shows itself, decided right here; a failure says why.
struct WorkUpdateRow: View {
    @Environment(\.hostSession) private var session
    @Environment(\.openChat) private var openChat
    var update: WorkUpdate
    /// Pennant said it in its own words in the same message (it asked the thread's question itself).
    var worded = false
    @State private var showOriginal = false

    /// The card while it still waits; once decided, the update says how.
    private var pendingCard: PendingApproval? {
        guard let id = update.approvalID else { return nil }
        return session.state.pendingApprovals.first { $0.request.id == id }
    }

    private var word: String {
        switch update.kind {
        case .finished: return "Done"
        case .failed: return "Didn't finish"
        case .question: return "Asks you"
        case .approval: return pendingCard == nil ? (update.outcome ?? "Decided") : "Needs your OK"
        case .unfinished: return "Ended without a change"
        }
    }

    var body: some View {
        switch update.kind {
        case .question where worded, .finished where worded, .failed where worded, .unfinished where worded:
            // Pennant said it; this is just where it came from.
            source
        case .approval where worded:
            VStack(alignment: .leading, spacing: 6) {
                if let pendingCard { ApprovalCard(request: pendingCard.request, agentID: pendingCard.agentID) }
                source
            }
            .frame(maxWidth: pendingCard == nil ? 720 : ApprovalCard.maxWidth + 15, alignment: .leading)
        case .finished:
            // No words from Pennant (no model to hand): the work's own note, as Pennant's.
            VStack(alignment: .leading, spacing: 5) {
                AgentText(text: update.text, agent: speaker, showsName: true)
                source
            }
        default:
            card
        }
    }

    /// Who's telling you: the thread's agent (Pennant).
    private var speaker: AgentProfile? {
        session.state.conversation(update.threadID).flatMap { session.state.agent($0.agentID) } ?? session.state.leadAgent
    }

    /// One line under what Pennant said: the work it's about, where that stands, and the way in. Pennant's own words
    /// carry the news; "Details" shows the thread's.
    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThreadNewsLine(name: update.threadName, status: sourceStatus, state: newsState, open: openChat == nil ? nil : { open() }) {
                if worded, update.kind != .approval {
                    Button(showOriginal ? "Hide details" : "Details") { withAnimation(.easeInOut(duration: 0.15)) { showOriginal.toggle() } }
                        .buttonStyle(.plain)
                        .font(.zoomed(.caption).weight(.medium))
                        .foregroundStyle(PennantTheme.brandInk)
                }
            }
            if showOriginal {
                Text(update.text)
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var newsState: ThreadNewsState {
        switch update.kind {
        case .finished: return .done
        case .failed: return .failed
        case .unfinished: return .unchanged
        case .question: return threadStillAsks ? .waiting : .done
        case .approval: return pendingCard == nil ? .done : .waiting
        }
    }

    /// A card, a failure, or a question nobody worded: the thread's news as it came.
    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch update.kind {
            case .finished, .failed, .unfinished:
                Text(update.text)
                    .font(.zoomed(.callout))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .question:
                PennantMarkdown(update.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if threadStillAsks {
                    Text("Answer here and Pennant passes it on.")
                        .font(.zoomed(.caption))
                        .foregroundStyle(PennantTheme.inkTertiary)
                }
            case .approval:
                if let pendingCard {
                    ApprovalCard(request: pendingCard.request, agentID: pendingCard.agentID)
                } else {
                    Text("“\(update.text)”")
                        .font(.zoomed(.callout))
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule().fill(update.kind.color.opacity(0.55)).frame(width: 3)
        }
        .frame(maxWidth: pendingCard == nil ? 720 : ApprovalCard.maxWidth + 15, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: update.kind.symbol)
                .font(.zoomed(.caption).weight(.semibold))
                .foregroundStyle(update.kind.color)
            Button { open() } label: {
                HStack(spacing: 3) {
                    Text(update.threadName).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.zoomed(size: 9, weight: .semibold))
                }
                .font(.zoomed(.subheadline).weight(.semibold))
                .foregroundStyle(PennantTheme.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(openChat == nil)
            .help("Open the thread")
            Text("·").foregroundStyle(PennantTheme.inkTertiary)
            Text(word)
                .font(.zoomed(.caption).weight(.semibold))
                .foregroundStyle(update.kind == .approval && pendingCard == nil ? PennantTheme.inkSecondary : update.kind.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(update.createdAt, style: .time)
                .font(.zoomed(.caption2).monospacedDigit())
                .foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    /// Where the work stands, in a few words.
    private var sourceStatus: String {
        switch update.kind {
        case .finished: return "done"
        case .failed: return "didn't finish"
        case .unfinished: return "ended without a change"
        case .question: return threadStillAsks ? "waiting on your answer" : "answered"
        case .approval: return pendingCard == nil ? (update.outcome ?? "decided").lowercased() : "waiting for your OK"
        }
    }

    /// The thread is still waiting on this question.
    private var threadStillAsks: Bool {
        guard let id = update.taskID else { return false }
        return session.state.task(id)?.state == .waitingForUser
    }

    private func open() {
        let agent = session.state.conversation(update.threadID)?.agentID ?? session.state.leadAgent?.id
        if let agent { openChat?(agent, update.threadID) }
    }
}

/// A thread Pennant started from the chat (`start_thread`): one quiet line under what Pennant said, with where it
/// stands and the way in. Pennant tells you what comes of it.
struct ThreadStartedRow: View {
    @Environment(\.hostSession) private var session
    @Environment(\.openChat) private var openChat
    var activity: ToolActivity

    /// The thread's title, or a coding run's request (its first line).
    private var title: String {
        if let t = activity.arguments["title"]?.stringValue, !t.isEmpty { return t }
        let request = activity.arguments["request"]?.stringValue ?? ""
        let first = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? request
        return first.isEmpty ? "something new" : (first.count > 70 ? String(first.prefix(70)) + "…" : first)
    }
    private var task: TaskRecord? { DelegatedWork.taskID(from: activity).flatMap { session.state.task($0) } }

    var body: some View {
        let phase = DelegatedWork.phase(task, call: activity.status)
        // While it works, what it's doing this moment and for how long, instead of a bare "working".
        let step = phase.live ? task.flatMap { WorkStep.current($0, records: session.state.toolRecords[$0.id] ?? [], naming: .from(session.state)) } : nil
        ThreadNewsLine(name: TitleMarks.strip(title), status: step == nil ? phase.word.lowercased() : "", state: phase.live ? .working : .done,
                       open: openChat == nil || task == nil ? nil : { if let task { openChat?(task.agentID, task.conversationID) } }) {
            if let step { WorkStepLabel(phrase: step.phrase, since: step.since) }
        }
            .frame(maxWidth: 720, alignment: .leading)
    }
}

enum ThreadNewsState { case working, waiting, done, unchanged, failed }

/// Where a thread stands, as one line in the Pennant chat: a spinner while it works, its name, a few words, and Open.
/// Its later news takes its place (one line per thread), so the chat doesn't fill with rows about the same work.
struct ThreadNewsLine<Extra: View>: View {
    var name: String
    var status: String
    var state: ThreadNewsState
    var open: (() -> Void)?
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch state {
                case .working: ProgressView().controlSize(.small).scaleEffect(0.75)
                case .waiting: Circle().fill(PennantTheme.brand).frame(width: 7, height: 7)
                case .done: Image(systemName: "checkmark").font(.zoomed(size: 10, weight: .bold)).foregroundStyle(PennantTheme.success)
                case .unchanged: Image(systemName: "pause.circle.fill").font(.zoomed(size: 10)).foregroundStyle(PennantTheme.warning)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.zoomed(size: 10)).foregroundStyle(PennantTheme.danger)
                }
            }
            .frame(width: 14, height: 14)
            Text(name)
                .font(.zoomed(.callout).weight(.semibold))
                .foregroundStyle(PennantTheme.ink)
                .lineLimit(1)
            Text(status)
                .font(.zoomed(.callout))
                .foregroundStyle(state == .failed ? PennantTheme.danger : PennantTheme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            extra
            Spacer(minLength: 8)
            if let open {
                Button("Open", action: open)
                    .buttonStyle(.pennantCompact)
                    .help("Open the thread")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(state == .working || state == .waiting ? PennantTheme.brandSoft : PennantTheme.panelBackground,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
    }
}

/// In place of the message box inside a thread: Pennant runs it, and you talk to Pennant.
struct ThreadFooter: View {
    @Environment(\.openPennantChat) private var openPennantChat
    var conversation: Conversation
    var waiting: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(PennantTheme.inkSecondary)
            Text(waiting ? "This thread waits on you. Answer in the Pennant chat, and Pennant passes it on."
                         : "Pennant runs this thread. To change anything, tell Pennant.")
                .font(.zoomed(.callout))
                .foregroundStyle(PennantTheme.inkSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let openPennantChat {
                Button {
                    ChatDraft.shared.pending = "About “\(conversationLabel(conversation))”: "
                    openPennantChat()
                } label: {
                    Text("Talk to Pennant")
                }
                .buttonStyle(.pennantPrimary)
                .accessibilityIdentifier("talk-to-pennant")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PennantTheme.cardElevated)
        .overlay(alignment: .top) { Rectangle().fill(PennantTheme.divider).frame(height: 1) }
    }
}

/// The Pennant chat before anything was said in it.
struct PennantChatIntro: View {
    var agent: AgentProfile?

    var body: some View {
        VStack(spacing: 10) {
            if let agent { AgentAvatar(agent: agent, size: 64) }
            Text(agent?.name ?? "Pennant").font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
            Text("Ask for anything here. Longer work goes to threads that run in the background, and what comes of them, results, questions and things to approve, lands in this chat.")
                .font(.zoomed(.callout))
                .foregroundStyle(PennantTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.bottom, 24)
    }
}
