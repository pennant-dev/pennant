import PennantClientKit
import PennantCore
import SwiftUI

/// Goals: what each agent is working toward on its own, and the board it keeps for it. The owner can pause or resume
/// a goal, move or drop any item, and comment (the agent reads comments first at its next session).
public struct GoalsView: View {
    @Environment(\.hostSession) private var session
    var onOpenConversation: (AgentID, ConversationID) -> Void
    /// A goal to open (the dashboard's goal rows); cleared once it's open.
    @Binding var open: GoalID?
    @State private var selected: GoalID?
    @State private var creating: Goal?
    @State private var editing: Goal?
    @State private var deleting: Goal?
    @State private var error: String?

    public init(open: Binding<GoalID?> = .constant(nil), onOpenConversation: @escaping (AgentID, ConversationID) -> Void = { _, _ in }) {
        _open = open
        self.onOpenConversation = onOpenConversation
    }

    private var goals: [Goal] {
        let order: [Goal.Status] = [.active, .proposed, .paused, .achieved, .dropped]
        return session.state.goals.sorted { (order.firstIndex(of: $0.status) ?? 9, $0.title) < (order.firstIndex(of: $1.status) ?? 9, $1.title) }
    }

    public var body: some View {
        Group {
            if let id = selected, let goal = session.state.goals.first(where: { $0.id == id }) {
                GoalDetail(goal: goal, onBack: { selected = nil }, onOpenConversation: onOpenConversation)
            } else if goals.isEmpty {
                EmptyState(title: "No goals yet", message: "A goal is something Pennant works toward on its own, on a schedule, keeping its own to-do board and reporting every week. Add one, or ask Pennant to propose one.") {
                    Button("New goal") { startNew() }.buttonStyle(.pennantPrimary)
                }
            } else {
                ScrollView {
                    HStack {
                        Spacer()
                        Button { startNew() } label: { Label("New goal", systemImage: "plus") }
                            .buttonStyle(.pennantPrimaryCompact)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).padding(.horizontal, 16) }
                    LazyVStack(spacing: 10) {
                        ForEach(goals) { goal in
                            let menu = GoalMenuItems(goal: goal, onStatus: { setStatus(goal, $0) }, onEdit: { editing = goal }, onDelete: { deleting = goal })
                            ZStack(alignment: .topTrailing) {
                                Button { selected = goal.id } label: { GoalCard(goal: goal) }.buttonStyle(.plain)
                                GoalMenuButton(items: menu).padding(10)
                            }
                            .contextMenu { menu }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(PennantTheme.panelBackground)
        .task { try? await session.loadGoals() }
        .onChange(of: open, initial: true) { _, id in
            guard let id else { return }
            selected = id
            open = nil
        }
        .sheet(item: $creating) { GoalEditSheet(goal: $0, isNew: true) }
        .goalActions(editing: $editing, deleting: $deleting, onError: { error = $0 })
    }

    private func setStatus(_ goal: Goal, _ status: Goal.Status) {
        Task {
            do { try await session.setGoalStatus(goal.id, status); error = nil } catch { self.error = HostSessionError.message(error) }
        }
    }

    /// A blank goal for the agent you talk to, active as soon as it's saved (you made it; nothing to approve).
    private func startNew() {
        guard let lead = session.state.leadAgent else { return }
        creating = Goal(title: "", outcome: "", ownerAgentID: lead.id, status: .active)
    }
}

/// A goal in the list: who works on it, its outcome, and the shape of its board.
struct GoalCard: View {
    @Environment(\.hostSession) private var session
    var goal: Goal

    var body: some View {
        let items = session.state.goalItems[goal.id] ?? []
        HStack(alignment: .top, spacing: 12) {
            if let agent = session.state.agent(goal.ownerAgentID) { AgentAvatar(agent: agent, size: 34) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(goal.title).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    GoalStatusChip(status: goal.status)
                    Spacer(minLength: 28)
                }
                Text(goal.outcome).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2)
                HStack(spacing: 12) {
                    if let agent = session.state.agent(goal.ownerAgentID) { Text(agent.name).font(.zoomed(.caption).weight(.medium)).foregroundStyle(PennantTheme.inkSecondary) }
                    if !items.isEmpty {
                        GoalCount(symbol: "arrow.right.circle", count: items.filter { $0.state == .next || $0.state == .doing }.count, label: "open")
                        GoalCount(symbol: "hand.raised", count: items.filter { $0.state == .waiting }.count, label: "waiting on you")
                        GoalCount(symbol: "checkmark.circle", count: items.filter { $0.state == .done }.count, label: "done")
                    }
                    if let next = session.state.schedules.first(where: { $0.goalID == goal.id && $0.goalRun == "work" })?.nextRunAt, goal.status == .active {
                        Text("Next session \(next.formatted(.relative(presentation: .named)))").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: goal.id) { if session.state.goalItems[goal.id] == nil { try? await session.loadGoalItems(goal.id) } }
    }
}

struct GoalCount: View {
    var symbol: String
    var count: Int
    var label: String
    var body: some View {
        if count > 0 {
            Label("\(count) \(label)", systemImage: symbol).font(.zoomed(.caption)).foregroundStyle(label.hasPrefix("waiting") ? PennantTheme.warning : PennantTheme.inkSecondary)
        }
    }
}

struct GoalStatusChip: View {
    var status: Goal.Status
    /// Drawn as the label of the menu that changes it.
    var opensMenu = false
    var body: some View {
        let color: Color = {
            switch status {
            case .active, .achieved: return PennantTheme.success
            case .proposed: return PennantTheme.warning
            case .paused, .dropped: return PennantTheme.inkTertiary
            }
        }()
        HStack(spacing: 3) {
            Text(status.title)
            if opensMenu { Image(systemName: "chevron.down").font(.zoomed(size: 7, weight: .bold)) }
        }
        .font(.zoomed(.caption2).weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

/// One goal: its outcome and settings, and its board.
struct GoalDetail: View {
    @Environment(\.hostSession) private var session
    var goal: Goal
    var onBack: () -> Void
    var onOpenConversation: (AgentID, ConversationID) -> Void
    @State private var commenting: GoalItem?
    @State private var editing: Goal?
    @State private var deleting: Goal?
    @State private var error: String?

    private var items: [GoalItem] { session.state.goalItems[goal.id] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach([GoalItem.State.waiting, .doing, .next, .idea, .done], id: \.self) { state in
                    let column = items.filter { $0.state == state }.sorted { state == .done ? $0.updatedAt > $1.updatedAt : $0.rank < $1.rank }
                    if !column.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("\(state.title) · \(column.count)")
                            ForEach(state == .done ? Array(column.prefix(10)) : column) { item in
                                GoalItemRow(item: item, onMove: { move(item, to: $0) }, onComment: { commenting = item })
                            }
                        }
                    }
                }
                if items.isEmpty {
                    Text(goal.status == .active ? "The board fills in at the first work session." : "No items yet.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                }
                if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
            }
            .padding(16)
        }
        .task(id: goal.id) { try? await session.loadGoalItems(goal.id) }
        .sheet(item: $commenting) { item in GoalCommentSheet(item: item) }
        .goalActions(editing: $editing, deleting: $deleting, onDeleted: onBack, onError: { error = $0 })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) { Label("Goals", systemImage: "chevron.left").font(.zoomed(.callout)) }.buttonStyle(.plain).foregroundStyle(PennantTheme.inkSecondary)
            HStack(spacing: 10) {
                if let agent = session.state.agent(goal.ownerAgentID) { AgentAvatar(agent: agent, size: 38) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(goal.title).font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        Menu {
                            ForEach(Goal.Status.menuOrder.filter { $0 != goal.status }, id: \.self) { status in
                                Button(status.move(from: goal.status)) { setStatus(status) }
                            }
                        } label: {
                            GoalStatusChip(status: goal.status, opensMenu: true)
                        }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                        .help("Change its status")
                        .accessibilityLabel("Status: \(goal.status.title)")
                    }
                    Text(session.state.agent(goal.ownerAgentID)?.name ?? "").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            Text(goal.outcome).font(.zoomed(.body)).foregroundStyle(PennantTheme.ink)
            VStack(alignment: .leading, spacing: 4) {
                if !goal.measure.isEmpty { fact("How we'll know", goal.measure) }
                fact("Freedom", goal.freedom.title)
                if !goal.limits.isEmpty { fact("Limits", goal.limits) }
                fact("Works", SchedulePhrasing.summary(for: goal.workSchedule, timeZone: TimeZone.current.identifier).text)
                fact("Reviews", SchedulePhrasing.summary(for: goal.reviewSchedule, timeZone: TimeZone.current.identifier).text)
                if let budget = goal.weeklyBudget { fact("Budget", String(format: "$%.0f a week", budget)) }
            }
            if goal.status == .proposed {
                Text("Proposed: start it here, or approve its card.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.warning)
            }
            HStack(spacing: 8) {
                if goal.status == .active {
                    Button(Goal.Status.paused.move(from: goal.status)) { setStatus(.paused) }.buttonStyle(.pennantCompact)
                } else {
                    Button(Goal.Status.active.move(from: goal.status)) { setStatus(.active) }.buttonStyle(.pennantPrimaryCompact)
                }
                Button("Edit") { editing = goal }.buttonStyle(.pennantCompact)
                if let conversation = goal.conversationID {
                    Button("Open its conversation") { onOpenConversation(goal.ownerAgentID, conversation) }.buttonStyle(.pennantCompact)
                }
                Spacer(minLength: 0)
                Button("Delete…", role: .destructive) { deleting = goal }.buttonStyle(.pennantGhostCompact)
            }
        }
        .padding(14)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.zoomed(.caption).weight(.medium)).foregroundStyle(PennantTheme.inkTertiary).frame(width: 96, alignment: .leading)
            Text(value).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
        }
    }

    private func setStatus(_ status: Goal.Status) {
        Task {
            do { try await session.setGoalStatus(goal.id, status); error = nil } catch { self.error = HostSessionError.message(error) }
        }
    }

    private func move(_ item: GoalItem, to state: GoalItem.State) {
        var moved = item
        moved.state = state
        moved.rank = (items.filter { $0.state == state }.map(\.rank).min() ?? 0) - 1
        moved.notes.append(GoalItem.Note(text: "Moved to \(state.title).", by: "owner"))
        Task {
            do { try await session.saveGoalItem(moved); error = nil } catch { self.error = HostSessionError.message(error) }
        }
    }
}

struct GoalItemRow: View {
    var item: GoalItem
    var onMove: (GoalItem.State) -> Void
    var onComment: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(item.state == .done ? PennantTheme.inkSecondary : PennantTheme.ink)
                if !item.detail.isEmpty { Text(item.detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(3) }
                if let note = item.notes.last {
                    Text("\(note.by == "owner" ? "You" : note.by): \(note.text)").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(GoalItem.State.allCases.filter { $0 != item.state }) { state in
                    Button(state == .dropped ? "Drop" : "Move to \(state.title)") { onMove(state) }
                }
                Divider()
                Button("Comment…", action: onComment)
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(PennantTheme.inkSecondary)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
        }
        .padding(12)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            ForEach(GoalItem.State.allCases.filter { $0 != item.state }) { state in
                Button(state == .dropped ? "Drop" : "Move to \(state.title)") { onMove(state) }
            }
            Button("Comment…", action: onComment)
        }
    }
}

/// A comment on an item; the agent reads it first at its next session.
struct GoalCommentSheet: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    var item: GoalItem
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.zoomed(.headline))
            Text("The agent reads this first at its next session.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            PennantTextField("Comment", placeholder: "Focus on this next; the numbers are in the Q3 deck", text: $text, lines: 2 ... 6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost)
                Button(busy ? "Saving…" : "Comment") {
                    busy = true
                    Task {
                        _ = try? await session.commentGoalItem(item.id, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                        busy = false
                        dismiss()
                    }
                }
                .buttonStyle(.pennantPrimaryCompact)
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }
}

/// The owner's edit of a goal: what it aims at, what its agent may do, when it works and reviews, its budget.
struct GoalEditSheet: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State var goal: Goal
    var isNew = false
    @State private var budget: String
    @State private var busy = false
    @State private var error: String?

    init(goal: Goal, isNew: Bool = false) {
        _goal = State(initialValue: goal)
        self.isNew = isNew
        _budget = State(initialValue: goal.weeklyBudget.map { String(format: "%.0f", $0) } ?? "")
    }

    /// The newest version of each skill, by name: what a goal can follow.
    private var skillChoices: [Skill] {
        var latest: [String: Skill] = [:]
        for s in session.state.skills where s.status != .disabled {
            if let cur = latest[s.name], cur.version >= s.version { continue }
            latest[s.name] = s
        }
        return latest.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The pinned skill by name, so a newer version of the same skill still reads as chosen.
    private var skillName: Binding<String> {
        Binding(get: { goal.skillID.flatMap { id in session.state.skills.first { $0.id == id }?.name } ?? "" },
                set: { name in goal.skillID = name.isEmpty ? nil : skillChoices.first { $0.name == name }?.id })
    }

    static let workChoices = ["daily at 09:00", "weekdays at 09:00", "every 4h", "daily at 07:00"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(isNew ? "New goal" : "Edit goal").font(.zoomed(.title3).weight(.semibold))
                PennantTextField("Title", placeholder: "Grow the LinkedIn page", text: $goal.title)
                PennantTextField("Outcome", placeholder: "What success looks like", text: $goal.outcome, lines: 2 ... 5)
                PennantTextField("How we'll know", placeholder: "The number to watch and where it comes from", text: $goal.measure, lines: 1 ... 3)
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Freedom")
                    ChipRow(selection: $goal.freedom, options: Goal.Freedom.allCases.map { ChoiceOption($0, title: $0.title) })
                }
                PennantTextField("Limits", placeholder: "What it must never do", text: $goal.limits, lines: 1 ... 4)
                if !isNew {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Status")
                        ChipRow(selection: $goal.status, options: Goal.Status.menuOrder.map { ChoiceOption($0, title: $0.title) })
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Follows skill")
                    Picker("Follows skill", selection: skillName) {
                        Text("None: Pennant finds its own way").tag("")
                        ForEach(skillChoices) { s in Text(s.name).tag(s.name) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Works")
                    ChipRow(selection: $goal.workSchedule, options: Array(Set(Self.workChoices + [goal.workSchedule])).sorted().map { ChoiceOption($0, title: SchedulePhrasing.summary(for: $0, timeZone: TimeZone.current.identifier).text) })
                    PennantTextField("", placeholder: "Or any schedule: every 2h, weekly on mon,thu at 18:00…", text: $goal.workSchedule)
                }
                PennantTextField("Reviews", placeholder: "weekly on fri at 16:00", text: $goal.reviewSchedule)
                PennantTextField("Weekly budget (US$)", placeholder: "No cap", text: $budget)
                if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost)
                    Button(busy ? "Saving…" : (isNew ? "Start goal" : "Save")) { save() }.buttonStyle(.pennantPrimaryCompact).disabled(busy || goal.title.isEmpty || goal.outcome.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 520)
        .task { if session.state.skills.isEmpty { try? await session.loadSkills() } }
    }

    private func save() {
        busy = true
        var edited = goal
        let trimmed = budget.trimmingCharacters(in: .whitespaces)
        edited.weeklyBudget = trimmed.isEmpty ? nil : Double(trimmed)
        Task {
            defer { busy = false }
            do {
                try await session.saveGoal(edited)
                dismiss()
            } catch { self.error = HostSessionError.message(error) }
        }
    }
}

extension Goal.Status {
    /// The status as the Goals page names it.
    var title: String {
        switch self {
        case .active: return "Working"
        case .proposed: return "Proposed"
        case .paused: return "Paused"
        case .achieved: return "Achieved"
        case .dropped: return "Dropped"
        }
    }

    /// The order the owner's menus offer them in.
    static let menuOrder: [Goal.Status] = [.active, .paused, .achieved, .proposed, .dropped]

    /// What moving a goal from `current` to this status is called.
    func move(from current: Goal.Status) -> String {
        switch self {
        case .active: return current == .proposed ? "Start working" : current == .paused ? "Resume" : "Work on it again"
        case .proposed: return "Back to proposed"
        case .paused: return "Pause"
        case .achieved: return "Mark achieved"
        case .dropped: return "Drop"
        }
    }
}

/// What the owner can do with a goal, wherever it shows: edit it, move it to any other status, delete it.
struct GoalMenuItems: View {
    var goal: Goal
    var onStatus: (Goal.Status) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button("Edit…", action: onEdit)
        Divider()
        ForEach(Goal.Status.menuOrder.filter { $0 != goal.status }, id: \.self) { status in
            Button(status.move(from: goal.status)) { onStatus(status) }
        }
        Divider()
        Button("Delete goal…", role: .destructive, action: onDelete)
    }
}

/// The ⋯ that opens a goal's menu.
struct GoalMenuButton: View {
    var items: GoalMenuItems

    var body: some View {
        Menu { items } label: {
            Image(systemName: "ellipsis.circle").font(.zoomed(.body)).foregroundStyle(PennantTheme.inkSecondary)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .help("Edit, change its status, or delete")
        .accessibilityLabel("Goal actions")
    }
}

extension View {
    /// The edit sheet and the delete confirmation behind a goal's menu.
    func goalActions(editing: Binding<Goal?>, deleting: Binding<Goal?>, onDeleted: @escaping () -> Void = {}, onError: @escaping (String?) -> Void) -> some View {
        modifier(GoalActions(editing: editing, deleting: deleting, onDeleted: onDeleted, onError: onError))
    }
}

private struct GoalActions: ViewModifier {
    @Environment(\.hostSession) private var session
    @Binding var editing: Goal?
    @Binding var deleting: Goal?
    var onDeleted: () -> Void
    var onError: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) { GoalEditSheet(goal: $0) }
            .confirmationDialog("Delete \u{201C}\(deleting?.title ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { goal in
                Button("Delete goal", role: .destructive) { delete(goal) }
            } message: { _ in
                Text("Its board and its jobs go with it; its conversation stays in your threads. To keep a record, drop it instead.")
            }
    }

    private func delete(_ goal: Goal) {
        Task {
            do {
                try await session.deleteGoal(goal.id)
                onError(nil)
                onDeleted()
            } catch { onError(HostSessionError.message(error)) }
        }
    }
}
