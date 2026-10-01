import PennantClientKit
import PennantCore
import SwiftUI

/// The sidebar now that Pennant is the one agent: what needs you on top, then every thread newest first, then the
/// closed ones folded away.
///
/// A thread closes with a swipe to the left (two fingers on a trackpad, one on a phone) or the ✕ that shows on hover,
/// and each close can be undone for a few seconds. Closing only tidies: nothing stops, and a closed thread comes back
/// by itself when something happens in it. Threads one agent started for another (a question, a Coder run) live under
/// the thread that asked and aren't listed.
public struct ThreadListView: View {
    @Environment(\.hostSession) private var session
    var selected: ConversationID?
    var onOpen: (AgentID, ConversationID?) -> Void
    var onNewThread: () -> Void
    @State private var query = ""
    @State private var showClosed = false
    @State private var closedShown = 30
    @State private var lastClosed: Conversation?

    public init(selected: ConversationID?, onOpen: @escaping (AgentID, ConversationID?) -> Void, onNewThread: @escaping () -> Void) {
        self.selected = selected
        self.onOpen = onOpen
        self.onNewThread = onNewThread
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            List {
                needsYouSection
                threadsSection
                closedSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        }
        .overlay(alignment: .bottom) { undoBar }
        .animation(.easeOut(duration: 0.18), value: lastClosed?.id)
    }

    // MARK: Data

    /// Threads the list shows: the agents' own (not a helper's, not one started for another thread).
    private var listed: [Conversation] {
        session.state.conversations.filter { c in
            c.parentID == nil && session.state.agent(c.agentID)?.kind == .persistent && matches(c)
        }
    }

    private var openThreads: [Conversation] { listed.filter { !$0.isClosed }.sorted { $0.updatedAt > $1.updatedAt } }
    private var closedThreads: [Conversation] { listed.filter(\.isClosed).sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) } }

    private func matches(_ c: Conversation) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || conversationLabel(c).localizedCaseInsensitiveContains(q) || c.preview.localizedCaseInsensitiveContains(q)
    }

    /// One thing waiting on the owner: an approval card, or a question a task is waiting on.
    struct Ask: Identifiable {
        var id: String
        var kind: String
        var title: String
        var conversation: Conversation
    }

    /// Cards first, then questions, newest first; nothing from a thread that's closed.
    private var asks: [Ask] {
        var out: [Ask] = []
        var seen = Set<ConversationID>()
        for p in session.state.pendingApprovals {
            guard let c = session.state.conversation(p.conversationID), !c.isClosed else { continue }
            out.append(Ask(id: "a:" + p.id, kind: p.request.destination.isEmpty ? "Approve" : "Approve · " + p.request.destination, title: p.request.title, conversation: c))
            seen.insert(c.id)
        }
        for t in session.state.tasks where t.state == .waitingForUser && t.parentTaskID == nil && !seen.contains(t.conversationID) {
            guard let c = session.state.conversation(t.conversationID), !c.isClosed else { continue }
            out.append(Ask(id: "q:" + t.id.rawValue, kind: "Question", title: conversationLabel(c), conversation: c))
            seen.insert(c.id)
        }
        return out.filter { matches($0.conversation) || $0.title.localizedCaseInsensitiveContains(query) || query.isEmpty }
    }

    // MARK: Sections

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            TextField("Search threads", text: $query)
                .textFieldStyle(.plain)
                .font(.zoomed(.callout))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PennantTheme.inkTertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var needsYouSection: some View {
        let items = asks
        Section {
            if items.isEmpty {
                Text("Nothing needs you.")
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .plainRow()
            }
            ForEach(items) { ask in
                AskRow(ask: ask) { onOpen(ask.conversation.agentID, ask.conversation.id) }
                    .plainRow()
            }
        } header: {
            SectionTitle(text: "Needs you", count: items.count, tint: PennantTheme.brandInk)
        }
    }

    /// What the rows need to know, looked up once per render instead of once per row.
    private var facts: RowFacts { RowFacts(state: session.state) }

    @ViewBuilder private var threadsSection: some View {
        let threads = openThreads
        let facts = facts
        Section {
            if threads.isEmpty {
                Text(query.isEmpty ? (session.connection.isConnected ? "No threads yet." : "Waiting for the host…") : "No threads match.")
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .padding(.horizontal, 8)
                    .plainRow()
            }
            ForEach(threads) { c in
                ThreadRow(model: facts.row(c, selected: selected == c.id), action: { open(c) }, onToggle: { close(c) })
                    .equatable()
                    .plainRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { close(c) } label: { Label("Close", systemImage: "checkmark.circle") }
                            .tint(PennantTheme.inkSecondary)
                    }
                    .contextMenu { rowMenu(c) }
            }
        } header: {
            HStack(spacing: 6) {
                SectionTitle(text: "Threads", count: threads.count)
                Button(action: onNewThread) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.pennantIcon)
                    .help("New thread")
                    .accessibilityLabel("New thread")
            }
        }
    }

    @ViewBuilder private var closedSection: some View {
        let closed = closedThreads
        let facts = facts
        Section {
            if showClosed {
                ForEach(closed.prefix(closedShown)) { c in
                    ThreadRow(model: facts.row(c, selected: selected == c.id), action: { open(c) }, onToggle: { reopen(c) })
                        .equatable()
                        .plainRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { reopen(c) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                                .tint(PennantTheme.success)
                        }
                        .contextMenu { rowMenu(c) }
                }
                if closed.count > closedShown {
                    Button("Show \(min(30, closed.count - closedShown)) more") { closedShown += 30 }
                        .buttonStyle(.plain)
                        .font(.zoomed(.caption))
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .padding(.horizontal, 8)
                        .plainRow()
                }
            }
        } header: {
            Button { withAnimation(.easeInOut(duration: 0.15)) { showClosed.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.zoomed(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showClosed ? 90 : 0))
                    SectionTitle(text: "Closed", count: closed.count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showClosed ? "Hide closed threads" : "Show closed threads")
        }
    }

    @ViewBuilder private func rowMenu(_ c: Conversation) -> some View {
        if c.isClosed {
            Button { reopen(c) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
        } else {
            Button { close(c) } label: { Label("Close", systemImage: "checkmark.circle") }
        }
        if session.state.isUnread(c) {
            Button { session.state.markRead(c.id) } label: { Label("Mark as read", systemImage: "envelope.open") }
        }
        OpenInNewWindowItem(agentID: c.agentID, conversationID: c.id)
    }

    // MARK: Undo

    @ViewBuilder private var undoBar: some View {
        if let c = lastClosed {
            HStack(spacing: 10) {
                Text("Closed “\(conversationLabel(c))”")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Undo") { reopen(c); lastClosed = nil }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(PennantTheme.brandSoft)
            }
            .font(.zoomed(.callout))
            .foregroundStyle(PennantTheme.windowBackground)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(PennantTheme.ink, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
            .padding(10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: c.id) {
                try? await Task.sleep(for: .seconds(5))
                if lastClosed?.id == c.id { lastClosed = nil }
            }
        }
    }

    // MARK: Actions

    private func open(_ c: Conversation) {
        session.state.markRead(c.id)
        onOpen(c.agentID, c.id)
    }

    private func close(_ c: Conversation) {
        lastClosed = c
        Task { try? await session.closeConversation(c.id, closed: true) }
    }

    private func reopen(_ c: Conversation) {
        Task { try? await session.closeConversation(c.id, closed: false) }
    }
}

// MARK: Rows

private extension View {
    /// A list row drawn by the row itself: no system inset, separator or background.
    func plainRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct SectionTitle: View {
    var text: String
    var count: Int
    var tint: Color = PennantTheme.inkSecondary
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.zoomed(.caption2).weight(.semibold))
                .tracking(0.6)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)").font(.zoomed(.caption2).weight(.semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(tint)
    }
}

/// Something waiting on the owner, with the thread it's in.
private struct AskRow: View {
    var ask: ThreadListView.Ask
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5).fill(PennantTheme.brand).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ask.kind)
                        .font(.zoomed(.caption2).weight(.semibold))
                        .foregroundStyle(PennantTheme.brandInk)
                        .lineLimit(1)
                    Text(ask.title)
                        .font(.zoomed(.callout).weight(.semibold))
                        .foregroundStyle(PennantTheme.ink)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if let symbol = threadSymbol(ask.conversation) {
                            Image(systemName: symbol).font(.zoomed(size: 9, weight: .semibold))
                        }
                        Text(conversationLabel(ask.conversation)).lineLimit(1)
                    }
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusSmall + 2, style: .continuous).stroke(hovering ? PennantTheme.brand : PennantTheme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(ask.kind): \(ask.title), in \(conversationLabel(ask.conversation))")
    }
}

/// Sets built once per render of the list, so each row is a few lookups rather than scans of every task and agent.
@MainActor struct RowFacts {
    let needsYou: Set<ConversationID>
    let working: Set<ConversationID>
    let goals: Set<ConversationID>
    let state: ClientState

    init(state: ClientState) {
        self.state = state
        needsYou = Set(state.pendingApprovals.map(\.conversationID)).union(state.tasks.filter { $0.state == .waitingForUser }.map(\.conversationID))
        working = Set(state.tasks.filter { [.running, .waitingForTool, .waitingForDesktop].contains($0.state) }.map(\.conversationID))
        goals = Set(state.goals.compactMap(\.conversationID))
    }

    func row(_ c: Conversation, selected: Bool) -> ThreadRowModel {
        let title = conversationLabel(c)
        let symbol = goals.contains(c.id) ? "target" : (threadSymbol(c) ?? (c.isCodingRun ? "chevron.left.forwardslash.chevron.right" : "bubble.left"))
        return ThreadRowModel(title: title, preview: c.preview, time: conversationTimestamp(c.updatedAt), closed: c.isClosed,
                              symbol: symbol, needsYou: !c.isClosed && needsYou.contains(c.id),
                              working: working.contains(c.id), unread: state.isUnread(c) && !selected, selected: selected)
    }
}

/// Everything a thread row shows, as plain values: equal models mean the row doesn't redraw.
struct ThreadRowModel: Equatable {
    var title: String
    var preview: String
    var time: String
    var closed: Bool
    var symbol: String
    var needsYou: Bool
    var working: Bool
    var unread: Bool
    var selected: Bool
}

/// One thread: what kind it is, its name and latest line, when it last moved, and whether it needs you, is working,
/// or has something unread. On hover, a ✕ (or ↺ for a closed one) replaces the time.
struct ThreadRow: View, Equatable {
    var model: ThreadRowModel
    var action: () -> Void
    var onToggle: () -> Void
    @State private var hovering = false

    nonisolated static func == (a: ThreadRow, b: ThreadRow) -> Bool { MainActor.assumeIsolated { a.model == b.model } }

    var body: some View {
        let m = model
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: m.symbol)
                    .font(.zoomed(size: 12, weight: .medium))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(m.selected ? PennantTheme.cardElevated : PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m.title)
                            .font(.zoomed(.callout).weight(m.unread || m.needsYou ? .semibold : .regular))
                            .foregroundStyle(m.closed ? PennantTheme.inkSecondary : PennantTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(m.time)
                            .font(.zoomed(.caption))
                            .foregroundStyle(PennantTheme.inkTertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .opacity(hovering ? 0 : 1)
                    }
                    HStack(spacing: 5) {
                        Text(m.preview.isEmpty ? " " : m.preview)
                            .font(.zoomed(.caption))
                            .foregroundStyle(PennantTheme.inkSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if m.needsYou {
                            Circle().fill(PennantTheme.brand).frame(width: 8, height: 8).help("Needs you")
                        } else if m.working {
                            // The system spinner, only while work is actually going in this thread.
                            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 12, height: 12).help("Working")
                        } else if m.unread {
                            Circle().fill(PennantTheme.info).frame(width: 7, height: 7).help("New since you last looked")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(m.selected ? PennantTheme.selection : (hovering ? PennantTheme.hover : PennantTheme.sidebarBackground),
                        in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall + 1, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: PennantTheme.radiusSmall + 1, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onToggle) {
                    Image(systemName: m.closed ? "arrow.uturn.backward" : "xmark")
                        .font(.zoomed(size: 9, weight: .bold))
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .frame(width: 20, height: 20)
                        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(PennantTheme.border))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .padding(.trailing, 6)
                .help(m.closed ? "Reopen" : "Close (it comes back if anything happens in it)")
                .accessibilityLabel(m.closed ? "Reopen \(m.title)" : "Close \(m.title)")
            }
        }
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityHint(m.needsYou ? "Needs you" : (m.unread ? "Unread" : ""))
    }
}

/// "Open in New Window" when the app has more than one window (the Mac).
private struct OpenInNewWindowItem: View {
    @Environment(\.openInNewWindow) private var openInNewWindow
    var agentID: AgentID
    var conversationID: ConversationID
    var body: some View {
        if let openInNewWindow {
            Button { openInNewWindow(agentID, conversationID) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
        }
    }
}
