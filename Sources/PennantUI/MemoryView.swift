import PennantClientKit
import PennantCore
import SwiftUI

/// Readable memory: preferences, entities by kind, relations, search, edit/correct/forget.
public struct MemoryView: View {
    @Environment(\.hostSession) private var session
    @State private var query = ""
    @State private var hits: [MemoryHit] = []
    @State private var kindFilter: MemoryEntityKind?
    @State private var overview: MemoryOverview?
    @State private var editingEntity: MemoryEntity?
    @State private var editingPreference: Preference?
    @State private var creatingPreference = false
    @State private var confirmForget: ForgetTarget?
    @State private var selectedEntity: MemoryEntity?
    @State private var error: String?
    /// Pennant's own decisions keeping memory current (there's no review queue for you).
    @State private var upkeep: [MemoryUpkeepEntry] = []
    @State private var showAllUpkeep = false
    /// Facts first: they're what memory is mostly for; instructions have their own tab.
    @AppStorage("pennant.memory.tab") private var tab: Tab = .facts

    enum Tab: String { case facts, preferences }

    enum ForgetTarget: Identifiable {
        case entity(MemoryEntity), preference(Preference)
        var id: String {
            switch self { case .entity(let e): return e.id.rawValue; case .preference(let p): return p.id.rawValue }
        }
        var name: String {
            switch self { case .entity(let e): return e.name; case .preference(let p): return p.text }
        }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField("Search memory", text: $query)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .buttonStyle(.pennantPrimaryCompact)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if !hits.isEmpty {
                    Button("Clear") { hits = []; query = "" }.buttonStyle(PennantButtonStyle(.ghost, compact: true))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, overview == nil ? 12 : 6)
            if let overview { statsRow(overview) }
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(MemoryTone.danger).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            ScrollView {
                if hits.isEmpty { browser } else { results }
            }
        }
        .background(PennantTheme.panelBackground)
        // Load once connected (the screen can appear while the app is still connecting), and again after a reconnect.
        .task(id: session.connection.isConnected) { if session.connection.isConnected { await reload() } }
        .onChange(of: query) { _, new in if new.trimmingCharacters(in: .whitespaces).isEmpty { hits = [] } }
        .sheet(item: $editingEntity) { e in EntityEditor(entity: e) { updated in Task { await save(entity: updated) } } }
        .sheet(item: $editingPreference) { p in PreferenceEditor(preference: p) { updated in Task { await save(preference: updated) } } }
        .sheet(isPresented: $creatingPreference) {
            PreferenceEditor(preference: Preference(text: "", provenance: Provenance(sourceType: .userEdit))) { p in Task { await save(preference: p, isNew: true) } }
        }
        .sheet(item: $selectedEntity) { e in EntityDetail(entity: e) }
        .confirmationDialog("Forget this memory?", isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }), presenting: confirmForget) { target in
            Button("Forget \"\(target.name.prefix(40))\"", role: .destructive) { Task { await forget(target) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed from memory and search, and agents won't remember it again (you can restore that under Removed).")
        }
    }

    /// Counts across the top. On a narrow screen (a phone) the lesser counts give way instead of wrapping letter by
    /// letter: first the file size and relations, then preferences and skills.
    private func statsRow(_ o: MemoryOverview) -> some View {
        let ready = o.embeddableCount > 0 ? min(100, Int((Double(o.embeddedCount) / Double(o.embeddableCount) * 100).rounded())) : nil
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                stat(o.entityCount, "facts"); stat(o.relationCount, "relations"); stat(o.preferenceCount, "preferences")
                stat(o.passageCount, "passages"); stat(o.skillCount, "skills")
                Spacer(minLength: 8)
                if let ready { note("meaning search \(ready)% ready") }
                note(ByteCountFormatter.string(fromByteCount: Int64(o.databaseBytes), countStyle: .file))
            }
            HStack(spacing: 12) {
                stat(o.entityCount, "facts"); stat(o.preferenceCount, "preferences"); stat(o.passageCount, "passages")
                Spacer(minLength: 8)
                if let ready { note("search \(ready)%") }
            }
            HStack(spacing: 12) {
                stat(o.entityCount, "facts"); stat(o.passageCount, "passages")
                Spacer(minLength: 0)
            }
        }
        .help(ready.map { "Meaning search covers \($0)% (\(o.embeddedCount) of \(o.embeddableCount) facts, instructions and passages)" } ?? "")
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text("\(n)").font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
            Text(label).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
        }
        .fixedSize()
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).fixedSize()
    }

    private var visiblePreferences: [Preference] {
        session.state.preferences.filter { $0.status != .forgotten && $0.status != .superseded }
    }

    private var visibleEntities: [MemoryEntity] {
        session.state.entities.filter { (kindFilter == nil || $0.kind == kindFilter) && $0.status != .forgotten }
    }

    private var kindOptions: [ChoiceOption<MemoryEntityKind?>] {
        [ChoiceOption(MemoryEntityKind?.none, title: "All")]
            + MemoryEntityKind.allCases.map { ChoiceOption(Optional($0), title: $0.rawValue.capitalized) }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) {
                Text("Facts (\(visibleEntities.count))").tag(Tab.facts)
                Text("Preferences (\(visiblePreferences.count))").tag(Tab.preferences)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .facts: factsTab
            case .preferences: preferencesTab
            }
        }
        .padding(16)
    }

    private var factsTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !upkeep.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Kept current by Pennant")
                    Text("When something new disagrees with what memory holds, Pennant weighs it against what was said and decides. Undo puts back what it set aside.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    ForEach(upkeep.prefix(showAllUpkeep ? 60 : 5)) { e in
                        UpkeepRow(entry: e) {
                            Task { upkeep = (try? await session.undoMemoryUpkeep(e.id)) ?? upkeep }
                        }
                    }
                    if upkeep.count > 5 {
                        Button(showAllUpkeep ? "Show fewer" : "Show all \(min(upkeep.count, 60))") { showAllUpkeep.toggle() }
                            .buttonStyle(.plain).font(.zoomed(.caption)).foregroundStyle(PennantTheme.brandInk)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ChipRow(selection: $kindFilter, options: kindOptions)
                if visibleEntities.isEmpty {
                    MemoryEmptyCard(text: session.state.entities.isEmpty ? "No facts recorded yet. Agents remember people, projects, and places as they work." : "Nothing of this kind yet.")
                }
                LazyVStack(spacing: 8) {
                    ForEach(visibleEntities) { e in
                        EntityCard(entity: e, onOpen: { selectedEntity = e }, onEdit: { editingEntity = e }, onForget: { confirmForget = .entity(e) })
                    }
                }
            }
            RemovedNamesSection()
        }
    }

    private var preferencesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Standing instructions every agent follows.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                Spacer()
                Button { creatingPreference = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(PennantButtonStyle(.secondary, compact: true))
                    .help("Add an instruction")
            }
            if visiblePreferences.isEmpty {
                MemoryEmptyCard(text: "No standing instructions yet. Tell an agent how you like things done, or add one here.")
            }
            ForEach(visiblePreferences) { p in
                PreferenceCard(preference: p, onEdit: { editingPreference = p }, onForget: { confirmForget = .preference(p) })
            }
        }
    }

    private var results: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            SectionLabel("\(hits.count) result\(hits.count == 1 ? "" : "s")")
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                switch hit.item {
                case .entity(let e):
                    EntityCard(entity: e, note: hit.reason, onOpen: { selectedEntity = e }, onEdit: { editingEntity = e }, onForget: { confirmForget = .entity(e) })
                case .relation(let r, let from, let to):
                    MemoryHitCard(symbol: "arrow.left.arrow.right", note: hit.reason) {
                        HStack(spacing: 6) {
                            Text(from.name).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink)
                            Text(r.relation.replacingOccurrences(of: "_", with: " ")).foregroundStyle(PennantTheme.inkSecondary)
                            Text(to.name).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink)
                            Chip(r.status.rawValue.capitalized, color: PennantTheme.color(for: r.status))
                        }
                        .lineLimit(1)
                    }
                case .preference(let p):
                    PreferenceCard(preference: p, note: hit.reason, onEdit: { editingPreference = p }, onForget: { confirmForget = .preference(p) })
                case .message(let m):
                    MemoryHitCard(symbol: "bubble.left", note: hit.reason) {
                        HStack(alignment: .top) {
                            Text(m.text).foregroundStyle(PennantTheme.ink).lineLimit(3)
                            Spacer()
                            Text(relativeTime(m.createdAt)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        }
                    }
                case .passage(let p):
                    PassageCard(passage: p, highlight: query, note: hit.reason)
                }
            }
        }
        .padding(16)
    }

    private func reload() async {
        error = nil
        do {
            try await session.loadMemory()
            overview = try await session.memoryOverview()
            upkeep = (try? await session.memoryUpkeepLog()) ?? []
        } catch { self.error = String(describing: error) }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task {
            do { hits = try await session.searchMemory(MemoryQuery(text: q, limit: 40)) } catch { self.error = String(describing: error) }
        }
    }

    private func save(entity: MemoryEntity) async {
        var e = entity
        e.provenance = Provenance(sourceType: .userEdit, note: "Edited in Memory view")
        e.status = .asserted
        e.version += 1
        e.updatedAt = Date()
        e.observedAt = Date()
        do { _ = try await session.send(.upsertEntity(e)); await reload() } catch { self.error = String(describing: error) }
    }

    private func save(preference: Preference, isNew: Bool = false) async {
        var p = preference
        p.provenance = Provenance(sourceType: .userEdit, note: isNew ? "Added in Memory view" : "Corrected in Memory view")
        p.status = .asserted
        if !isNew { p.version += 1 }
        p.updatedAt = Date()
        do { _ = try await session.send(.upsertPreference(p)); await reload() } catch { self.error = String(describing: error) }
    }

    private func forget(_ target: ForgetTarget) async {
        do {
            switch target {
            case .entity(let e): _ = try await session.send(.forgetEntity(e.id))
            case .preference(let p): _ = try await session.send(.forgetPreference(p.id))
            }
            await reload()
        } catch { self.error = String(describing: error) }
    }
}

// MARK: - Shared pieces

/// Status colour for errors, from the theme's task-state palette (the foundation has no standalone danger token).
enum MemoryTone {
    static let danger = PennantTheme.color(for: TaskState.failed)
}

enum MemoryGlyph {
    static func symbol(_ kind: MemoryEntityKind) -> String {
        switch kind {
        case .person: return "person"
        case .project: return "folder"
        case .document: return "doc.text"
        case .application: return "app"
        case .deadline: return "calendar"
        case .place: return "mappin"
        case .organization: return "building.2"
        case .account: return "key"
        case .device: return "desktopcomputer"
        case .topic: return "tag"
        case .fact: return "lightbulb"
        case .other: return "circle"
        }
    }

    /// "2 hours ago" for this week, then the date ("Sep 12"), so an old fact says when it was learned.
    static func when(_ date: Date) -> String {
        date.timeIntervalSinceNow > -7 * 86_400 ? relativeTime(date) : date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func sourceLabel(_ p: Provenance) -> String {
        switch p.sourceType {
        case .userMessage: return "you said"
        case .assistantMessage: return "agent said"
        case .toolObservation: return "observed"
        case .inference: return "inferred"
        case .userEdit: return "edited by you"
        case .importedData: return "imported"
        case .skillRun: return "from a skill run"
        }
    }
}

/// Scopes an editor can pick from: shared, then each persistent agent's own scope, then whatever the record already has.
enum MemoryScopes {
    static func options(agents: [AgentProfile], current: String) -> [ChoiceOption<String>] {
        var out = [ChoiceOption("shared", title: "Shared", subtitle: "Every agent can read it", symbol: "person.2")]
        for a in agents where !out.contains(where: { $0.value == a.memoryScope.label }) {
            out.append(ChoiceOption(a.memoryScope.label, title: a.name, subtitle: a.memoryScope.label, symbol: "person"))
        }
        if !current.isEmpty, !out.contains(where: { $0.value == current }) {
            out.append(ChoiceOption(current, title: current, subtitle: "Existing scope", symbol: "tag"))
        }
        return out
    }
}

struct MemoryEmptyCard: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.zoomed(.callout))
            .foregroundStyle(PennantTheme.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }
}

/// A round glyph for the leading edge of a card.
struct MemoryCardGlyph: View {
    var symbol: String
    var color: Color = PennantTheme.inkSecondary
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.12))
            Image(systemName: symbol).font(.zoomed(size: 13, weight: .medium)).foregroundStyle(color)
        }
        .frame(width: 30, height: 30)
    }
}

/// The "…" menu on a card.
struct MemoryCardMenu<Items: View>: View {
    @ViewBuilder var items: Items
    var body: some View {
        Menu { items } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .buttonStyle(.pennantIcon)
            .menuIndicator(.hidden)
    }
}

/// Generic search-hit card for relations and messages.
struct MemoryHitCard<Content: View>: View {
    var symbol: String
    var note: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MemoryCardGlyph(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                content
                if !note.isEmpty { Text(note).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary) }
            }
            Spacer(minLength: 0)
        }
        .card(elevated: true)
    }
}

struct PreferenceCard: View {
    var preference: Preference
    var note: String? = nil
    var onEdit: () -> Void
    var onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MemoryCardGlyph(symbol: "text.quote")
            VStack(alignment: .leading, spacing: 5) {
                Text(preference.text).foregroundStyle(PennantTheme.ink)
                HStack(spacing: 6) {
                    Chip(preference.status.rawValue.capitalized, color: PennantTheme.color(for: preference.status))
                    Chip("v\(preference.version)")
                    if preference.scope != "shared" { Chip(preference.scope) }
                    Text("\(MemoryGlyph.sourceLabel(preference.provenance)) · \(MemoryGlyph.when(preference.updatedAt))")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                }
                if let note, !note.isEmpty { Text(note).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary) }
            }
            Spacer(minLength: 0)
            MemoryCardMenu {
                Button("Edit or correct") { onEdit() }
                Button("Forget", role: .destructive) { onForget() }
            }
        }
        .card(elevated: true)
    }
}

struct EntityCard: View {
    var entity: MemoryEntity
    var note: String? = nil
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onForget: () -> Void

    private var provenanceLine: String {
        var parts = [MemoryGlyph.sourceLabel(entity.provenance), MemoryGlyph.when(entity.observedAt)]
        if entity.scope != "shared", !entity.scope.isEmpty { parts.append(entity.scope) }
        return parts.joined(separator: " · ")
    }

    private var name: some View {
        Text(entity.name).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
    }

    private var tags: some View {
        HStack(spacing: 6) {
            Chip(entity.kind.rawValue.capitalized)
            Chip(entity.status.rawValue.capitalized, color: PennantTheme.color(for: entity.status))
        }
        .fixedSize()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MemoryCardGlyph(symbol: MemoryGlyph.symbol(entity.kind))
            VStack(alignment: .leading, spacing: 4) {
                // The name and its tags on one line when they fit; with large text or a long name, the tags go under it
                // rather than cutting the name short.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        name
                        tags
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        name.lineLimit(2)
                        tags
                    }
                }
                if !entity.summary.isEmpty {
                    Text(entity.summary).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2)
                }
                Text(provenanceLine).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                if let note, !note.isEmpty { Text(note).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary) }
            }
            Spacer(minLength: 0)
            MemoryCardMenu {
                Button("Details") { onOpen() }
                Button("Edit or correct") { onEdit() }
                Button("Forget", role: .destructive) { onForget() }
            }
        }
        .card(elevated: true)
        .contentShape(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .onTapGesture { onOpen() }
        .contextMenu {
            Button("Details") { onOpen() }
            Button("Edit or correct") { onEdit() }
            Button("Forget", role: .destructive) { onForget() }
        }
    }
}

/// Sheet chrome shared by the memory editors and the detail view: title, scrolling content, pill buttons.
struct MemorySheet<Content: View>: View {
    var title: String
    var subtitle: String?
    var primaryTitle: String
    var canConfirm: Bool = true
    var showsCancel: Bool = true
    var onCancel: () -> Void
    var onConfirm: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            HStack {
                if showsCancel { Button("Cancel") { onCancel() }.buttonStyle(.pennantGhost).keyboardShortcut(.cancelAction) }
                Spacer()
                Button(primaryTitle) { onConfirm() }.buttonStyle(.pennantPrimary).keyboardShortcut(.defaultAction).disabled(!canConfirm)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
    }
}

struct MemoryDetailRow: View {
    var label: String
    var value: String
    var monospaced: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? .zoomed(.callout).monospaced() : .zoomed(.callout))
                .foregroundStyle(PennantTheme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Detail and editors

struct EntityDetail: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    var entity: MemoryEntity
    @State private var relations: [MemoryRelation] = []
    @State private var names: [MemoryEntityID: String] = [:]
    /// Passages that mention it: the words behind the fact.
    @State private var evidence: [MemoryPassage] = []
    @State private var renaming = false
    @State private var newName = ""
    @State private var actionError: String?

    /// Other current facts of the same kind, to merge this one into.
    private var mergeTargets: [MemoryEntity] {
        session.state.entities.filter { $0.id != entity.id && $0.kind == entity.kind && ($0.status == .asserted || $0.status == .inferred) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        MemorySheet(title: entity.name, subtitle: entity.kind.rawValue.capitalized, primaryTitle: "Done", showsCancel: false, onCancel: { dismiss() }, onConfirm: { dismiss() }) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Fact")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Status").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 90, alignment: .leading)
                        Chip(entity.status.rawValue.capitalized, color: PennantTheme.color(for: entity.status))
                    }
                    MemoryDetailRow(label: "Scope", value: entity.scope)
                    MemoryDetailRow(label: "Version", value: "\(entity.version)")
                    if !entity.summary.isEmpty { Text(entity.summary).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).textSelection(.enabled) }
                    if let obj = entity.attributes.objectValue, !obj.isEmpty {
                        ForEach(obj.keys.sorted(), id: \.self) { k in MemoryDetailRow(label: k, value: obj[k]?.compactText ?? "") }
                    }
                    HStack(spacing: 8) {
                        Button("Rename…") { newName = entity.name; renaming = true }
                            .buttonStyle(PennantButtonStyle(.secondary, compact: true))
                        if !mergeTargets.isEmpty {
                            Menu("Merge into…") {
                                ForEach(mergeTargets.prefix(40)) { t in
                                    Button(t.name) { Task { await run { _ = try await session.mergeEntities(entity.id, into: t.id) } } }
                                }
                            }
                            .menuStyle(.button).buttonStyle(PennantButtonStyle(.secondary, compact: true)).fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                    if let actionError { Text(actionError).font(.zoomed(.caption)).foregroundStyle(MemoryTone.danger) }
                }
                .card(elevated: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Evidence")
                if evidence.isEmpty {
                    Text("No conversation mentions it by name yet.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).card(elevated: true)
                }
                ForEach(evidence) { p in PassageCard(passage: p, highlight: entity.name) }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Source")
                VStack(alignment: .leading, spacing: 8) {
                    MemoryDetailRow(label: "From", value: MemoryGlyph.sourceLabel(entity.provenance))
                    if let id = entity.provenance.sourceID { MemoryDetailRow(label: "Source ID", value: id, monospaced: true) }
                    if let seq = entity.provenance.eventSeq { MemoryDetailRow(label: "Event", value: "#\(seq)") }
                    if !entity.provenance.note.isEmpty { MemoryDetailRow(label: "Note", value: entity.provenance.note) }
                    MemoryDetailRow(label: "Observed", value: entity.observedAt.formatted())
                }
                .card(elevated: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Relationships")
                VStack(alignment: .leading, spacing: 8) {
                    if relations.isEmpty { Text("None recorded").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary) }
                    ForEach(relations) { r in
                        HStack(spacing: 6) {
                            Text(r.fromEntityID == entity.id ? entity.name : (names[r.fromEntityID] ?? "…")).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                            Text(r.relation.replacingOccurrences(of: "_", with: " ")).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                            Text(r.toEntityID == entity.id ? entity.name : (names[r.toEntityID] ?? "…")).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                            Spacer()
                            Chip(r.status.rawValue.capitalized, color: PennantTheme.color(for: r.status))
                        }
                        .lineLimit(1)
                    }
                }
                .card(elevated: true)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await run { _ = try await session.renameEntity(entity.id, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old name stays as an alias, so agents that use it update this fact. Renaming to another fact's name merges them.")
        }
        .task {
            evidence = (try? await session.memoryEvidence(entity.id)) ?? []
            relations = (try? await session.relations(for: entity.id)) ?? []
            for r in relations {
                for id in [r.fromEntityID, r.toEntityID] where id != entity.id && names[id] == nil {
                    names[id] = session.state.entities.first { $0.id == id }?.name ?? id.rawValue
                }
            }
        }
    }
}

extension EntityDetail {
    /// Runs a correction and closes the sheet (the fact it showed has a new version now).
    func run(_ action: @escaping () async throws -> Void) async {
        do { try await action(); dismiss() } catch { actionError = String(describing: error) }
    }
}

struct EntityEditor: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State var entity: MemoryEntity
    var onSave: (MemoryEntity) -> Void
    @State private var attributesText: String
    @State private var showAttributes = false

    init(entity: MemoryEntity, onSave: @escaping (MemoryEntity) -> Void) {
        _entity = State(initialValue: entity)
        self.onSave = onSave
        _attributesText = State(initialValue: (try? String(decoding: JSONCodec.prettyEncoder.encode(entity.attributes), as: UTF8.self)) ?? "{}")
    }

    private var kindOptions: [ChoiceOption<MemoryEntityKind>] {
        MemoryEntityKind.allCases.map { ChoiceOption($0, title: $0.rawValue.capitalized, symbol: MemoryGlyph.symbol($0)) }
    }

    var body: some View {
        MemorySheet(title: "Correct fact", subtitle: "Saving marks it as asserted by you and keeps the history.", primaryTitle: "Save",
                    canSave: !entity.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: { dismiss() },
                    onConfirm: {
                        if let v = try? JSONValue.parse(attributesText) { entity.attributes = v }
                        onSave(entity)
                        dismiss()
                    }) {
            PennantTextField("Name", placeholder: "Who or what this is", text: $entity.name)
            ChoiceMenu("Kind", selection: $entity.kind, options: kindOptions)
            ChoiceMenu("Scope", selection: $entity.scope, options: MemoryScopes.options(agents: session.state.persistentAgents, current: entity.scope))
            PennantTextField("Summary", placeholder: "One or two lines an agent can rely on", text: $entity.summary, lines: 2 ... 6)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAttributes.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showAttributes ? "chevron.down" : "chevron.right").font(.zoomed(.caption).weight(.semibold))
                        Text("Attributes (JSON)")
                    }
                    .font(.zoomed(.subheadline)).foregroundStyle(PennantTheme.inkSecondary)
                }
                .buttonStyle(.plain)
                if showAttributes {
                    TextEditor(text: $attributesText)
                        .font(.zoomed(.callout).monospaced())
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .pennantField()
                }
            }
        }
        .frame(minWidth: 460, minHeight: 440)
    }
}

extension MemorySheet {
    /// Convenience: `canSave` reads as the intent at the call site.
    init(title: String, subtitle: String? = nil, primaryTitle: String, canSave: Bool, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, primaryTitle: primaryTitle, canConfirm: canSave, showsCancel: true, onCancel: onCancel, onConfirm: onConfirm, content: content)
    }
}

struct PreferenceEditor: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State var preference: Preference
    var onSave: (Preference) -> Void

    private var isNew: Bool { preference.version <= 1 && preference.text.isEmpty }

    var body: some View {
        MemorySheet(title: isNew ? "New instruction" : "Edit instruction",
                    subtitle: "Instructions govern future work for every agent that can read the scope.",
                    primaryTitle: "Save",
                    canSave: !preference.text.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: { dismiss() },
                    onConfirm: { onSave(preference); dismiss() }) {
            PennantTextField("Instruction", placeholder: "Always reply in British English; keep receipts in ~/Finance", text: $preference.text, lines: 3 ... 8)
            ChoiceMenu("Scope", selection: $preference.scope, options: MemoryScopes.options(agents: session.state.persistentAgents, current: preference.scope))
        }
        .frame(minWidth: 460, minHeight: 320)
    }
}

/// One decision Pennant made about a fact: what it did, why, when, and Undo.
struct UpkeepRow: View {
    var entry: MemoryUpkeepEntry
    var onUndo: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.zoomed(size: 12, weight: .semibold))
                .foregroundStyle(PennantTheme.brandInk)
                .frame(width: 24, height: 24)
                .background(PennantTheme.brandSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                if !entry.reason.isEmpty { Text(entry.reason).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                Text(relativeTime(entry.at)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
            }
            Spacer(minLength: 8)
            if entry.undone {
                Text("Undone").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            } else {
                Button("Undo", action: onUndo).buttonStyle(.pennantGhostCompact).help("Put back what was set aside")
            }
        }
        .padding(10)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var headline: String {
        switch entry.action {
        case .kept: return "Kept \(entry.name) as it was"
        case .updated: return "Updated \(entry.name)"
        case .combined: return "Combined what it knew about \(entry.name)"
        }
    }
    private var symbol: String {
        switch entry.action {
        case .kept: return "checkmark"
        case .updated: return "arrow.triangle.2.circlepath"
        case .combined: return "arrow.triangle.merge"
        }
    }
}
