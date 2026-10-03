import PennantClientKit
import PennantCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Conversation with one agent: bubbles, tool cards, streaming output, and the composer.
/// The user's messages are dark bubbles on the right; the agent's are light bubbles on the left.
public struct ConversationView: View {
    @Environment(\.hostSession) private var session
    var agentID: AgentID
    @Binding var conversationID: ConversationID?
    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    /// Unsent text and files stay with their own thread (see `ThreadDrafts`).
    @State private var threadDrafts = ThreadDrafts()
    @State private var hasMore = false
    @State private var loading = false
    @State private var sendError: String?
    @State private var loadedTaskIDs: Set<TaskID> = []
    @State private var checkpoints: [Checkpoint] = []
    /// True while the timeline is scrolled to (or within a few lines of) its end. New messages and streaming
    /// deltas keep the end in view only then; once the user scrolls up, the view stays where they are.
    @State private var pinnedToBottom = true
    /// Whether the end of the timeline is on screen, from the latest scroll geometry.
    @State private var nearEnd = true
    /// True while the user is dragging, wheeling or flicking the timeline. Only their scrolling moves
    /// `pinnedToBottom`; programmatic scrolls and late row measurement never unpin it.
    @State private var userScrolling = false
    /// True while earlier messages are being prepended, so the size change keeps the visible rows in place.
    @State private var prepending = false
    /// Bumped when a conversation's first page has landed, so the timeline can jump to the end once laid out.
    @State private var initialLoads = 0
    /// A coding agent's folder, mode and model picked before the conversation exists; sent with the first message.

    public init(agentID: AgentID, conversationID: Binding<ConversationID?>) {
        self.agentID = agentID
        _conversationID = conversationID
    }

    private var messages: [Message] {
        guard let id = conversationID else { return [] }
        return session.state.messages[id] ?? []
    }

    /// Checkpoint boundaries keyed by the last message they cover. Live `checkpointSaved` events are merged in.
    private var checkpointsByMessage: [MessageID: Checkpoint] {
        var all = checkpoints
        let known = Set(all.map(\.id))
        for task in session.state.tasks where task.agentID == agentID && task.conversationID == conversationID {
            for c in session.state.checkpoints[task.id] ?? [] where !known.contains(c.id) && (c.conversationID == nil || c.conversationID == conversationID) {
                all.append(c)
            }
        }
        var out: [MessageID: Checkpoint] = [:]
        for c in all.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let m = c.throughMessageID { out[m] = c }
        }
        return out
    }

    /// The most relevant task for this conversation: the newest non-terminal one, else the newest. A new thread has
    /// none: the agent's work in another thread isn't this one's (with one agent, a fresh thread showed another
    /// thread's status and cost, and a first message could go in as the answer to that thread's question).
    private var currentTask: TaskRecord? {
        guard let conversationID else { return nil }
        let tasks = session.state.tasks
            .filter { $0.agentID == agentID && $0.conversationID == conversationID }
            .sorted { $0.updatedAt > $1.updatedAt }
        return tasks.first { !$0.state.isTerminal } ?? tasks.first
    }

    // MARK: Timeline

    /// The conversation in display order: timestamps, the user's messages, the agent's words and attachments,
    /// and each stretch of the agent's work (reasoning and tool calls, across model turns) as one group.
    private struct TimelineEntry: Identifiable {
        enum Kind {
            case timestamp(Date)
            /// A user or system message; `tight` when it follows another on the same side.
            case message(Message, tight: Bool)
            case work([WorkItem])
            /// Agent text; `time` when it is the last text of a finished reply (the time and speed go under it).
            case agentText(String, Message, time: Bool)
            case agentPart(ContentPart, Message)
            case checkpoint(Checkpoint)
            /// A coding run the agent started (see DelegatedWorkViews).
            case codingRun(ToolActivity)
            /// Workers the agent split a job across; consecutive delegations share one card.
            case workers([ToolActivity])
            /// A thread the Pennant chat started.
            case threadStarted(ToolActivity)
        }
        var id: String
        var kind: Kind
        var isAgent: Bool {
            switch kind { case .work, .agentText, .agentPart, .codingRun, .workers, .threadStarted: return true; default: return false }
        }
    }

    private static let timestampGap: TimeInterval = 20 * 60

    /// Tool results whose call is on screen fold into the call's row, so their own rows are skipped.
    private var toolPairing: ToolPairing { ToolPairing(messages: messages) }

    private func timeline(_ pairing: ToolPairing) -> [TimelineEntry] {
        let boundaries = checkpointsByMessage
        var out: [TimelineEntry] = []
        var work: [WorkItem] = []
        var lastDate: Date?
        var lastUserSide: MessageRole?
        func flushWork() {
            guard let first = work.first else { return }
            out.append(TimelineEntry(id: "work-" + first.id, kind: .work(work)))
            work = []
        }
        func checkpoint(after m: Message) {
            if let c = boundaries[m.id] {
                flushWork()
                out.append(TimelineEntry(id: "cp-\(c.id.rawValue)", kind: .checkpoint(c)))
                lastUserSide = nil
            }
        }
        for m in messages {
            if pairing.suppresses(m) { checkpoint(after: m); continue }
            if let last = lastDate, m.createdAt.timeIntervalSince(last) <= Self.timestampGap {
                // same stretch of conversation
            } else {
                flushWork()
                out.append(TimelineEntry(id: "ts-\(m.id.rawValue)", kind: .timestamp(m.createdAt)))
                lastUserSide = nil
            }
            lastDate = m.createdAt
            switch m.role {
            case .user, .system:
                flushWork()
                out.append(TimelineEntry(id: m.id.rawValue, kind: .message(m, tight: lastUserSide == m.role)))
                lastUserSide = m.role
            case .assistant, .tool:
                lastUserSide = nil
                let task = self.task(for: m)
                let records = m.taskID.flatMap { session.state.toolRecords[$0] } ?? []
                let taskActive = task.map { !$0.state.isTerminal } ?? m.isStreaming
                var lastTextIndex: Int?
                var pendingText: String?
                // Text in a step that also calls tools is narration of the work; it goes in the work group.
                let narrates = m.parts.contains { if case .toolCall = $0 { return true } else { return false } }
                func flushText(_ index: Int) {
                    guard let t = pendingText else { return }
                    pendingText = nil
                    if narrates {
                        work.append(.note(id: "\(m.id.rawValue)-n\(index)", text: t.trimmingCharacters(in: .whitespacesAndNewlines)))
                        return
                    }
                    flushWork()
                    out.append(TimelineEntry(id: "\(m.id.rawValue)-t\(index)", kind: .agentText(t, m, time: false)))
                    lastTextIndex = out.count - 1
                }
                for (i, part) in m.parts.enumerated() {
                    switch part {
                    case .text(let t):
                        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        pendingText = pendingText.map { $0 + "\n" + t } ?? t
                    case .reasoning(let r):
                        flushText(i)
                        guard !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        work.append(.reasoning(id: "\(m.id.rawValue)-r\(i)", text: r, streaming: m.isStreaming && i == m.parts.count - 1))
                    case .toolCall(let call):
                        flushText(i)
                        // Passing word to a thread, checking on one, stopping one: how Pennant works, not news.
                        if DelegatedWork.quietThreadTools.contains(call.name) { continue }
                        let record = records.first { $0.call.id == call.id }
                        let activity = ToolActivity(call: call, result: pairing.results[call.id], record: record, taskActive: taskActive)
                        if DelegatedWork.isDelegated(call.name) {
                            // Work handed off gets its own rows instead of folding into the tool group.
                            flushWork()
                            if call.name == DelegatedWork.delegation, let last = out.indices.last, case .workers(let group) = out[last].kind {
                                out[last].kind = .workers(group + [activity])
                            } else if call.name == DelegatedWork.delegation {
                                out.append(TimelineEntry(id: "workers-" + call.id.rawValue, kind: .workers([activity])))
                            } else if call.name == DelegatedWork.thread || isMainChat {
                                // In the Pennant chat a coding run is one more piece of work: a quiet line, like a thread.
                                out.append(TimelineEntry(id: "thread-" + call.id.rawValue, kind: .threadStarted(activity)))
                            } else {
                                out.append(TimelineEntry(id: "coding-" + call.id.rawValue, kind: .codingRun(activity)))
                            }
                        } else {
                            work.append(.activity(activity))
                        }
                    case .toolResult(let result):
                        flushText(i)
                        if pairing.calls.contains(result.callID) { continue }
                        let record = records.first { $0.call.id == result.callID }
                        work.append(.activity(ToolActivity(call: nil, result: result, record: record)))
                    case .update(let u) where u.silent == true:
                        // Pennant kept it to itself: they already knew.
                        continue
                    default:
                        flushText(i)
                        flushWork()
                        out.append(TimelineEntry(id: "\(m.id.rawValue)-p\(i)", kind: .agentPart(part, m)))
                    }
                }
                flushText(m.parts.count)
                if m.isStreaming, m.parts.isEmpty { work.append(.thinking(id: "\(m.id.rawValue)-thinking")) }
                if let i = lastTextIndex, !m.isStreaming, case .agentText(let t, let msg, _) = out[i].kind {
                    out[i].kind = .agentText(t, msg, time: true)
                }
            }
            checkpoint(after: m)
        }
        flushWork()
        return out
    }

    public var body: some View {
        let pairing = toolPairing
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if hasMore {
                            Button("Load earlier messages") { loadMore(proxy) }
                                .buttonStyle(PennantButtonStyle(.ghost, compact: true))
                                .frame(maxWidth: .infinity)
                                .disabled(loading)
                                .padding(.bottom, 6)
                        }
                        if messages.isEmpty, !loading {
                            if isMainChat {
                                PennantChatIntro(agent: session.state.agent(agentID))
                            } else {
                                EmptyConversation(agent: session.state.agent(agentID))
                            }
                        }
                        let entries = timeline(pairing)
                        let taskActive = currentTask.map { !$0.state.isTerminal } ?? false
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            let afterAgent = index > 0 && entries[index - 1].isAgent
                            switch entry.kind {
                            case .timestamp(let date):
                                TimestampLabel(date: date)
                            case .message(let message, let tight):
                                MessageRow(message: message, agent: session.state.agent(agentID), task: task(for: message), pairing: pairing)
                                    .padding(.top, tight ? 4 : 16)
                                    .id(message.id)
                            case .work(let items):
                                WorkGroupView(items: items, live: taskActive && index == entries.count - 1)
                                    .padding(.top, afterAgent ? 6 : 14)
                            case .agentText(let text, let message, let time):
                                VStack(alignment: .leading, spacing: 4) {
                                    AgentText(text: text, agent: session.state.agent(agentID), showsName: Self.firstTextOfTurn(entries, at: index))
                                    if time {
                                        HStack(spacing: 4) {
                                            MessageTime(date: message.createdAt, stats: message.stats)
                                            // The run's cost goes under its last reply, once it has finished.
                                            if let t = task(for: message), t.state.isTerminal,
                                               messages.last(where: { $0.taskID == t.id && $0.role == .assistant })?.id == message.id {
                                                RunCostChip(task: t)
                                            }
                                        }
                                        .font(.zoomed(.caption2).monospacedDigit())
                                        .foregroundStyle(PennantTheme.inkTertiary)
                                        .padding(.leading, 2)
                                    }
                                }
                                .padding(.top, afterAgent ? 8 : 14)
                            case .agentPart(let part, let message):
                                PartView(part: part, message: message, task: task(for: message), alignTrailing: false)
                                    .frame(maxWidth: part.isApproval || part.isUpdate ? ApprovalCard.maxWidth + 15 : 720, alignment: .leading)
                                    .padding(.top, afterAgent ? 8 : 14)
                            case .checkpoint(let c):
                                CheckpointDivider(checkpoint: c)
                                    .padding(.vertical, 10)
                            case .codingRun(let activity):
                                CodingRunRow(activity: activity, from: session.state.agent(agentID))
                                    .padding(.top, afterAgent ? 8 : 14)
                            case .workers(let activities):
                                WorkersCard(activities: activities, lead: session.state.agent(agentID))
                                    .padding(.top, afterAgent ? 8 : 14)
                            case .threadStarted(let activity):
                                ThreadStartedRow(activity: activity)
                                    .padding(.top, afterAgent ? 8 : 14)
                            }
                        }
                        if let task = currentTask, task.state == .waitingForUser {
                            WaitingForAnswerView(task: task).padding(.top, 12)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                // Open at the end. While pinned there (or prepending history), content growth keeps the same
                // rows in view: streaming text, lazily measured rows and "Load earlier" all resolve without a jump.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(pinnedToBottom || prepending ? .bottom : nil, for: .sizeChanges)
                #if os(iOS)
                // Dragging the timeline or tapping it puts the keyboard away; Return is taken by Send.
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                #endif
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 48
                } action: { _, isNearEnd in
                    nearEnd = isNearEnd
                    if userScrolling, !prepending { pinnedToBottom = isNearEnd }
                }
                // Rows measured lazily can shrink after the view scrolled to them (a tool group settling while the
                // agent works), leaving the view parked past the end: a blank screen until you scroll up. Snap back.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height > geometry.containerSize.height
                        && geometry.visibleRect.maxY > geometry.contentSize.height + 80
                } action: { _, pastEnd in
                    if pastEnd, !userScrolling { scrollToBottom(proxy, animated: false) }
                }
                .onScrollPhaseChange { _, phase in
                    // Interacting and decelerating are the user's own scrolls; animating is ours.
                    let scrolling = phase == .interacting || phase == .decelerating
                    if userScrolling, !scrolling, !prepending { pinnedToBottom = nearEnd }
                    userScrolling = scrolling
                }
                .onChange(of: followFingerprint) { _, _ in
                    if pinnedToBottom { followEnd(proxy) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !pinnedToBottom, !messages.isEmpty {
                        Button {
                            pinnedToBottom = true
                            scrollToBottom(proxy, animated: true)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.zoomed(size: 13, weight: .semibold))
                                .foregroundStyle(PennantTheme.ink)
                                .frame(width: 34, height: 34)
                                .background(PennantTheme.cardElevated, in: Circle())
                                .overlay(Circle().strokeBorder(PennantTheme.border))
                                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 18)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .help("Jump to latest")
                        .accessibilityLabel("Jump to latest message")
                    }
                }
                .animation(.easeOut(duration: 0.15), value: pinnedToBottom)
                .onChange(of: initialLoads) { _, _ in
                    // The page is in the state already; the rows are laid out on the next pass, so scroll then too.
                    pinnedToBottom = true
                    followEnd(proxy)
                    // Tall rows (tool cards, Markdown, images) can finish measuring a beat later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if pinnedToBottom { scrollToBottom(proxy, animated: false) }
                    }
                }
                .onChange(of: conversationID) { _, _ in
                    pinnedToBottom = true
                    prepending = false
                    scrollToBottom(proxy, animated: false)
                }
            }
            if let conversationID, session.state.conversation(conversationID)?.isCodingRun == true {
                // A coding CLI keeps its own context; what matters here is which project it works in.
                CodingBar(conversationID: conversationID)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            } else if conversationID != nil, threadInChat == nil {
                ContextMeterView(conversationID: conversationID, agentID: agentID, hasMessages: !messages.isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }
            if let id = conversationID, let closedAt = session.state.conversation(id)?.closedAt {
                ClosedConversationBanner(conversationID: id, closedAt: closedAt)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let task = currentTask, !task.state.isTerminal || task.updatedAt.timeIntervalSinceNow > -30 {
                TaskStatusBar(task: task)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let sendError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(sendError).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.zoomed(.caption))
                .foregroundStyle(ShellPalette.danger)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            if let thread = threadInChat {
                // Pennant runs its threads; you talk to Pennant.
                // Waiting on a question; a card it waits on is decided right here.
                ThreadFooter(conversation: thread, waiting: currentTask?.state == .waitingForUser && !session.state.pendingApprovals.contains { $0.conversationID == thread.id })
            } else {
                ComposerView(
                    text: $draft,
                    attachments: $attachments,
                    placeholder: composerPlaceholder,
                    isEnabled: session.connection.isConnected,
                    onSend: { send() },
                    conversationID: conversationID,
                    onNewConversation: isMainChat || session.state.mainConversation != nil ? nil : { conversationID = nil }
                )
            }
        }
        .background(PennantTheme.windowBackground)
        .task(id: conversationID) { await initialLoad() }
        // "Talk to Pennant" in a thread: its name goes into the chat's box.
        .onChange(of: ChatDraft.shared.pending, initial: true) { _, pending in
            guard isMainChat, let pending else { return }
            ChatDraft.shared.pending = nil
            draft = draft.isEmpty ? pending : pending + draft
        }
        .onChange(of: conversationID) { old, new in
            let next = threadDrafts.switching(from: old, to: new, leaving: ThreadDrafts.Draft(text: draft, attachments: attachments))
            draft = next.text
            attachments = next.attachments
        }
        .onAppear { markShownRead() }
        .onChange(of: shownUpdatedAt) { _, _ in markShownRead() }
        .onChange(of: currentTask?.id) { _, new in
            if let new, !loadedTaskIDs.contains(new) {
                loadedTaskIDs.insert(new)
                Task { try? await session.loadToolRecords(taskID: new) }
            }
        }
    }

    /// This is the Pennant chat.
    private var isMainChat: Bool {
        conversationID.flatMap { session.state.conversation($0)?.isMain } ?? false
    }

    /// The thread on screen, when there's a Pennant chat to talk in instead: threads are read, not written in.
    private var threadInChat: Conversation? {
        guard session.state.mainConversation != nil, let id = conversationID, let c = session.state.conversation(id), !c.isMain else { return nil }
        return c
    }

    private var composerPlaceholder: String {
        if let t = currentTask, t.state == .waitingForUser { return "Answer \(session.state.agent(agentID)?.name ?? "the agent")" }
        return "Message \(session.state.agent(agentID)?.name ?? "agent")"
    }

    private func task(for message: Message) -> TaskRecord? {
        guard let id = message.taskID else { return nil }
        return session.state.task(id)
    }

    /// Changes whenever something can appear or grow at the end of the timeline: a new message, a new part
    /// or more text in the last one, a tool result landing, or the task starting or stopping to wait.
    private var followFingerprint: Int {
        var h = Hasher()
        h.combine(messages.count)
        if let last = messages.last {
            h.combine(last.id)
            h.combine(last.parts.count)
            h.combine(last.text.utf8.count)
        }
        if let task = currentTask {
            h.combine(task.id)
            h.combine(task.state)
            h.combine(session.state.toolRecords[task.id]?.count ?? 0)
        }
        return h.finalize()
    }

    /// Keeps the end in view. The rows are measured lazily, so the end can move once they are laid out:
    /// scroll now and again on the next pass.
    private func followEnd(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy, animated: false)
        DispatchQueue.main.async {
            if pinnedToBottom { scrollToBottom(proxy, animated: false) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// The open conversation's last change; when it moves while it's on screen, the user has seen it.
    private var shownUpdatedAt: Date? { conversationID.flatMap { session.state.conversation($0)?.updatedAt } }

    private func markShownRead() {
        if let id = conversationID { session.state.markRead(id) }
    }

    /// True for the agent's first text since the user last spoke (or since a break in the timeline): that bubble
    /// carries the agent's flag and name.
    private static func firstTextOfTurn(_ entries: [TimelineEntry], at index: Int) -> Bool {
        for entry in entries[..<index].reversed() {
            if case .agentText = entry.kind { return false }
            if !entry.isAgent { return true }
        }
        return true
    }

    private func initialLoad() async {
        // A new conversation has no history; don't keep the previous one's "Load earlier" button.
        guard let id = conversationID else { hasMore = false; return }
        loading = true
        defer { loading = false }
        hasMore = (try? await session.loadMessages(conversationID: id, limit: 60)) ?? false
        initialLoads += 1
        checkpoints = (try? await session.conversationCheckpoints(id)) ?? []
        if let t = currentTask, !loadedTaskIDs.contains(t.id) {
            loadedTaskIDs.insert(t.id)
            try? await session.loadToolRecords(taskID: t.id)
        }
    }

    /// Prepends the previous page and keeps the row that was at the top where it is.
    private func loadMore(_ proxy: ScrollViewProxy) {
        guard let id = conversationID, let first = messages.first else { return }
        loading = true
        prepending = true
        Task {
            defer { loading = false }
            hasMore = (try? await session.loadMessages(conversationID: id, before: first.id, limit: 60)) ?? false
            // The new rows land on the next layout pass; align the old first row to the top after it.
            DispatchQueue.main.async {
                proxy.scrollTo(first.id, anchor: .top)
                prepending = false
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments.compactMap(\.ready)
        guard !text.isEmpty || !files.isEmpty else { return }
        let pending = attachments
        draft = ""
        attachments = []
        sendError = nil
        pinnedToBottom = true   // your own message always comes into view, even after reading back
        Task {
            do {
                if let t = currentTask, t.state == .waitingForUser, files.isEmpty {
                    try await session.answerQuestion(taskID: t.id, text: text)
                } else {
                    // The host answers a waiting question with the message too, attachments included.
                    let (_, cid, tid) = try await session.sendMessage(to: agentID, conversationID: conversationID, text: text, attachments: files)
                    if conversationID == nil { threadDrafts.startedHere = cid; conversationID = cid }
                    loadedTaskIDs.insert(tid)
                }
            } catch {
                sendError = String(describing: error)
                if draft.isEmpty { draft = text }
                if attachments.isEmpty { attachments = pending }
            }
        }
    }
}

/// Under a closed conversation: when it was closed, and Reopen. Writing a message reopens it too.
struct ClosedConversationBanner: View {
    @Environment(\.hostSession) private var session
    var conversationID: ConversationID
    var closedAt: Date
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(PennantTheme.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text("Closed \(relativeTime(closedAt))").font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                Text("Writing here reopens it.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            }
            Spacer(minLength: 0)
            Button("Reopen") { Task { try? await session.closeConversation(conversationID, closed: false) } }
                .buttonStyle(PennantButtonStyle(.secondary, compact: true))
        }
        .padding(10)
        .background(PennantTheme.brandSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
    }
}

/// Small centred grey time label between stretches of conversation.
struct TimestampLabel: View {
    var date: Date
    var body: some View {
        Text(messageTimestamp(date))
            .font(.zoomed(.caption))
            .foregroundStyle(PennantTheme.inkTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// The small time under an agent reply ("1:38 PM"). Hovering shows the full date and time.
struct MessageTime: View {
    var date: Date
    var stats: GenerationStats? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(date, format: .dateTime.hour().minute())
            if let tps = stats?.tokensPerSecond {
                Text("·")
                Text("\(Int(tps.rounded())) tok/s")
            }
        }
        .font(.zoomed(.caption2).monospacedDigit())
        .foregroundStyle(PennantTheme.inkTertiary)
        .help(help)
        .accessibilityLabel("Sent \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    /// Full date, then the reply's speed in detail.
    private var help: String {
        var lines = [date.formatted(date: .complete, time: .shortened)]
        if let s = stats {
            lines.append("\(s.estimated ? "≈" : "")\(s.outputTokens) tokens in \(String(format: "%.1f", s.seconds)) s\(s.tokensPerSecond.map { String(format: " (%.0f tok/s)", $0) } ?? "")")
            if let ttft = s.firstTokenSeconds { lines.append(String(format: "First token after %.1f s", ttft)) }
            if let model = s.model { lines.append(model) }
        }
        return lines.joined(separator: "\n")
    }
}

struct EmptyConversation: View {
    var agent: AgentProfile?
    var body: some View {
        VStack(spacing: 8) {
            if let agent {
                AgentAvatar(agent: agent, size: 64)
                Text(agent.name).font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                if !agent.role.isEmpty {
                    Text(agent.role)
                        .font(.zoomed(.callout))
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            } else {
                Text("Pick an agent to start.").foregroundStyle(PennantTheme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.bottom, 24)
    }
}

/// One message with all its parts. Consecutive text parts share a bubble; tool activity and images sit
/// beside the bubbles as cards. A tool call and its result (a later `.tool` message, matched through
/// `pairing`) draw as one activity card.
/// A decision handed back to the agent: one quiet line in the conversation, the full message the agent got on request.
struct DecisionNoteRow: View {
    var note: DecisionNote
    var text: String
    var agentName: String?
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text("\(verdict): \(note.title)").foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    if let agentName { Text("· handed back to \(agentName)").foregroundStyle(PennantTheme.inkTertiary).lineLimit(1) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.zoomed(.caption2).weight(.semibold)).foregroundStyle(PennantTheme.inkTertiary)
                }
                .font(.zoomed(.caption))
            }
            .buttonStyle(.plain)
            .help("What \(agentName ?? "the agent") was told")
            if expanded {
                Text(text).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).textSelection(.enabled)
                    .padding(10).frame(maxWidth: 560, alignment: .leading)
                    .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var verdict: String {
        switch note.verdict { case .approved: return "Approved"; case .changesRequested: return "Changes requested"; case .rejected: return "Rejected"; case .pending: return "Pending" }
    }
    private var symbol: String {
        switch note.verdict { case .approved: return "checkmark.seal.fill"; case .changesRequested: return "arrow.uturn.backward.circle.fill"; case .rejected: return "xmark.circle.fill"; case .pending: return "clock" }
    }
    private var color: Color {
        switch note.verdict { case .approved: return PennantTheme.success; case .changesRequested: return PennantTheme.warning; case .rejected: return PennantTheme.danger; case .pending: return PennantTheme.inkTertiary }
    }
}

struct MessageRow: View {
    @Environment(\.hostSession) private var session
    var message: Message
    var agent: AgentProfile?
    var task: TaskRecord?
    var pairing = ToolPairing()

    private enum Piece {
        case text(String)
        case activity(ToolActivity)
        case part(ContentPart)
        var isActivity: Bool { if case .activity = self { return true } else { return false } }
    }

    /// Runs of `.text` parts merged into one piece, calls paired with their results, everything else in order.
    private var pieces: [Piece] {
        let records = message.taskID.flatMap { session.state.toolRecords[$0] } ?? []
        let taskActive = task.map { !$0.state.isTerminal } ?? message.isStreaming
        var out: [Piece] = []
        for part in message.parts {
            switch part {
            case .text(let t):
                if case .text(let prev)? = out.last {
                    out[out.count - 1] = .text(prev + "\n" + t)
                } else {
                    out.append(.text(t))
                }
            case .toolCall(let call):
                let record = records.first { $0.call.id == call.id }
                out.append(.activity(ToolActivity(call: call, result: pairing.results[call.id], record: record, taskActive: taskActive)))
            case .toolResult(let result):
                // Shown on the call's card when the call is on screen; on its own small card otherwise.
                if pairing.calls.contains(result.callID) { continue }
                let record = records.first { $0.call.id == result.callID }
                out.append(.activity(ToolActivity(call: nil, result: result, record: record)))
            default:
                out.append(.part(part))
            }
        }
        return out
    }

    var body: some View {
        switch message.role {
        case .user where DecisionNote(text: message.text) != nil:
            DecisionNoteRow(note: DecisionNote(text: message.text)!, text: message.text, agentName: agent?.name)
        case .user:
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 0) {
                    // Every message says whose it is, so people sharing one Pennant can tell theirs apart.
                    if let author = message.author {
                        Text(author.name).font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                            .padding(.trailing, 6).padding(.bottom, 3)
                    }
                    piecesView(alignTrailing: true)
                }
            }
        case .assistant, .tool:
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    piecesView(alignTrailing: false)
                    if message.isStreaming, message.parts.isEmpty {
                        TypingDots()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(PennantTheme.assistantBubble, in: RoundedRectangle(cornerRadius: PennantTheme.bubbleRadius, style: .continuous))
                    }
                    if showsTime {
                        MessageTime(date: message.createdAt, stats: message.stats)
                            .padding(.leading, 8)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 80)
            }
        case .system:
            Text(message.text)
                .font(.zoomed(.caption))
                .foregroundStyle(PennantTheme.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        }
    }

    /// Agent replies carry their time once they have finished. Tool-only turns do not: their cards show
    /// how long each call took, and a time under every card would be noise.
    private var showsTime: Bool {
        guard !message.isStreaming else { return false }
        return message.parts.contains { part in
            if case .text(let t) = part { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }

    /// The pieces stacked: 6 pt between bubbles, 4 pt between consecutive activity cards so a run of tool
    /// calls reads as one block.
    @ViewBuilder private func piecesView(alignTrailing: Bool) -> some View {
        let items = pieces
        ForEach(Array(items.enumerated()), id: \.offset) { index, piece in
            let tight = index > 0 && piece.isActivity && items[index - 1].isActivity
            Group {
                switch piece {
                case .text(let text): MessageBubble(text: text, mine: alignTrailing)
                case .activity(let activity): ToolActivityCard(activity: activity)
                case .part(let part): PartView(part: part, message: message, task: task, alignTrailing: alignTrailing)
                }
            }
            .padding(.top, index == 0 ? 0 : (tight ? 4 : 6))
        }
    }
}

/// A rounded speech bubble. `mine` is the dark bubble on the right; otherwise the light one on the left.
/// The whole message copies in one go: on the Mac from a button beside it on hover, on the iPhone from a long press
/// (Copy, or Select Text to pick out part of it). Selecting within a paragraph works as usual.
struct MessageBubble: View {
    var text: String
    var mine: Bool
    @State private var hovering = false
    @State private var copied = false
    @State private var selecting = false

    private var bubble: some View {
        PennantMarkdown(text, onDark: mine)
            .tint(mine ? PennantTheme.userBubbleText : ShellPalette.info)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(mine ? PennantTheme.userBubble : PennantTheme.assistantBubble, in: RoundedRectangle(cornerRadius: PennantTheme.bubbleRadius, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        #if os(iOS)
        bubble
            .contextMenu {
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { selecting = true } label: { Label("Select Text", systemImage: "character.cursor.ibeam") }
            }
            .sheet(isPresented: $selecting) { SelectableTextSheet(text: text) }
        #else
        HStack(alignment: .bottom, spacing: 6) {
            if mine { copyButton }
            bubble
            if !mine { copyButton }
        }
        .onHover { hovering = $0 }
        #endif
    }

    #if os(macOS)
    private var copyButton: some View {
        Button { copy() } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.zoomed(size: 11, weight: .semibold))
                .foregroundStyle(copied ? PennantTheme.success : PennantTheme.inkTertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy message")
        .opacity(hovering || copied ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
    #endif

    private func copy() {
        copyToPasteboard(text)
        withAnimation(.snappy) { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(.snappy) { copied = false } }
    }
}

#if os(iOS)
/// A message in full, where any part of it can be selected and copied.
struct SelectableTextSheet: View {
    var text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .padding(.horizontal, 12)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarLeading) { Button("Copy All") { copyToPasteboard(text); dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// UITextView, read-only but selectable: SwiftUI's Text only copies whole.
struct SelectableTextView: UIViewRepresentable {
    var text: String
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.dataDetectorTypes = [.link]
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) { if v.text != text { v.text = text } }
}
#endif

struct PartView: View {
    @Environment(\.hostSession) private var session
    var part: ContentPart
    var message: Message
    var task: TaskRecord?
    var alignTrailing: Bool

    private func record(for id: ToolCallID) -> ToolRecord? {
        guard let taskID = message.taskID else { return nil }
        return session.state.toolRecords[taskID]?.first { $0.call.id == id }
    }

    var body: some View {
        switch part {
        case .text(let text):
            MessageBubble(text: text, mine: alignTrailing)
        case .reasoning(let text):
            ReasoningDisclosure(text: text, streaming: message.isStreaming)
        case .image(let ref):
            ArtifactImageView(ref: ref)
        case .toolCall(let call):
            ToolActivityCard(activity: ToolActivity(call: call, record: record(for: call.id), taskActive: task.map { !$0.state.isTerminal } ?? message.isStreaming))
        case .toolResult(let result):
            ToolActivityCard(activity: ToolActivity(result: result, record: record(for: result.callID)))
        case .file(let ref):
            FileAttachmentView(ref: ref)
        case .approval(let request):
            ApprovalCard(request: request)
        case .report(let report):
            ReportCardView(report: report)
        case .choices(let question):
            ChoiceCard(question: question, task: task)
        case .update(let update):
            WorkUpdateRow(update: update, worded: message.parts.contains { !($0.plainText ?? "").isEmpty })
        }
    }
}

extension Text {
    init(markdown: String) {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            self.init(attributed)
        } else {
            self.init(verbatim: markdown)
        }
    }
}

struct ReasoningDisclosure: View {
    var text: String
    var streaming: Bool
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(streaming ? "Thinking…" : "Reasoning")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.zoomed(.caption2))
                }
                .font(.zoomed(.caption))
                .foregroundStyle(PennantTheme.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ArtifactImageView: View {
    @Environment(\.hostSession) private var session
    var ref: ImageRef
    @State private var enlarged = false
    var body: some View {
        Group {
            if let img = ArtifactCache.shared.image(for: ref.artifactID) {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: enlarged ? .infinity : 360)
                    .clipShape(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
                    .onTapGesture { withAnimation { enlarged.toggle() } }
            } else {
                RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous)
                    .fill(PennantTheme.cardBackground)
                    .frame(width: 240, height: 140)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .onAppear { ArtifactCache.shared.load(ref.artifactID, using: session) }
        .help(ref.caption)
    }
}

/// The agent asked a question and is waiting. The composer sends the answer.
struct WaitingForAnswerView: View {
    var task: TaskRecord
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(ShellPalette.violet)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for your answer").font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                if !task.stateReason.isEmpty {
                    Text(task.stateReason).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(ShellPalette.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(ShellPalette.violet.opacity(0.25)))
    }
}

#if os(iOS)
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

/// Unsent text and files, one per thread. The conversation view is reused across an agent's threads, so a single draft
/// showed in every one of them (with one agent, in every thread there is). A new, unstarted thread has its own draft.
struct ThreadDrafts {
    struct Draft: Equatable { var text = ""; var attachments: [ComposerAttachment] = [] }
    private var parked: [ConversationID: Draft] = [:]
    private var newThread = Draft()
    /// The thread this view's first message just started: the box stays as it is when it gets its id.
    var startedHere: ConversationID?

    /// Parks what's in the box for the thread being left and returns what the box holds for the next one.
    mutating func switching(from old: ConversationID?, to new: ConversationID?, leaving: Draft) -> Draft {
        if old == nil, let new, new == startedHere {
            newThread = Draft()
            startedHere = nil
            return leaving
        }
        if let old { parked[old] = leaving == Draft() ? nil : leaving } else { newThread = leaving }
        guard let new else { return newThread }
        return parked[new] ?? Draft()
    }
}

private extension ContentPart {
    var isApproval: Bool { if case .approval = self { return true }; return false }
    var isUpdate: Bool { if case .update = self { return true }; return false }
}
