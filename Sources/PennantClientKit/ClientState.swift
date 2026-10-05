import PennantCore
import Foundation
import Observation

/// Client-side cache of host state, kept current by applying snapshots and events.
/// Enough to stay useful while disconnected; the host remains authoritative.
@MainActor
@Observable
public final class ClientState {
    public internal(set) var host: HostInfo?
    public internal(set) var agents: [AgentProfile] = []
    public internal(set) var tasks: [TaskRecord] = []
    public internal(set) var conversations: [Conversation] = []
    public internal(set) var messages: [ConversationID: [Message]] = [:]
    public internal(set) var toolRecords: [TaskID: [ToolRecord]] = [:]
    public internal(set) var checkpoints: [TaskID: [Checkpoint]] = [:]
    public internal(set) var desktop = DesktopStatus()
    public internal(set) var mcpServers: [MCPServerStatus] = []
    /// The host's teach-mode session: recording, stopped for review, or drafted. `nil` when there is none.
    public internal(set) var teaching: TeachingSession?
    public internal(set) var skills: [Skill] = []
    /// Approval cards waiting for the user, from every agent, newest first; kept current from message events.
    public internal(set) var pendingApprovals: [PendingApproval] = []
    /// Report cards from every agent, newest first; kept current from message events.
    public internal(set) var reports: [PostedReport] = []
    /// Who this app is signed in as; nil for the owner's own devices and older hosts.
    public internal(set) var me: Person?
    /// The people on this host (Settings › People).
    public internal(set) var people: PeopleDirectory?
    public func setPeople(_ directory: PeopleDirectory) { people = directory }
    public internal(set) var schedules: [ScheduledJob] = []
    public internal(set) var goals: [Goal] = []
    /// Boards of the goals the app has opened, by goal.
    public internal(set) var goalItems: [GoalID: [GoalItem]] = [:]
    public func setGoalItems(_ items: [GoalItem], for goal: GoalID) { goalItems[goal] = items }
    public internal(set) var entities: [MemoryEntity] = []
    public internal(set) var preferences: [Preference] = []
    public internal(set) var notices: [Notice] = []
    public internal(set) var lastEventSeq: EventSeq = 0
    /// Most recent screen frame (JPEG) and its header.
    public internal(set) var screenFrame: (header: ScreenFrameHeader, jpeg: Data)?
    /// Set when the last snapshot or event is older than the staleness threshold.
    public internal(set) var lastUpdateAt: Date?

    public struct Notice: Identifiable, Hashable, Sendable {
        public let id = UUID()
        public var level: NoticeLevel
        public var text: String
        public var at: Date
    }

    /// When this device last showed each conversation. A conversation that changed since is unread, which raises
    /// its agent's flag. Conversations never opened here count as read up to `readBaseline` (the first launch
    /// with this feature), so an old history doesn't light every flag.
    public internal(set) var readMarks: [ConversationID: Date] = [:]
    private var readBaseline = Date()
    private var readStore: UserDefaults?

    public init() {}

    /// Keeps read marks in `defaults` across launches (the apps pass `.standard`; tests and the CLI don't).
    public func persistReadMarks(in defaults: UserDefaults) {
        readStore = defaults
        if let base = defaults.object(forKey: Self.readBaselineKey) as? Date { readBaseline = base }
        else { defaults.set(readBaseline, forKey: Self.readBaselineKey) }
        let saved = defaults.dictionary(forKey: Self.readMarksKey) as? [String: Date] ?? [:]
        readMarks = Dictionary(uniqueKeysWithValues: saved.map { (ConversationID($0.key), $0.value) })
    }

    /// The user is looking at this conversation: everything in it up to now is read.
    public func markRead(_ id: ConversationID, at now: Date = Date()) {
        let seen = max(now, conversation(id)?.updatedAt ?? now)
        if let old = readMarks[id], old >= seen { return }
        readMarks[id] = seen
        readStore?.set(Dictionary(uniqueKeysWithValues: readMarks.map { ($0.key.rawValue, $0.value) }), forKey: Self.readMarksKey)
    }

    /// True when one of the agent's conversations changed after this device last showed it.
    public func hasUnread(agentID: AgentID) -> Bool {
        conversations.contains { $0.agentID == agentID && $0.updatedAt > (readMarks[$0.id] ?? readBaseline) }
    }

    /// The agent is waiting on the user: it asked something or has an approval card out. Something new but
    /// unread is not "needs you" (that's `hasUnread`, a quieter dot), or the flag would never come down.
    public func needsUser(agentID: AgentID) -> Bool {
        agent(agentID)?.status == .waitingForUser
            || pendingApprovals.contains { $0.agentID == agentID }
            || tasks.contains { $0.agentID == agentID && $0.state == .waitingForUser && $0.parentTaskID == nil }
    }

    /// This conversation is waiting on the user: a question in it, or an approval card in it.
    public func conversationNeedsUser(_ id: ConversationID) -> Bool {
        pendingApprovals.contains { $0.conversationID == id } || tasks.contains { $0.conversationID == id && $0.state == .waitingForUser }
    }

    /// Something in this conversation came after this device last showed it.
    public func isUnread(_ id: ConversationID) -> Bool {
        guard let c = conversation(id) else { return false }
        return isUnread(c)
    }

    /// The same, for a conversation already at hand (a list row), without looking it up again.
    public func isUnread(_ c: Conversation) -> Bool {
        c.updatedAt > (readMarks[c.id] ?? readBaseline)
    }

    /// Where to take the user when they open an agent: the conversation that needs them (newest first), else the
    /// newest unread one, else the latest.
    public func conversationToOpen(agentID: AgentID) -> ConversationID? {
        let all = conversations(for: agentID)
        return all.first { conversationNeedsUser($0.id) }?.id ?? all.first { isUnread($0.id) }?.id ?? all.first?.id
    }

    /// Every conversation of this agent (or every agent, for nil) counts as read on this device.
    public func markAllRead(agentID: AgentID? = nil, now: Date = Date()) {
        for c in conversations where agentID == nil || c.agentID == agentID { markRead(c.id, at: now) }
    }

    static let readMarksKey = "pennant.readMarks"
    static let readBaselineKey = "pennant.readBaseline"

    public func agent(_ id: AgentID) -> AgentProfile? { agents.first { $0.id == id } }
    public func task(_ id: TaskID) -> TaskRecord? { tasks.first { $0.id == id } }
    public func conversation(_ id: ConversationID) -> Conversation? { conversations.first { $0.id == id } }
    /// An agent's open conversations, newest first; closed ones only when asked for.
    public func conversations(for agentID: AgentID, includeClosed: Bool = false) -> [Conversation] {
        conversations.filter { $0.agentID == agentID && (includeClosed || !$0.isClosed) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    /// An agent's closed conversations, most recently closed first.
    public func closedConversations(for agentID: AgentID) -> [Conversation] {
        conversations.filter { $0.agentID == agentID && $0.isClosed }.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
    }
    public var persistentAgents: [AgentProfile] { agents.filter { $0.kind == .persistent && $0.status != .retired } }
    /// The agent the owner talks to (the only persistent one; workers are its helpers).
    public var leadAgent: AgentProfile? { persistentAgents.first }
    /// The Pennant chat: the one conversation people have with Pennant (nil on hosts from before it).
    public var mainConversation: Conversation? { conversations.first { $0.isMain } }
    /// Pennant's threads, as the Work list shows them: its conversations but the chat, without the ones a thread
    /// started inside another (a coding run's, a helper's), which open from their thread.
    public func isWorkThread(_ c: Conversation) -> Bool {
        guard !c.isMain, agent(c.agentID)?.kind == .persistent else { return false }
        return c.parentID == nil || c.parentID == mainConversation?.id
    }
    public var isStale: Bool { guard let t = lastUpdateAt else { return true }; return Date().timeIntervalSince(t) > 30 }

    public func apply(snapshot: StateSnapshot) {
        me = snapshot.me
        host = snapshot.host
        agents = snapshot.agents
        tasks = snapshot.tasks
        conversations = snapshot.conversations
        desktop = snapshot.desktop
        mcpServers = snapshot.mcpServers
        schedules = snapshot.schedules
        goals = snapshot.goals
        lastEventSeq = max(lastEventSeq, snapshot.latestEventSeq)
        lastUpdateAt = Date()
    }

    public func setMessages(_ page: [Message], for conversationID: ConversationID, prepend: Bool) {
        var existing = messages[conversationID] ?? []
        let known = Set(existing.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if prepend { existing = fresh + existing } else { existing += fresh }
        existing.sort { $0.createdAt < $1.createdAt }
        messages[conversationID] = existing
    }

    public func setToolRecords(_ records: [ToolRecord], for taskID: TaskID) { toolRecords[taskID] = records.sorted { $0.startedAt < $1.startedAt } }
    public func setSkills(_ items: [Skill]) { skills = items }
    public func setPendingApprovals(_ items: [PendingApproval]) { pendingApprovals = items }
    public func setReports(_ items: [PostedReport]) { reports = items }

    /// A card that appears or changes in a message: waiting cards join the list, decided ones leave it.
    func trackApprovals(in m: Message) {
        for case .report(let r) in m.parts where !reports.contains(where: { $0.id == r.id }) {
            reports.insert(PostedReport(report: r, agentID: m.agentID, conversationID: m.conversationID, messageID: m.id), at: 0)
        }
        for case .approval(let a) in m.parts {
            pendingApprovals.removeAll { $0.id == a.id }
            if a.state == .pending {
                pendingApprovals.insert(PendingApproval(request: a, agentID: m.agentID, conversationID: m.conversationID, messageID: m.id), at: 0)
            }
        }
    }
    public func setMCPServers(_ items: [MCPServerStatus]) { mcpServers = items }
    public func setSchedules(_ items: [ScheduledJob]) { schedules = items }
    public func setEntities(_ items: [MemoryEntity]) { entities = items }
    public func setPreferences(_ items: [Preference]) { preferences = items }
    public func setScreenFrame(_ header: ScreenFrameHeader, _ jpeg: Data) { screenFrame = (header, jpeg) }
    public func clearScreenFrame() { screenFrame = nil }

    public func apply(event: HostEvent) {
        if !event.payload.isTransient { lastEventSeq = max(lastEventSeq, event.seq) }
        // At most once a second: views that read it (the "may be stale" notice) would otherwise redraw on every
        // streamed word, and staleness is judged in tens of seconds.
        let now = Date()
        if now.timeIntervalSince(lastUpdateAt ?? .distantPast) >= 1 { lastUpdateAt = now }
        switch event.payload {
        case .hostStatus(let info):
            host = info
        case .agentUpserted(let agent):
            upsert(&agents, agent)
        case .agentRemoved(let id):
            agents.removeAll { $0.id == id }
            let gone = Set(conversations.filter { $0.agentID == id }.map(\.id))
            conversations.removeAll { $0.agentID == id }
            for c in gone { messages[c] = nil }
            let goneTasks = Set(tasks.filter { $0.agentID == id }.map(\.id))
            tasks.removeAll { $0.agentID == id }
            for t in goneTasks { toolRecords[t] = nil; checkpoints[t] = nil }
            schedules.removeAll { $0.agentID == id }
        case .conversationUpserted(let c):
            upsert(&conversations, c)
        case .conversationsRemoved(let ids):
            let gone = Set(ids)
            conversations.removeAll { gone.contains($0.id) }
            for c in gone { messages[c] = nil }
            let goneTasks = Set(tasks.filter { gone.contains($0.conversationID) }.map(\.id))
            tasks.removeAll { gone.contains($0.conversationID) }
            for t in goneTasks { toolRecords[t] = nil; checkpoints[t] = nil }
        case .messagesRemoved(let conversationID, let ids):
            let gone = Set(ids)
            messages[conversationID]?.removeAll { gone.contains($0.id) }
        case .messageAppended(let m), .messageFinalized(let m):
            var list = messages[m.conversationID] ?? []
            if let i = list.firstIndex(where: { $0.id == m.id }) { list[i] = m } else { list.append(m) }
            messages[m.conversationID] = list
            trackApprovals(in: m)
        case .messageDelta(let d):
            var list = messages[d.conversationID] ?? []
            if let i = list.firstIndex(where: { $0.id == d.messageID }) {
                var m = list[i]
                // An older host can send the end of the thinking and the start of the answer together: the thinking
                // came first.
                if let r = d.reasoningDelta { appendText(&m, r, reasoning: true) }
                if let t = d.textDelta { appendText(&m, t, reasoning: false) }
                if let call = d.toolCall { m.parts.append(.toolCall(call)) }
                list[i] = m
                messages[d.conversationID] = list
            }
        case .taskUpserted(let t):
            upsert(&tasks, t)
        case .taskTransition(let tr):
            if let i = tasks.firstIndex(where: { $0.id == tr.taskID }) {
                tasks[i].state = tr.to
                tasks[i].stateReason = tr.reason
                tasks[i].updatedAt = tr.at
            }
        case .toolRecordUpserted(let r):
            var list = toolRecords[r.taskID] ?? []
            if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r } else { list.append(r) }
            toolRecords[r.taskID] = list
        case .checkpointSaved(let c):
            var list = checkpoints[c.taskID] ?? []
            list.append(c)
            checkpoints[c.taskID] = list
        case .desktopStatus(let d):
            desktop = d
        case .memoryEntityUpserted(let e):
            upsert(&entities, e)
        case .memoryRelationUpserted:
            break
        case .preferenceUpserted(let p):
            upsert(&preferences, p)
        case .memoryForgotten(let kind, let id):
            if kind == "entity" { entities.removeAll { $0.id.rawValue == id } }
            if kind == "preference" { preferences.removeAll { $0.id.rawValue == id } }
        case .skillUpserted(let s):
            upsert(&skills, s)
        case .skillRemoved(let id):
            skills.removeAll { $0.id == id }
        case .scheduleUpserted(let job):
            upsert(&schedules, job)
        case .scheduleRemoved(let id):
            schedules.removeAll { $0.id == id }
        case .goalUpserted(let goal):
            upsert(&goals, goal)
        case .goalItemUpserted(let item):
            if var list = goalItems[item.goalID] {
                if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
                goalItems[item.goalID] = list
            }
        case .goalRemoved(let id):
            goals.removeAll { $0.id == id }
            goalItems[id] = nil
        case .mcpServerStatus(let s):
            upsert(&mcpServers, s)
        case .notice(let level, _, let text):
            notices.append(Notice(level: level, text: text, at: event.at))
            if notices.count > 200 { notices.removeFirst(notices.count - 200) }
        case .teachingUpdated(let session):
            teaching = session
        }
    }

    private func upsert<T: Identifiable>(_ list: inout [T], _ item: T) {
        if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
    }

    private func appendText(_ m: inout Message, _ delta: String, reasoning: Bool) {
        if let last = m.parts.indices.last {
            switch (m.parts[last], reasoning) {
            case (.text(let t), false): m.parts[last] = .text(t + delta); return
            case (.reasoning(let t), true): m.parts[last] = .reasoning(t + delta); return
            default: break
            }
        }
        m.parts.append(reasoning ? .reasoning(delta) : .text(delta))
    }
}
