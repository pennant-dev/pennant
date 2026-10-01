import PennantClientKit
import PennantCore
import SwiftUI

/// The host setting that closes quiet threads on its own (it checks every few hours). A thread with work going, a
/// question or card waiting, or an active goal's thread stays; closed ones come back when something happens.
public struct AutoTidyPicker: View {
    @Environment(\.hostSession) private var session
    @State private var days: Int = 0
    @State private var loaded = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Close quiet threads automatically", selection: $days) {
                Text("Never").tag(0)
                Text("After a day").tag(1)
                Text("After 3 days").tag(3)
                Text("After a week").tag(7)
                Text("After 30 days").tag(30)
                Text("After 90 days").tag(90)
            }
            .disabled(!loaded)
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
        }
        .task {
            guard !loaded, let c = try? await session.getConfig().config else { return }
            days = c.autoCloseIdleDays ?? 0
            loaded = true
        }
        .onChange(of: days) { _, new in
            guard loaded else { return }
            Task {
                do {
                    var c = try await session.getConfig().config
                    c.autoCloseIdleDays = new == 0 ? nil : new
                    _ = try await session.updateConfig(c)
                    error = nil
                } catch { self.error = HostSessionError.message(error) }
            }
        }
    }
}

/// Closes every open conversation (of one agent, or all) with nothing new for `days` days. Returns how many.
@MainActor public func closeIdleConversations(_ session: HostSession, agentID: AgentID? = nil, days: Int) async throws -> Int {
    if agentID == nil { return try await session.pruneConversations(idleDays: days) }
    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    let idle = session.state.conversations.filter { !$0.isClosed && $0.updatedAt < cutoff && $0.agentID == agentID }
    for c in idle { try await session.closeConversation(c.id, closed: true) }
    return idle.count
}

#if os(iOS)
/// Every conversation (of one agent, or all), with what needs you first: swipe to close or delete, tidy up in bulk.
public struct PhoneConversationsView: View {
    @Environment(\.hostSession) private var session
    var agentID: AgentID?
    var onOpen: (AgentID, ConversationID) -> Void
    @State private var showClosed = false
    @State private var confirmDelete: [ConversationID] = []
    @State private var status: String?

    public init(agentID: AgentID? = nil, onOpen: @escaping (AgentID, ConversationID) -> Void) {
        self.agentID = agentID
        self.onOpen = onOpen
    }

    private var open: [Conversation] {
        session.state.conversations.filter { !$0.isClosed && (agentID == nil || $0.agentID == agentID) }
            .sorted { a, b in
                let na = session.state.conversationNeedsUser(a.id), nb = session.state.conversationNeedsUser(b.id)
                return na != nb ? na : a.updatedAt > b.updatedAt
            }
    }
    private var closed: [Conversation] {
        session.state.conversations.filter { $0.isClosed && (agentID == nil || $0.agentID == agentID) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var body: some View {
        List {
            if let status { Section { Text(status).font(.zoomed(.footnote)).foregroundStyle(PennantTheme.inkSecondary) } }
            Section(open.isEmpty ? "No open conversations" : "Open") {
                ForEach(open) { c in row(c) }
            }
            if !closed.isEmpty {
                Section {
                    DisclosureGroup("Closed (\(closed.count))", isExpanded: $showClosed) {
                        ForEach(closed) { c in row(c) }
                    }
                }
            }
            Section { AutoTidyPicker() } footer: { Text("Closed conversations leave your lists. Writing in one, or reopening it here, brings it back.") }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Close idle for a week") { tidy(7) }
                    Button("Close idle for 30 days") { tidy(30) }
                    if !closed.isEmpty {
                        Divider()
                        Button("Delete closed conversations…", role: .destructive) { confirmDelete = closed.map(\.id) }
                    }
                } label: { Label("Tidy up", systemImage: "wand.and.sparkles") }
            }
        }
        .confirmationDialog("Delete \(confirmDelete.count) conversation\(confirmDelete.count == 1 ? "" : "s") for good?",
                            isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = confirmDelete
                Task { try? await session.deleteConversations(ids); status = "Deleted \(ids.count)" }
            }
        } message: {
            Text("Their messages and tasks are removed and can't be restored. What agents learned from them stays in memory.")
        }
    }

    private func row(_ c: Conversation) -> some View {
        let agent = session.state.agent(c.agentID)
        let needs = session.state.conversationNeedsUser(c.id)
        return Button { onOpen(c.agentID, c.id) } label: {
            HStack(spacing: 10) {
                if let agent { AgentAvatar(agent: agent, size: 28) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(conversationLabel(c)).font(.zoomed(.body).weight(needs ? .semibold : .regular)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                        if needs { Text("Needs you").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.color(for: AgentStatus.waitingForUser)) }
                    }
                    Text("\(agentID == nil ? (agent?.name ?? "") + " · " : "")\(conversationTimestamp(c.updatedAt))").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirmDelete = [c.id] } label: { Label("Delete", systemImage: "trash") }
            if c.isClosed {
                Button { Task { try? await session.closeConversation(c.id, closed: false) } } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }.tint(.blue)
            } else {
                Button { Task { try? await session.closeConversation(c.id, closed: true) } } label: { Label("Close", systemImage: "checkmark.circle") }.tint(.gray)
            }
        }
        .swipeActions(edge: .leading) {
            if session.state.isUnread(c.id) {
                Button { session.state.markRead(c.id) } label: { Label("Read", systemImage: "envelope.open") }.tint(.blue)
            }
        }
    }

    private func tidy(_ days: Int) {
        Task {
            do {
                let n = try await closeIdleConversations(session, agentID: agentID, days: days)
                status = n == 0 ? "Nothing that idle." : "Closed \(n) conversation\(n == 1 ? "" : "s")."
            } catch { status = HostSessionError.message(error) }
        }
    }
}
#endif
