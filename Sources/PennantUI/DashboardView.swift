import PennantClientKit
import PennantCore
import SwiftUI

/// Pennant at a glance: every instance working right now (its threads, and the helpers and coding runs they started),
/// what needs you, today's numbers, what runs next with the goals under it, and the latest reports. Live without
/// costing the Mac: spinners are the system's own and clocks are system-drawn timers, so nothing redraws per frame.
public struct DashboardView: View {
    @Environment(\.hostSession) private var session
    var onOpenChat: (AgentID, ConversationID?) -> Void
    var onOpenReports: () -> Void
    var onOpenApprovals: (() -> Void)?
    var onOpenGoals: (() -> Void)?
    /// Opens one goal; its rows fall back to the Goals list without it.
    var onOpenGoal: ((GoalID) -> Void)?
    @State private var reviewing: PendingApproval?
    /// Today's new tokens (cached input left out) and spend; `nil` until the host answers.
    @State private var usageToday: (tokens: Int, cost: Double)?
    @State private var appeared = false
    /// Two columns when there's room. Measured only when the width changes: ViewThatFits measured both layouts on
    /// every pass, recreating the clocks and countdowns inside them, which fired and asked for another pass.
    @State private var wide = true

    public init(onOpenChat: @escaping (AgentID, ConversationID?) -> Void, onOpenReports: @escaping () -> Void = {},
                onOpenApprovals: (() -> Void)? = nil, onOpenGoals: (() -> Void)? = nil, onOpenGoal: ((GoalID) -> Void)? = nil) {
        self.onOpenGoals = onOpenGoals
        self.onOpenGoal = onOpenGoal
        self.onOpenChat = onOpenChat
        self.onOpenReports = onOpenReports
        self.onOpenApprovals = onOpenApprovals
    }

    // MARK: Data

    private var activeTasks: [TaskRecord] { session.state.tasks.filter { !$0.state.isTerminal } }

    /// Everything running right now, one row per instance: each thread's task, and under it the helpers and Coder
    /// runs it started. Newest first.
    private var instances: [(task: TaskRecord, depth: Int)] {
        let active = activeTasks
        let ids = Set(active.map(\.id))
        func parent(_ t: TaskRecord) -> TaskID? { t.parentTaskID ?? t.requestedByTaskID }
        var out: [(task: TaskRecord, depth: Int)] = []
        func add(_ t: TaskRecord, _ depth: Int) {
            out.append((t, depth))
            for c in active.filter({ parent($0) == t.id }).sorted(by: { $0.createdAt < $1.createdAt }) where depth < 4 { add(c, depth + 1) }
        }
        for t in active.filter({ parent($0).map { !ids.contains($0) } ?? true }).sorted(by: { $0.createdAt > $1.createdAt }) { add(t, 0) }
        return out
    }

    /// Instances actually at it (not parked waiting on you or queued).
    private var running: Int { activeTasks.filter { [.running, .waitingForTool, .waitingForDesktop].contains($0.state) }.count }

    /// Questions waiting on a person (tasks stopped to ask, without an approval card).
    private var questions: [TaskRecord] {
        let approvalTasks = Set(session.state.pendingApprovals.map(\.request.taskID))
        return activeTasks.filter { $0.state == .waitingForUser && !approvalTasks.contains($0.id) && $0.parentTaskID == nil }
    }

    private var needsYouCount: Int { session.state.pendingApprovals.count + questions.count }

    private var finishedToday: [TaskRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return session.state.tasks.filter { $0.state == .completed && ($0.finishedAt ?? $0.updatedAt) >= start }
    }

    private var upcoming: [ScheduledJob] {
        session.state.schedules.filter { $0.enabled && $0.nextRunAt != nil }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
    }

    private var latestReports: [PostedReport] {
        session.state.reports.sorted { $0.report.createdAt > $1.report.createdAt }
    }

    // MARK: Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                needsYou
                if wide {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 28) {
                            workingNow
                            today
                            if !latestReports.isEmpty { reports }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 28) {
                            comingUp
                            if !activeGoals.isEmpty { goalsSection }
                        }
                        .frame(width: 320, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        workingNow
                        comingUp
                        if !activeGoals.isEmpty { goalsSection }
                        today
                        if !latestReports.isEmpty { reports }
                    }
                }
            }
            .padding(.horizontal, 24)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 780 } action: { wide = $0 }
            .padding(.bottom, 32)
        }
        .background(PennantTheme.windowBackground)
        .sheet(item: $reviewing) { p in
            VStack(spacing: 0) {
                // A way out without deciding: Close (or Esc) leaves the card waiting where it was.
                HStack(spacing: 10) {
                    Text("Waiting for your approval").font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
                    Spacer(minLength: 8)
                    Button("Open thread") { reviewing = nil; onOpenChat(p.agentID, p.conversationID) }
                        .buttonStyle(.pennantCompact)
                    Button("Close") { reviewing = nil }
                        .buttonStyle(.pennantCompact)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider().overlay(PennantTheme.divider)
                ScrollView { ApprovalCard(request: p.request, agentID: p.agentID) { reviewing = nil; onOpenChat(p.agentID, p.conversationID) }.padding(20) }
            }
            .frame(minWidth: 560, idealWidth: ApprovalCard.maxWidth + 40, minHeight: 420)
            .background(PennantTheme.windowBackground)
        }
        .onChange(of: session.state.pendingApprovals.map(\.id)) { _, ids in
            if let r = reviewing, !ids.contains(r.id) { reviewing = nil }
        }
        .task(id: session.connection.isConnected) {
            guard session.connection.isConnected else { return }
            try? await session.loadPendingApprovals()
            try? await session.loadReports()
            if session.state.schedules.isEmpty { try? await session.loadSchedules() }
            while !Task.isCancelled {
                await refreshUsage()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.05)) { appeared = true } }
    }

    private func refreshUsage() async {
        let start = Calendar.current.startOfDay(for: Date())
        guard let rows = try? await session.usageReport(from: start, to: Date()) else { return }
        withAnimation(.snappy) {
            usageToday = (rows.reduce(0) { $0 + max(0, $1.inputTokens - $1.cachedInputTokens) + $1.outputTokens }, rows.reduce(0) { $0 + $1.cost })
        }
    }

    // MARK: Header

    /// A slim band sized to its words: the greeting on the left, the live status on the right (below it on a phone).
    private var header: some View {
        Group {
            if wide {
                HStack(alignment: .center, spacing: 24) {
                    greetingBlock
                    Spacer(minLength: 0)
                    HStack(spacing: 18) { statusItems }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    greetingBlock
                    VStack(alignment: .leading, spacing: 4) { statusItems }
                }
            }
        }
        .font(.zoomed(.callout).weight(.medium))
        .foregroundStyle(PennantTheme.inkSecondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.brand.opacity(running > 0 ? 0.6 : 0.3), lineWidth: 1))
        .padding(.top, 16)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
    }

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.zoomed(.caption2).weight(.semibold)).tracking(1.1)
                .foregroundStyle(PennantTheme.inkTertiary)
            Text(greeting).font(.zoomed(size: 21, weight: .bold, design: .rounded)).foregroundStyle(PennantTheme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var statusItems: some View {
        HStack(spacing: 16) {
            runningLabel
            if needsYouCount > 0 { Text("\(needsYouCount) need\(needsYouCount == 1 ? "s" : "") you").foregroundStyle(PennantTheme.brandInk).contentTransition(.numericText()) }
        }
        .fixedSize()
        if let next = upcoming.first?.nextRunAt {
            TimelineView(.periodic(from: Clock.anchor, by: 30)) { _ in
                Label("Next run \(Self.countdown(to: next))", systemImage: "clock").labelStyle(.titleAndIcon)
            }
            .fixedSize()
        }
    }

    private var greeting: String {
        let name = session.state.me?.name.split(separator: " ").first.map(String.init) ?? ""
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? part : "\(part), \(name)"
    }

    /// "3 running" beside the system spinner, or "All quiet".
    private var runningLabel: some View {
        HStack(spacing: 7) {
            if running > 0 {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(PennantTheme.inkTertiary.opacity(0.6)).frame(width: 7, height: 7).frame(width: 14, height: 14)
            }
            Text(running > 0 ? "\(running) running" : "All quiet").contentTransition(.numericText())
        }
    }

    // MARK: Needs you

    @ViewBuilder private var needsYou: some View {
        if needsYouCount == 0 {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(PennantTheme.success)
                Text("All clear — nothing needs you right now.").foregroundStyle(PennantTheme.inkSecondary)
            }
            .font(.zoomed(.callout))
            .transition(.opacity)
        } else {
            section("Needs you", trailing: "\(needsYouCount)", action: onOpenApprovals.map { ("History", $0) }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(session.state.pendingApprovals) { p in
                            NeedsYouCard(agent: session.state.agent(p.agentID), kind: "Approval", title: p.request.title,
                                         detail: p.request.destination.isEmpty ? p.request.text : p.request.destination,
                                         since: p.request.createdAt, symbol: "checkmark.seal") { reviewing = p }
                                .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
                        }
                        ForEach(questions) { t in
                            // Stopped for an approval whose card hasn't loaded yet: say so, and open the conversation it's in.
                            let isApproval = t.stateReason.hasPrefix("Waiting for your approval")
                            NeedsYouCard(agent: session.state.agent(t.agentID), kind: isApproval ? "Approval" : "Question",
                                         title: Self.needsYouTitle(t, isApproval: isApproval),
                                         detail: t.title, since: t.updatedAt, symbol: isApproval ? "checkmark.seal" : "questionmark.bubble") { onOpenChat(t.agentID, t.conversationID) }
                                .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: session.state.pendingApprovals.map(\.id) + questions.map(\.id.rawValue))
                }
            }
        }
    }

    // MARK: Working now

    private var workingNow: some View {
        let rows = instances
        return section("Working now", trailing: rows.isEmpty ? nil : "\(rows.count)") {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz").foregroundStyle(PennantTheme.inkTertiary)
                        Text(idleLine).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    .font(.zoomed(.callout))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                ForEach(Array(rows.enumerated()), id: \.element.task.id) { i, row in
                    if i > 0 { Divider().padding(.leading, 44 + CGFloat(row.depth) * 22) }
                    InstanceRow(task: row.task, depth: row.depth) { open(row.task) }
                }
            }
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.border))
            .animation(.snappy, value: rows.map(\.task.id))
        }
    }

    private var idleLine: String {
        let who = session.state.leadAgent?.name ?? "Pennant"
        guard let next = upcoming.first, let at = next.nextRunAt else { return "\(who) is idle." }
        return "\(who) is idle. Next: \(next.name) \(Self.countdown(to: at))."
    }

    /// A helper's or Coder's run opens the thread that started it, where its result lands.
    private func open(_ task: TaskRecord) {
        var t = task
        while let up = t.parentTaskID ?? t.requestedByTaskID, let p = session.state.task(up) { t = p }
        onOpenChat(t.agentID, t.conversationID)
    }

    // MARK: Today

    private var today: some View {
        section("Today") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StatTile(value: "\(finishedToday.count)", label: "tasks done", symbol: "checkmark.circle")
                    StatTile(value: usageToday.map { Self.tokens($0.tokens) } ?? "—", label: "new tokens", symbol: "text.word.spacing")
                    StatTile(value: usageToday.map { $0.cost.formatted(.currency(code: "USD").precision(.fractionLength(2))) } ?? "—", label: "spent", symbol: "creditcard")
                }
                ActivitySparkline(values: hourly)
                    .frame(height: 54)
                    .accessibilityLabel("Tasks finished per hour today")
            }
            .padding(16)
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.border))
        }
    }

    /// Tasks finished in each hour so far today.
    private var hourly: [Double] {
        let cal = Calendar.current
        let now = cal.component(.hour, from: Date())
        var buckets = Array(repeating: 0.0, count: max(now + 1, 8))
        for t in finishedToday {
            let h = cal.component(.hour, from: t.finishedAt ?? t.updatedAt)
            if h < buckets.count { buckets[h] += 1 }
        }
        return buckets
    }

    // MARK: Coming up

    // MARK: Goals

    private var activeGoals: [Goal] { session.state.goals.filter { $0.status == .active || $0.status == .proposed }.sorted { $0.title < $1.title } }

    /// What Pennant works toward on its own: a compact list under Coming up.
    private var goalsSection: some View {
        let waiting = activeGoals.reduce(0) { n, g in n + (session.state.goalItems[g.id] ?? []).filter { $0.state == .waiting }.count }
        return section("Goals", trailing: waiting > 0 ? "\(waiting) waiting on you" : nil, action: onOpenGoals.map { ("All", $0) }) {
            VStack(spacing: 0) {
                ForEach(Array(activeGoals.prefix(6).enumerated()), id: \.element.id) { i, goal in
                    if i > 0 { Divider().padding(.leading, 44) }
                    Button { if let onOpenGoal { onOpenGoal(goal.id) } else { onOpenGoals?() } } label: { CompactGoalRow(goal: goal) }.buttonStyle(.plain)
                }
            }
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.border))
        }
        .task { try? await session.loadGoals() }
    }

    private var comingUp: some View {
        section("Coming up") {
            VStack(spacing: 0) {
                if upcoming.isEmpty {
                    Text("Nothing scheduled.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkTertiary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                ForEach(Array(upcoming.prefix(5).enumerated()), id: \.element.id) { i, job in
                    if i > 0 { Divider().padding(.leading, 44) }
                    HStack(spacing: 10) {
                        Image(systemName: job.goalID != nil ? ThreadMark.goalSymbol : "clock")
                            .font(.zoomed(size: 12, weight: .medium))
                            .foregroundStyle(PennantTheme.inkSecondary)
                            .frame(width: 22, height: 22)
                            .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(scheduleLabel(job.name)).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        if let next = job.nextRunAt {
                            TimelineView(.periodic(from: Clock.anchor, by: 30)) { _ in
                                Text(Self.countdown(to: next)).font(.zoomed(.caption).weight(.semibold).monospacedDigit()).foregroundStyle(PennantTheme.brandInk)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(PennantTheme.brandSoft, in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.border))
        }
    }

    // MARK: Reports

    private var reports: some View {
        section("Latest reports", action: ("All reports", onOpenReports)) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 14)], spacing: 14) {
                ForEach(latestReports.prefix(3)) { r in
                    ReportTile(posted: r, agent: session.state.agent(r.agentID)) { onOpenChat(r.agentID, r.conversationID) }
                }
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, trailing: String? = nil, action: (String, () -> Void)? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                if let trailing {
                    Text(trailing).font(.zoomed(.callout).weight(.medium).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).contentTransition(.numericText())
                }
                Spacer()
                if let action { Button(action.0, action: action.1).buttonStyle(.plain).font(.zoomed(.callout)).foregroundStyle(PennantTheme.brandInk) }
            }
            content()
        }
    }

    /// What a waiting task is stopped on: the approval's subject, the question, or the task itself.
    static func needsYouTitle(_ t: TaskRecord, isApproval: Bool) -> String {
        let reason = isApproval ? String(t.stateReason.dropFirst("Waiting for your approval".count)).trimmingCharacters(in: CharacterSet(charactersIn: ": ")) : t.stateReason
        return reason.isEmpty ? t.title : reason
    }

    static func countdown(to date: Date) -> String {
        let s = date.timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "in \(Int(s / 60)) min" }
        if s < 86400 { let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60); return m == 0 ? "in \(h) h" : "in \(h) h \(m) m" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

// MARK: - Pieces

/// One instance at work: the system spinner (or what it's waiting on), the thread, who's doing it and what it's on,
/// and a clock the system keeps running. Helpers and coding runs sit indented under the thread that started them.
struct InstanceRow: View {
    @Environment(\.hostSession) private var session
    var task: TaskRecord
    var depth: Int
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                indicator.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.zoomed(.callout).weight(depth == 0 ? .medium : .regular)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(who).font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                        Text(doing).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // A fixed box: each tick redraws this text only, instead of re-laying out the whole dashboard
                // (three clocks a second apart meant three full layouts a second).
                Text(task.usage.startedAt ?? task.createdAt, style: .timer)
                    .font(.zoomed(.caption).monospacedDigit())
                    .foregroundStyle(PennantTheme.inkTertiary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.vertical, 9)
            .padding(.trailing, 14)
            .padding(.leading, 12 + CGFloat(depth) * 22)
            .background(hovering ? PennantTheme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var indicator: some View {
        switch task.state {
        case .waitingForUser:
            Image(systemName: "hand.raised.fill").font(.zoomed(size: 11)).foregroundStyle(PennantTheme.brand)
                .frame(width: 20, height: 20).background(PennantTheme.brandSoft, in: Circle())
        case .paused:
            Image(systemName: "pause.circle").foregroundStyle(PennantTheme.inkTertiary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(PennantTheme.inkTertiary)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private var title: String {
        if let c = session.state.conversation(task.conversationID), depth == 0 { return conversationLabel(c) }
        return scheduleLabel(task.title)
    }

    private var who: String {
        guard let a = session.state.agent(task.agentID) else { return "Helper" }
        return a.kind == .worker ? "Helper" : a.name
    }

    private var doing: String {
        switch task.state {
        case .waitingForUser: return "waiting for you"
        case .queued: return "queued"
        case .paused: return "paused"
        default: return task.stateReason.isEmpty ? "working" : task.stateReason.prefix(1).lowercased() + task.stateReason.dropFirst()
        }
    }
}

/// A goal in the side column: its name, what's open, and when it works next.
struct CompactGoalRow: View {
    @Environment(\.hostSession) private var session
    var goal: Goal
    @State private var hovering = false

    var body: some View {
        let items = session.state.goalItems[goal.id] ?? []
        let open = items.filter { $0.state == .next || $0.state == .doing }.count
        let waiting = items.filter { $0.state == .waiting }.count
        let session_ = session.state.tasks.filter { $0.conversationID == goal.conversationID && !$0.state.isTerminal }
        let working = session_.contains { [.running, .waitingForTool, .waitingForDesktop].contains($0.state) }
        let waitingOnYou = session_.contains { $0.state == .waitingForUser }
        HStack(spacing: 10) {
            Image(systemName: ThreadMark.goalSymbol)
                .font(.zoomed(size: 12, weight: .medium))
                .foregroundStyle(PennantTheme.brandInk)
                .frame(width: 22, height: 22)
                .background(PennantTheme.brandSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                Text(detail(open: open, waiting: waiting)).font(.zoomed(.caption)).foregroundStyle(waiting > 0 ? PennantTheme.warning : PennantTheme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if working {
                ProgressView().controlSize(.small)
            } else if waitingOnYou {
                Image(systemName: "hand.raised.fill").font(.zoomed(size: 10)).foregroundStyle(PennantTheme.brand).help("Waiting for you")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? PennantTheme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: goal.id) { if session.state.goalItems[goal.id] == nil { try? await session.loadGoalItems(goal.id) } }
    }

    private func detail(open: Int, waiting: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if open > 0 { parts.append("\(open) open") }
        if goal.status == .proposed { parts.append("proposed") }
        else if let next = session.state.schedules.first(where: { $0.goalID == goal.id && $0.goalRun == "work" })?.nextRunAt {
            parts.append("next \(DashboardView.countdown(to: next))")
        }
        return parts.isEmpty ? "No work queued" : parts.joined(separator: " · ")
    }
}

/// Something waiting on you: who, what, since when. Tap to deal with it.
struct NeedsYouCard: View {
    var agent: AgentProfile?
    var kind: String
    var title: String
    var detail: String
    var since: Date
    var symbol: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let agent { AgentAvatar(agent: agent, size: 22) }
                    Text(agent?.name ?? "Agent").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                    Spacer(minLength: 4)
                    Label(kind, systemImage: symbol).font(.zoomed(.caption2).weight(.semibold)).foregroundStyle(PennantTheme.brandInk)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(PennantTheme.brandSoft, in: Capsule())
                }
                Text(title).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).lineLimit(2).multilineTextAlignment(.leading)
                Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack {
                    Text(relativeTime(since)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
                    Spacer()
                    Text(kind == "Approval" ? "Review" : "Answer").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.brandInk)
                    Image(systemName: "arrow.right").font(.zoomed(.caption2).weight(.bold)).foregroundStyle(PennantTheme.brandInk)
                }
            }
            .padding(14)
            .frame(width: 260, height: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous)
                    .fill(PennantTheme.cardElevated)
                    .shadow(color: PennantTheme.brand.opacity(hovering ? 0.22 : 0.10), radius: hovering ? 14 : 8, y: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.brand.opacity(0.35)))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }
}

/// A number that rolls when it changes, with a small label.
struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.zoomed(size: 12, weight: .semibold)).foregroundStyle(PennantTheme.brandInk)
            Text(value).font(.zoomed(size: 24, weight: .bold, design: .rounded)).foregroundStyle(PennantTheme.ink)
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Activity through the day as a soft area line, drawn in once; a dot marks the current hour.
struct ActivitySparkline: View {
    var values: [Double]
    @State private var drawn: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: values.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0,
                        y: geo.size.height - 4 - (geo.size.height - 10) * CGFloat(v / maxV))
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for pt in points { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [PennantTheme.brand.opacity(0.28), PennantTheme.brand.opacity(0)], startPoint: .top, endPoint: .bottom))
                .opacity(Double(drawn))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .trim(from: 0, to: drawn)
                .stroke(PennantTheme.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(PennantTheme.brand).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(PennantTheme.cardElevated, lineWidth: 2))
                        .position(last)
                }
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.2)) { drawn = 1 } }
    }
}

/// A report at a glance: its status as a coloured edge, the verdict, who and when.
struct ReportTile: View {
    var posted: PostedReport
    var agent: AgentProfile?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4).padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let agent { AgentAvatar(agent: agent, size: 18) }
                        Text(agent?.name ?? "").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                        Spacer()
                        Text(relativeTime(posted.report.createdAt)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    Text(posted.report.title).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    Text(posted.report.verdict).font(.zoomed(.caption)).foregroundStyle(color).lineLimit(2)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.border))
        }
        .buttonStyle(.plain)
    }
    private var color: Color {
        switch posted.report.status {
        case .good: return PennantTheme.success
        case .watch: return PennantTheme.warning
        case .bad: return PennantTheme.danger
        case .neutral: return PennantTheme.inkSecondary
        }
    }
}
