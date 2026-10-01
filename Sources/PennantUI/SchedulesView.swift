import PennantClientKit
import PennantCore
import SwiftUI

/// Recurring and one-off jobs the host runs on its own clock.
public struct SchedulesView: View {
    @Environment(\.hostSession) private var session
    var onOpenConversation: (AgentID, ConversationID) -> Void
    @State private var editing: ScheduledJob?
    @State private var creating = false
    @State private var confirmDelete: ScheduledJob?
    @State private var error: String?
    @State private var busy: Set<ScheduleID> = []

    public init(onOpenConversation: @escaping (AgentID, ConversationID) -> Void = { _, _ in }) {
        self.onOpenConversation = onOpenConversation
    }

    private var jobs: [ScheduledJob] {
        session.state.schedules.sorted { ($0.nextRunAt ?? .distantFuture, $0.name) < ($1.nextRunAt ?? .distantFuture, $1.name) }
    }

    private var canCreate: Bool { session.connection.isConnected && !session.state.persistentAgents.isEmpty }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(jobs.count) job\(jobs.count == 1 ? "" : "s")").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                Spacer()
                Button { creating = true } label: { Label("New job", systemImage: "plus") }
                    .buttonStyle(.pennantPrimaryCompact)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            if jobs.isEmpty {
                EmptyState(title: "No routines yet", message: "Ask an agent to run a skill or a prompt on a schedule: every morning, on weekdays, or just once.") {
                    Button("New job") { creating = true }.buttonStyle(.pennantPrimary).disabled(!canCreate)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(jobs) { job in
                            ScheduleCard(job: job, busy: busy.contains(job.id),
                                         onToggle: { setEnabled(job, !job.enabled) },
                                         onRunNow: { runNow(job) },
                                         onEdit: { editing = job },
                                         onDelete: { confirmDelete = job },
                                         onOpen: { if let c = job.conversationID { onOpenConversation(job.agentID, c) } })
                        }
                    }
                    .padding(16)
                }
            }
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(ScheduleTone.danger).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .background(PennantTheme.panelBackground)
        .task { try? await session.loadSchedules() }
        .sheet(isPresented: $creating) { ScheduleEditor(job: nil) }
        .sheet(item: $editing) { job in ScheduleEditor(job: job) }
        .confirmationDialog("Delete this job?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { job in
            Button("Delete \"\(scheduleLabel(job.name))\"", role: .destructive) { delete(job) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Past runs and their conversations are kept.") }
    }

    private func setEnabled(_ job: ScheduledJob, _ enabled: Bool) {
        var j = job
        j.enabled = enabled
        j.updatedAt = Date()
        run(job.id) { _ = try await session.upsertSchedule(j) }
    }

    private func runNow(_ job: ScheduledJob) { run(job.id) { _ = try await session.runScheduleNow(job.id) } }
    private func delete(_ job: ScheduledJob) { run(job.id) { try await session.deleteSchedule(job.id) } }

    private func run(_ id: ScheduleID, _ op: @escaping () async throws -> Void) {
        busy.insert(id)
        error = nil
        Task {
            defer { busy.remove(id) }
            do { try await op() } catch { self.error = String(describing: error) }
        }
    }
}

/// Status colours for jobs, taken from the theme's task-state palette (the foundation has no standalone danger/success tokens).
enum ScheduleTone {
    static let danger = PennantTheme.color(for: TaskState.failed)
    static let success = PennantTheme.color(for: TaskState.completed)
    static let accent = PennantTheme.color(for: TaskState.running)

    enum Outcome { case ok, failed, skipped, unknown }

    static func outcome(_ text: String?) -> Outcome {
        guard let o = text?.lowercased(), !o.isEmpty else { return .unknown }
        if o.contains("fail") || o.contains("error") { return .failed }
        if o.contains("cancel") || o.contains("skip") { return .skipped }
        if o.contains("complet") || o.contains("succe") || o.contains("ok") || o.contains("done") { return .ok }
        return .unknown
    }

    static func color(for outcome: Outcome) -> Color {
        switch outcome {
        case .ok: return success
        case .failed: return danger
        case .skipped, .unknown: return PennantTheme.inkTertiary
        }
    }
}

/// One job as a white card: glyph, name, friendly schedule, who runs it, when next, and compact actions.
struct ScheduleCard: View {
    @Environment(\.hostSession) private var session
    var job: ScheduledJob
    var busy: Bool
    var onToggle: () -> Void
    var onRunNow: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onOpen: () -> Void

    private var summary: SchedulePhrasing.Summary { SchedulePhrasing.summary(for: job.schedule, timeZone: job.timeZone) }
    private var agent: AgentProfile? { session.state.agent(job.agentID) }
    private var skill: Skill? { job.skillID.flatMap { id in session.state.skills.first { $0.id == id } } }

    private var glyph: (symbol: String, color: Color) {
        guard job.enabled else { return ("pause.fill", PennantTheme.inkTertiary) }
        switch ScheduleTone.outcome(job.lastOutcome) {
        case .failed: return ("exclamationmark", ScheduleTone.danger)
        case .ok: return ("checkmark", ScheduleTone.success)
        case .skipped, .unknown: return ("clock", ScheduleTone.accent)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(glyph.color.opacity(0.14))
                Image(systemName: glyph.symbol).font(.zoomed(size: 14, weight: .semibold)).foregroundStyle(glyph.color)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(scheduleLabel(job.name)).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    if !job.enabled { Chip("Paused") }
                    if let skill { Chip(skill.name, color: ScheduleTone.accent) }
                }
                HStack(spacing: 6) {
                    Text(summary.text)
                        .font(summary.isCron ? .zoomed(.callout).monospaced() : .zoomed(.callout))
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .lineLimit(1)
                    if summary.isCron { Chip("cron") }
                    if job.timeZone != TimeZone.current.identifier {
                        Text(job.timeZone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? job.timeZone)
                            .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    }
                }
                HStack(spacing: 6) {
                    if let agent {
                        AgentAvatar(agent: agent, size: 16)
                        Text(agent.name).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    } else {
                        Circle().fill(PennantTheme.fieldBackground).frame(width: 16, height: 16)
                        Text("Unknown agent").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    Text("·").foregroundStyle(PennantTheme.inkTertiary)
                    if job.enabled, let next = job.nextRunAt {
                        Text("Next \(relativeTime(next))").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    } else if job.enabled {
                        Text("No upcoming run").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    } else {
                        Text("Not running").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    if let last = job.lastRunAt {
                        Text("·").foregroundStyle(PennantTheme.inkTertiary)
                        Text("Last \(relativeTime(last))").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        if let outcome = job.lastOutcome, !outcome.isEmpty {
                            // "skipped: the previous run is still going" reads as a short chip that fits the row.
                            Chip(outcome.lowercased().hasPrefix("skipped") ? "Skipped · previous run still going" : outcome,
                                 color: ScheduleTone.color(for: ScheduleTone.outcome(outcome)))
                                .layoutPriority(1)
                        }
                    }
                }
                .lineLimit(1)
                if skill == nil, !job.prompt.isEmpty {
                    Text(job.prompt).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if job.conversationID != nil {
                    Button { onOpen() } label: { Image(systemName: "bubble.left") }.buttonStyle(.pennantIcon).help("Open conversation")
                }
                Button { onRunNow() } label: { Image(systemName: "play.fill") }.buttonStyle(.pennantIcon).help("Run now")
                Button { onEdit() } label: { Image(systemName: "pencil") }.buttonStyle(.pennantIcon).help("Edit")
                Toggle("Enabled", isOn: Binding(get: { job.enabled }, set: { _ in onToggle() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .padding(.horizontal, 4)
                    .help(job.enabled ? "Pause" : "Resume")
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }.buttonStyle(.pennantIcon).help("Delete")
            }
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
        }
        .card(elevated: true)
        .contentShape(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .onTapGesture { if job.conversationID != nil { onOpen() } else { onEdit() } }
    }
}

/// Create or edit a job by choosing: who runs it, what runs, how often. Free text only where it is the input.
struct ScheduleEditor: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss

    enum RunKind: Hashable { case skill, prompt }

    static let promptStarters: [(prompt: String, subject: String)] = [
        ("Summarise my inbox", "inbox summary"),
        ("Check the calendar for today and brief me", "calendar briefing"),
        ("Tidy the Downloads folder", "Downloads tidy-up"),
        ("Report what changed in <folder>", "folder change report"),
    ]

    private let existing: ScheduledJob?
    @State private var name: String
    @State private var nameEdited: Bool
    @State private var agentID: AgentID?
    @State private var runKind: RunKind
    @State private var skillID: SkillID?
    @State private var prompt: String
    @State private var recipe: ScheduleRecipe
    @State private var timeZone: String
    @State private var enabled: Bool
    @State private var fresh: Bool
    @State private var preview: [Date] = []
    @State private var previewError: String?
    @State private var previewing = false
    @State private var saving = false
    @State private var error: String?

    init(job: ScheduledJob?) {
        existing = job
        _name = State(initialValue: job?.name ?? "")
        _nameEdited = State(initialValue: job != nil)
        _agentID = State(initialValue: job?.agentID)
        _runKind = State(initialValue: job?.skillID != nil ? .skill : .prompt)
        _skillID = State(initialValue: job?.skillID)
        _prompt = State(initialValue: job?.prompt ?? "")
        let tz = job?.timeZone ?? TimeZone.current.identifier
        _timeZone = State(initialValue: tz)
        _recipe = State(initialValue: job.map { ScheduleRecipe.parse($0.schedule, timeZone: tz) } ?? ScheduleRecipe())
        _enabled = State(initialValue: job?.enabled ?? true)
        _fresh = State(initialValue: job?.freshConversation ?? false)
    }

    private var expression: String { recipe.expression(timeZone: timeZone) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "New job" : "Edit job").font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                    Text("Choose what runs, and how often.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    whatSection
                    repeatSection
                    TimeZoneField(identifier: $timeZone)
                    PennantTextField("Name", placeholder: suggestedName.isEmpty ? "Name this job" : suggestedName, text: $name)
                    previewCard
                    Toggle(isOn: $enabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enabled").foregroundStyle(PennantTheme.ink)
                            Text("Paused jobs keep their schedule and can be resumed later.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                    Toggle(isOn: $fresh) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("New conversation each run").foregroundStyle(PennantTheme.ink)
                            Text("Each run starts with a clean slate instead of continuing yesterday's chat.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if let error { Text(error).font(.zoomed(.callout)).foregroundStyle(ScheduleTone.danger) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost).keyboardShortcut(.cancelAction)
                Spacer()
                Button(existing == nil ? "Create job" : "Save") { save() }
                    .buttonStyle(.pennantPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || saving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
        .frame(minWidth: 560, idealWidth: 580, minHeight: 640, idealHeight: 720)
        .task { if session.state.skills.isEmpty { try? await session.loadSkills() } }
        .task(id: "\(expression)|\(timeZone)") { await runPreview() }
        .onAppear {
            if agentID == nil { agentID = session.state.leadAgent?.id }
            if !nameEdited, name.isEmpty { name = suggestedName }
        }
        .onChange(of: suggestedName) { _, new in if !nameEdited { name = new } }
        .onChange(of: name) { _, new in nameEdited = !new.isEmpty && new != suggestedName }
    }

    // MARK: Sections

    private var skillOptions: [ChoiceOption<SkillID?>] {
        var skills = session.state.skills.filter { $0.status != .disabled }
        if let id = skillID, !skills.contains(where: { $0.id == id }), let s = session.state.skills.first(where: { $0.id == id }) { skills.append(s) }
        return skills.map { ChoiceOption(Optional($0.id), title: $0.name, subtitle: $0.purpose.isEmpty ? nil : $0.purpose) }
    }

    private var whatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("What to run")
            ChipRow(selection: $runKind, options: [
                ChoiceOption(RunKind.skill, title: "A skill", symbol: "sparkles"),
                ChoiceOption(RunKind.prompt, title: "A prompt", symbol: "text.quote"),
            ])
            switch runKind {
            case .skill:
                if skillOptions.isEmpty {
                    Text("No enabled skills yet. Agents learn skills from successful runs; you can also import one under Skills.")
                        .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                } else {
                    ChoiceMenu(selection: $skillID, options: skillOptions, placeholder: "Choose a skill…")
                }
                PennantTextField("Extra instructions (optional)", placeholder: "Anything the agent should keep in mind", text: $prompt, lines: 1 ... 4)
            case .prompt:
                ChipRow(selection: starterSelection, options: Self.promptStarters.map { ChoiceOption($0.prompt, title: $0.prompt) })
                PennantTextField(nil, placeholder: "What the agent should do each run", text: $prompt, lines: 3 ... 8)
            }
        }
    }

    /// Chips fill the prompt field; the chip stays selected while the field still holds its text.
    private var starterSelection: Binding<String?> {
        Binding(get: { Self.promptStarters.first { $0.prompt == prompt }?.prompt }, set: { if let s = $0 { prompt = s } })
    }

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Repeat")
            ChipRow(selection: $recipe.preset, options: ScheduleRecipe.Preset.allCases.map { ChoiceOption($0, title: $0.title) })
            switch recipe.preset {
            case .interval:
                ChoiceMenu("Every", selection: $recipe.intervalMinutes, options: intervalOptions)
            case .hourly:
                Text("At the top of every hour.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            case .daily, .weekdays:
                timeField
            case .weekly:
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Days")
                    MultiChipRow(selection: $recipe.days, options: (0 ..< 7).map { ChoiceOption($0, title: ScheduleRecipe.dayTitles[$0]) })
                }
                timeField
            case .monthly:
                ChoiceMenu("Day of the month", selection: $recipe.dayOfMonth, options: (1 ... 28).map { ChoiceOption($0, title: "The \(SchedulePhrasing.ordinal($0))") })
                timeField
            case .once:
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("When")
                    HStack(spacing: 8) {
                        Image(systemName: "calendar").foregroundStyle(PennantTheme.inkSecondary)
                        DatePicker("When", selection: $recipe.onceDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                        Spacer(minLength: 0)
                    }
                    .pennantField()
                }
            case .cron:
                PennantTextField("Cron expression", placeholder: "minute hour day month weekday", text: $recipe.cron).font(.zoomed(.body).monospaced())
                ChipRow(selection: cronExampleSelection, options: ScheduleRecipe.cronExamples.map { ChoiceOption($0.cron, title: $0.title) })
            }
        }
    }

    private var intervalOptions: [ChoiceOption<Int>] {
        var minutes = ScheduleRecipe.intervalChoices
        if !minutes.contains(recipe.intervalMinutes) { minutes.append(recipe.intervalMinutes); minutes.sort() }
        return minutes.map { m in
            if m < 60 { return ChoiceOption(m, title: "\(m) minutes") }
            if m % 60 == 0 { return ChoiceOption(m, title: m == 60 ? "1 hour" : "\(m / 60) hours") }
            return ChoiceOption(m, title: "\(m) minutes")
        }
    }

    private var cronExampleSelection: Binding<String?> {
        Binding(get: { ScheduleRecipe.cronExamples.first { $0.cron == recipe.cron.trimmingCharacters(in: .whitespaces) }?.cron },
                set: { if let c = $0 { recipe.cron = c } })
    }

    private var timeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Time")
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(PennantTheme.inkSecondary)
                DatePicker("Time", selection: $recipe.time, displayedComponents: .hourAndMinute).labelsHidden()
                Spacer(minLength: 0)
            }
            .pennantField()
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel("Next runs")
                if previewing { ProgressView().controlSize(.mini) }
                Spacer()
                Text(expression).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
            }
            if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle").font(.zoomed(.callout)).foregroundStyle(ScheduleTone.danger)
            } else if preview.isEmpty {
                Text(session.connection.isConnected ? "No upcoming run." : "Connect to the host to preview.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkTertiary)
            } else {
                ForEach(preview, id: \.self) { d in
                    HStack {
                        Text(d.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(PennantTheme.ink)
                        Spacer()
                        Text(relativeTime(d)).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    .font(.zoomed(.callout))
                }
            }
        }
        .card(elevated: true)
    }

    // MARK: Derived

    private var suggestedName: String {
        let subject: String
        switch runKind {
        case .skill:
            subject = skillID.flatMap { id in session.state.skills.first { $0.id == id }?.name } ?? "skill run"
        case .prompt:
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if let starter = Self.promptStarters.first(where: { $0.prompt == trimmed }) {
                subject = starter.subject
            } else if trimmed.isEmpty {
                subject = "routine"
            } else {
                let words = trimmed.split(separator: " ").prefix(4).map { $0.trimmingCharacters(in: .punctuationCharacters) }
                let joined = words.joined(separator: " ")
                subject = joined.prefix(1).lowercased() + joined.dropFirst()
            }
        }
        return "\(recipe.cadenceWord) \(subject)"
    }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? suggestedName : typed
    }

    private var valid: Bool {
        guard agentID != nil, !effectiveName.isEmpty, !expression.isEmpty, previewError == nil else { return false }
        switch runKind {
        case .skill: return skillID != nil
        case .prompt: return !prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: Host calls

    private func runPreview() async {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        guard !expr.isEmpty, session.connection.isConnected else { preview = []; previewError = nil; return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        previewing = true
        defer { previewing = false }
        do {
            let (dates, err) = try await session.previewSchedule(expr, timeZone: timeZone, count: 3)
            guard !Task.isCancelled else { return }
            preview = dates
            previewError = err
        } catch {
            previewError = String(describing: error)
        }
    }

    private func save() {
        guard let agentID else { return }
        saving = true
        error = nil
        let expr = expression.trimmingCharacters(in: .whitespaces)
        var job = existing ?? ScheduledJob(name: effectiveName, agentID: agentID, prompt: prompt, schedule: expr)
        job.name = effectiveName
        job.agentID = agentID
        job.skillID = runKind == .skill ? skillID : nil
        job.prompt = prompt
        job.schedule = expr
        job.timeZone = timeZone
        job.enabled = enabled
        job.freshConversation = fresh ? true : nil
        job.updatedAt = Date()
        Task {
            defer { saving = false }
            do { _ = try await session.upsertSchedule(job); dismiss() } catch { self.error = String(describing: error) }
        }
    }
}
