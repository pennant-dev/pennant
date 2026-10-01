import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// A conversation to show in a window of its own.
struct ConversationRef: Codable, Hashable {
    var agentID: AgentID
    var conversationID: ConversationID
}

/// Every thread in one window: find one, open it in its own window, and keep things tidy by closing (reversible) or
/// deleting (for good) threads, one by one or all the idle ones at once. Helpers' threads stay with the work that
/// started them.
struct ConversationsWindow: View {
    @Environment(\.hostSession) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var filter: Filter = .open
    @State private var selection = Set<ConversationID>()
    @State private var sortOrder = [KeyPathComparator(\Row.updatedAt, order: .reverse)]
    @State private var confirmDelete = false
    @State private var showPrune = false
    @State private var pruneDays = 30
    @State private var status: String?
    @State private var busy = false

    enum Filter: String, CaseIterable, Identifiable {
        case open, idle, closed, all
        var id: String { rawValue }
        var title: String {
            switch self { case .open: return "Open"; case .idle: return "Idle 30+ days"; case .closed: return "Closed"; case .all: return "All" }
        }
    }

    struct Row: Identifiable, Hashable {
        var id: ConversationID
        var agentID: AgentID
        var title: String
        var preview: String
        var updatedAt: Date
        var closed: Bool
        var working: Bool
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let idleCutoff = Date().addingTimeInterval(-30 * 86400)
        let busyConversations = Set(session.state.tasks.filter { !$0.state.isTerminal }.map(\.conversationID))
        return session.state.conversations.compactMap { c -> Row? in
            guard session.state.agent(c.agentID)?.kind == .persistent else { return nil }
            switch filter {
            case .open: if c.isClosed { return nil }
            case .idle: if c.isClosed || c.updatedAt > idleCutoff { return nil }
            case .closed: if !c.isClosed { return nil }
            case .all: break
            }
            let title = conversationLabel(c)
            if !q.isEmpty, !(title.lowercased().contains(q) || c.preview.lowercased().contains(q)) { return nil }
            return Row(id: c.id, agentID: c.agentID, title: title, preview: c.preview, updatedAt: c.updatedAt,
                       closed: c.isClosed, working: busyConversations.contains(c.id))
        }.sorted(using: sortOrder)
    }

    private var selectedRows: [Row] { rows.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(PennantTheme.windowBackground)
        .confirmationDialog("Delete \(selection.count) conversation\(selection.count == 1 ? "" : "s") for good?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete(Array(selection)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their messages and tasks are removed and can't be restored. What agents learned from them stays in memory. To only tidy up, close them instead.")
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            SearchField("Search conversations", text: $query)
                .frame(maxWidth: 280)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button { showPrune = true } label: { Label("Tidy up…", systemImage: "wand.and.sparkles") }
                .buttonStyle(.pennantCompact)
                .popover(isPresented: $showPrune, arrowEdge: .bottom) { prunePanel }
        }
        .padding(12)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Conversation", value: \.title) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.title).fontWeight(.medium).lineLimit(1)
                        if row.working { Chip("Working", color: PennantTheme.success) }
                        if row.closed { Chip("Closed", color: PennantTheme.inkTertiary) }
                    }
                    if !row.preview.isEmpty, row.preview != row.title {
                        Text(row.preview).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            TableColumn("Last activity", value: \.updatedAt) { row in
                Text(relativeTime(row.updatedAt)).foregroundStyle(PennantTheme.inkSecondary)
            }
            .width(min: 90, ideal: 120, max: 160)
        }
        .contextMenu(forSelectionType: ConversationID.self) { ids in
            if ids.count == 1, let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Open in New Window") { open(row) }
            }
            if rowsFor(ids).contains(where: { !$0.closed }) { Button("Close") { close(ids, closed: true) } }
            if rowsFor(ids).contains(where: \.closed) { Button("Reopen") { close(ids, closed: false) } }
            Divider()
            Button("Delete…", role: .destructive) { selection = ids; confirmDelete = true }
        } primaryAction: { ids in
            for row in rowsFor(ids) { open(row) }
        }
    }

    private func rowsFor(_ ids: Set<ConversationID>) -> [Row] { rows.filter { ids.contains($0.id) } }

    private var footer: some View {
        HStack(spacing: 8) {
            if let status {
                Text(status).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            } else {
                Text("\(rows.count) conversation\(rows.count == 1 ? "" : "s")\(selection.isEmpty ? "" : " · \(selection.count) selected")")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            }
            Spacer()
            if !selection.isEmpty {
                Button("Open") { for row in selectedRows { open(row) } }.buttonStyle(.pennantCompact)
                if selectedRows.contains(where: { !$0.closed }) { Button("Close") { close(selection, closed: true) }.buttonStyle(.pennantCompact) }
                if selectedRows.contains(where: \.closed) { Button("Reopen") { close(selection, closed: false) }.buttonStyle(.pennantCompact) }
                Button("Delete…", role: .destructive) { confirmDelete = true }.buttonStyle(.pennantCompact)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(busy)
    }

    /// Tidy up: close everything idle for a while (reversible), or delete what's been closed.
    private var prunePanel: some View {
        let cutoff = Date().addingTimeInterval(-Double(pruneDays) * 86400)
        let idle = session.state.conversations.filter { !$0.isClosed && $0.updatedAt < cutoff }
        let closed = session.state.conversations.filter(\.isClosed)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Tidy up").font(.zoomed(.headline))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Close conversations with nothing new for")
                    Picker("", selection: $pruneDays) {
                        Text("a week").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    .labelsHidden().fixedSize()
                }
                HStack {
                    Text(idle.isEmpty ? "Nothing that idle." : "\(idle.count) conversation\(idle.count == 1 ? "" : "s")")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    Spacer()
                    Button("Close them") { prune() }.buttonStyle(.pennantPrimaryCompact).disabled(idle.isEmpty || busy)
                }
                Text("Closed conversations leave the sidebar; reopen them here any time, or by writing in them.")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            }
            Divider()
            AutoTidyPicker()
            Divider()
            HStack {
                Text(closed.isEmpty ? "No closed conversations." : "\(closed.count) closed conversation\(closed.count == 1 ? "" : "s")")
                    .font(.zoomed(.callout))
                Spacer()
                Button("Delete them…", role: .destructive) {
                    selection = Set(closed.map(\.id))
                    showPrune = false
                    confirmDelete = true
                }
                .buttonStyle(.pennantCompact)
                .disabled(closed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    // MARK: Actions

    private func open(_ row: Row) {
        openWindow(id: "conversation", value: ConversationRef(agentID: row.agentID, conversationID: row.id))
    }

    private func close(_ ids: Set<ConversationID>, closed: Bool) {
        run("\(closed ? "Closed" : "Reopened") \(ids.count) conversation\(ids.count == 1 ? "" : "s")") {
            for id in ids { try await session.closeConversation(id, closed: closed) }
        }
    }

    private func delete(_ ids: [ConversationID]) {
        run("Deleted \(ids.count) conversation\(ids.count == 1 ? "" : "s")") {
            try await session.deleteConversations(ids)
            selection.removeAll()
        }
    }

    private func prune() {
        let days = pruneDays
        showPrune = false
        busy = true
        Task {
            defer { busy = false }
            do {
                let n = try await session.pruneConversations(idleDays: days)
                withAnimation { status = "Closed \(n) idle conversation\(n == 1 ? "" : "s")" }
            } catch { status = String(describing: error) }
        }
    }

    private func run(_ done: String, _ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); withAnimation { status = done } } catch { status = String(describing: error) }
        }
    }
}

/// One conversation in a window of its own: the agent's name and the conversation's title on top, the thread below.
struct ConversationWindow: View {
    @Environment(\.hostSession) private var session
    var ref: ConversationRef
    @State private var conversationID: ConversationID?

    var body: some View {
        let agent = session.state.agent(ref.agentID)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let agent { AgentAvatar(agent: agent, size: 26) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent?.name ?? "Agent").font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
                    ConversationTitleMenu(agentID: ref.agentID, conversationID: $conversationID)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ConversationView(agentID: ref.agentID, conversationID: $conversationID)
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(PennantTheme.windowBackground)
        .navigationTitle(agent.map { "\($0.name) — \(session.state.conversation(ref.conversationID).map(conversationLabel) ?? "Conversation")" } ?? "Conversation")
        .onAppear { if conversationID == nil { conversationID = ref.conversationID } }
    }
}

/// Window › Conversations (⇧⌘K).
extension Notification.Name {
    /// File › New Thread: the main window opens a new thread with the lead agent.
    static let pennantNewThread = Notification.Name("dev.pennant.newThread")
}

/// File › New Thread (⌘N): a new thread in the main window, which comes back if it was closed.
struct NewThreadCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Thread") {
            openWindow(id: "main")
            NotificationCenter.default.post(name: .pennantNewThread, object: nil)
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

struct OpenConversationsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Conversations") { openWindow(id: "conversations") }
            .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}
