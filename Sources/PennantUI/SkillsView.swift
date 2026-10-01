import PennantClientKit
import PennantCore
import SwiftUI

// MARK: - Origin and status styling

/// Where a skill came from decides the tint of its icon: built-in Ocean, learned Moss, imported Violet.
enum SkillOriginStyle {
    static func color(_ origin: String) -> Color {
        switch origin {
        case "builtin": return Color(hex: "#2F80ED")
        case "learned": return Color(hex: "#3DB553")
        case "imported": return Color(hex: "#8B5CF6")
        case "taught": return Color(hex: "#F0762B")
        default: return Color(hex: "#6B7280")
        }
    }

    static func symbol(_ origin: String) -> String {
        switch origin {
        case "builtin": return "shippingbox"
        case "learned": return "sparkles"
        case "imported": return "square.and.arrow.down"
        case "taught": return "hand.point.up.left"
        default: return "book"
        }
    }

    static func statusColor(_ status: SkillStatus) -> Color {
        switch status {
        case .provisional: return Color(hex: "#F0A93B")
        case .validated: return Color(hex: "#3DB553")
        case .disabled: return PennantTheme.inkTertiary
        }
    }

    static func statusTitle(_ status: SkillStatus) -> String {
        switch status {
        case .provisional: return "Provisional"
        case .validated: return "Validated"
        case .disabled: return "Disabled"
        }
    }
}

/// Round icon tinted by origin, used in the list and the detail header.
struct SkillIcon: View {
    var origin: String
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            Circle().fill(SkillOriginStyle.color(origin).opacity(0.16))
            Image(systemName: SkillOriginStyle.symbol(origin))
                .font(.zoomed(size: size * 0.42, weight: .medium))
                .foregroundStyle(SkillOriginStyle.color(origin))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Skills pane

/// Learned procedures: visible, editable, and switchable.
public struct SkillsView: View {
    @Environment(\.hostSession) private var session
    @State private var selected: Skill?
    @State private var editing: Skill?
    @State private var creating = false
    @State private var teaching = false
    @State private var error: String?
    @State private var importRequest: SkillImportRequest?
    @State private var query = ""
    @State private var selecting = false
    @State private var picked: Set<SkillID> = []
    @State private var confirmBulkDelete = false
    @State private var busy = false

    public init() {}

    /// Every version of each skill, newest first, keyed by name (agents improve skills by saving new versions).
    private var versionsByName: [String: [Skill]] {
        Dictionary(grouping: session.state.skills) { $0.name.lowercased() }.mapValues { $0.sorted { $0.version > $1.version } }
    }

    private func versions(of skill: Skill) -> [Skill] { versionsByName[skill.name.lowercased()] ?? [skill] }

    /// How often a skill has been used, across all its versions, and when last.
    private func usage(_ skill: Skill) -> (count: Int, last: Date) {
        let outcomes = versions(of: skill).flatMap(\.outcomes)
        return (outcomes.count, outcomes.map(\.at).max() ?? .distantPast)
    }

    /// One row per skill (its newest version), the most used first; then the most recently used, then by name.
    private var skills: [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let latest = versionsByName.values.compactMap(\.first).map { ($0, usage($0)) }.sorted { a, b in
            if a.1.count != b.1.count { return a.1.count > b.1.count }
            if a.1.last != b.1.last { return a.1.last > b.1.last }
            return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
        }.map(\.0)
        guard !q.isEmpty else { return latest }
        return latest.filter { $0.name.lowercased().contains(q) || $0.purpose.lowercased().contains(q) || $0.applicability.lowercased().contains(q) }
    }

    private var current: Skill? { selected.flatMap { s in session.state.skills.first { $0.id == s.id } } }

    /// Ticked skills (every version of each ticked row) in the visible list; bulk actions apply to these.
    private var pickedSkills: [Skill] { skills.flatMap { versions(of: $0) }.filter { picked.contains($0.id) } }
    private var deletable: [Skill] { pickedSkills.filter { $0.origin != "builtin" } }
    private var allPicked: Bool { !skills.isEmpty && skills.allSatisfy { picked.contains($0.id) } }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// On an iPhone the navigation bar already says "Skills".
    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    /// Side by side on the Mac and iPad; on an iPhone the list fills the screen and a skill opens on its own page.
    @ViewBuilder private var layout: some View {
        #if os(iOS)
        if sizeClass == .compact {
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PennantTheme.windowBackground)
                .navigationDestination(item: $selected) { skill in
                    let live = session.state.skills.first { $0.id == skill.id } ?? skill
                    SkillDetail(skill: live, onEdit: { editing = live }, onToggle: { toggle(live) }, onDelete: { delete(live); selected = nil }, onReimport: { reimport(live) },
                                versions: versions(of: live), onSelectVersion: { selected = $0 }, onDeleteOlder: { deleteOlder(than: live) },
                                onRestore: { old in Task { await restore(old) } })
                    .background(PennantTheme.windowBackground)
                    .navigationTitle(live.name)
                    .navigationBarTitleDisplayMode(.inline)
                }
        } else {
            split
        }
        #else
        split
        #endif
    }

    private var split: some View {
        HStack(spacing: 0) {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                .background(PennantTheme.sidebarBackground)
            Divider().overlay(PennantTheme.divider)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PennantTheme.windowBackground)
        }
        // Open the first skill rather than an empty pane.
        .task(id: groups.first?.skills.first?.id) {
            if selected == nil, let first = groups.first?.skills.first { selected = first }
        }
    }

    public var body: some View {
        layout
        // Reload once connected: on a phone the pane often opens before the connection is up.
        .task(id: session.connection.isConnected) {
            if session.connection.isConnected { try? await session.loadSkills() }
        }
        .sheet(item: $importRequest) { r in SkillImportSheet(request: r) }
        .sheet(isPresented: $teaching) { TeachStartSheet() }
        .sheet(item: $editing) { s in SkillEditor(skill: s) { updated in Task { await save(updated) } } }
        .sheet(isPresented: $creating) {
            SkillEditor(skill: Skill(name: "", purpose: ""), isNew: true) { created in Task { await save(created, select: true) } }
        }
        .confirmationDialog(bulkDeleteTitle, isPresented: $confirmBulkDelete) {
            Button(bulkDeleteTitle.replacingOccurrences(of: "?", with: ""), role: .destructive) { bulkDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let skipped = pickedSkills.count - deletable.count
            Text(skipped > 0
                ? "\(skipped) built-in skill\(skipped == 1 ? " is" : "s are") skipped; built-ins can only be disabled. Agents will no longer find or use the rest."
                : "Agents will no longer find or use them.")
        }
        .overlay(alignment: .bottom) {
            if let error {
                Text(error)
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.danger)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(PennantTheme.cardElevated, in: Capsule())
                    .overlay(Capsule().stroke(PennantTheme.border))
                    .padding(12)
            }
        }
    }

    private var bulkDeleteTitle: String { "Delete \(deletable.count) skill\(deletable.count == 1 ? "" : "s")?" }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            PaneHeader(isCompact ? "" : "Skills") {
                if selecting {
                    Button(allPicked ? "None" : "Select all") {
                        let ids = skills.flatMap { versions(of: $0) }.map(\.id)
                        if allPicked { picked.subtract(ids) } else { picked.formUnion(ids) }
                    }
                    .buttonStyle(.pennantGhostCompact)
                    .disabled(skills.isEmpty)
                } else {
                    // Words when the column is wide enough, icons when it is not; never a squeezed, wrapped label.
                    ViewThatFits(in: .horizontal) {
                        headerActions(iconsOnly: false)
                        headerActions(iconsOnly: true)
                    }
                }
            }
            SearchField("Search skills", text: $query)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.zoomed(.caption).weight(.semibold))
                            .foregroundStyle(PennantTheme.inkTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, group.title == groups.first?.title ? 4 : 14)
                            .padding(.bottom, 2)
                        ForEach(group.skills) { skill in row(skill) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .overlay {
                if session.state.skills.isEmpty {
                    EmptyState(title: "No skills yet", message: "Agents record procedures after verified runs. You can also teach one by doing it, import SKILL.md folders, or write one yourself.") {
                        Button("Import…") { importRequest = SkillImportRequest() }.buttonStyle(.pennantCompact).disabled(!session.connection.isConnected)
                    }
                } else if skills.isEmpty {
                    Text("No skills match \"\(query)\".").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).padding()
                }
            }
            if selecting { selectionBar }
        }
    }

    /// The list in three groups: yours (learned, taught, imported), the built-ins, and the ones turned off.
    private var groups: [(title: String, skills: [Skill])] {
        let on = skills.filter { $0.status != .disabled }
        return [("Your skills", on.filter { $0.origin != "builtin" }),
                ("Built in", on.filter { $0.origin == "builtin" }),
                ("Turned off", skills.filter { $0.status == .disabled })]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, skills: $0.1) }
    }

    @ViewBuilder private func row(_ skill: Skill) -> some View {
                        if selecting {
                            SelectableRow(selected: picked.contains(skill.id), action: { togglePick(skill) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: picked.contains(skill.id) ? "checkmark.square.fill" : "square")
                                        .font(.zoomed(.title3))
                                        .foregroundStyle(picked.contains(skill.id) ? PennantTheme.ink : PennantTheme.inkTertiary)
                                        .frame(width: 22)
                                        .accessibilityHidden(true)
                                    SkillRow(skill: skill, versionCount: versions(of: skill).count, uses: usage(skill).count)
                                }
                            }
                            .accessibilityAddTraits(picked.contains(skill.id) ? [.isSelected] : [])
                        } else {
                            SelectableRow(selected: selected.map { sel in versions(of: skill).contains { $0.id == sel.id } } ?? false, action: { selected = skill }) {
                                SkillRow(skill: skill, versionCount: versions(of: skill).count, uses: usage(skill).count)
                            }
                        }
    }

    /// Bottom bar in selection mode: the count, then enable, disable, and delete for the ticked skills.
    private func headerActions(iconsOnly: Bool) -> some View {
        let connected = session.connection.isConnected
        return HStack(spacing: iconsOnly ? 2 : 6) {
            headerButton("Select", symbol: "checkmark.circle", iconsOnly: iconsOnly, help: "Select skills to enable, disable or delete") { selecting = true }
                .disabled(session.state.skills.isEmpty)
            headerButton("Import…", symbol: "square.and.arrow.down", iconsOnly: iconsOnly, help: "Import SKILL.md folders or a git repository") { importRequest = SkillImportRequest() }
                .disabled(!connected)
            #if os(macOS)
            headerButton("Teach", symbol: "hand.point.up.left", iconsOnly: iconsOnly, help: "Show Pennant how to do something once; it drafts a skill from what you do") { teaching = true }
                .disabled(!connected || session.state.teaching?.isRecording == true)
            #endif
            Button("New") { creating = true }
                .buttonStyle(.pennantPrimaryCompact)
                .fixedSize()
                .disabled(!connected)
        }
        .fixedSize()
    }

    @ViewBuilder private func headerButton(_ title: String, symbol: String, iconsOnly: Bool, help: String, action: @escaping () -> Void) -> some View {
        if iconsOnly {
            Button(action: action) { Image(systemName: symbol) }
                .buttonStyle(.pennantIcon)
                .help("\(title.replacingOccurrences(of: "…", with: "")): \(help)")
                .accessibilityLabel(title.replacingOccurrences(of: "…", with: ""))
        } else {
            Button(title, action: action)
                .buttonStyle(.pennantCompact)
                .fixedSize()
                .help(help)
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 8) {
            Divider().overlay(PennantTheme.divider)
            HStack(spacing: 8) {
                Text("\(pickedSkills.count) selected")
                    .font(.zoomed(.subheadline).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                if busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel") { exitSelection() }.buttonStyle(.pennantGhostCompact)
            }
            .padding(.horizontal, 12)
            HStack(spacing: 8) {
                Button("Enable") { setStatus(pickedSkills, enabled: true) }
                    .buttonStyle(.pennantCompact)
                    .disabled(pickedSkills.isEmpty || busy || !session.connection.isConnected)
                Button("Disable") { setStatus(pickedSkills, enabled: false) }
                    .buttonStyle(.pennantCompact)
                    .disabled(pickedSkills.isEmpty || busy || !session.connection.isConnected)
                Spacer(minLength: 0)
                Button("Delete…") { confirmBulkDelete = true }
                    .buttonStyle(.pennantDestructiveCompact)
                    .disabled(deletable.isEmpty || busy || !session.connection.isConnected)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let skill = current {
            SkillDetail(skill: skill, onEdit: { editing = skill }, onToggle: { toggle(skill) }, onDelete: { delete(skill) }, onReimport: { reimport(skill) },
                        versions: versions(of: skill), onSelectVersion: { selected = $0 }, onDeleteOlder: { deleteOlder(than: skill) },
                        onRestore: { old in Task { await restore(old) } })
        } else {
            EmptyState(title: "Pick a skill", message: "Steps, checks, and the evidence behind each procedure show up here.")
        }
    }

    // MARK: Actions

    private func togglePick(_ skill: Skill) {
        let ids = versions(of: skill).map(\.id)
        if picked.contains(skill.id) { picked.subtract(ids) } else { picked.formUnion(ids) }
    }

    /// Deletes every version of this skill except the newest (built-in skills stay).
    private func deleteOlder(than skill: Skill) {
        let all = versions(of: skill)
        guard let newest = all.first else { return }
        let ids = all.dropFirst().filter { $0.origin != "builtin" }.map(\.id)
        guard !ids.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await session.deleteSkills(ids)
                selected = newest
            } catch { self.error = String(describing: error) }
        }
    }

    private func exitSelection() {
        selecting = false
        picked = []
    }

    /// What "enabled" means for a skill: validated once it has enough wins, provisional otherwise.
    private func enabledStatus(for skill: Skill) -> SkillStatus {
        skill.outcomes.filter(\.succeeded).count >= 3 ? .validated : .provisional
    }

    private func toggle(_ skill: Skill) { setStatus([skill], enabled: skill.status == .disabled) }

    private func setStatus(_ targets: [Skill], enabled: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                for s in targets {
                    let next: SkillStatus = enabled ? enabledStatus(for: s) : .disabled
                    if enabled, s.status != .disabled { continue }
                    if !enabled, s.status == .disabled { continue }
                    _ = try await session.send(.setSkillStatus(s.id, next))
                }
                try await session.loadSkills()
            } catch { self.error = String(describing: error) }
        }
    }

    private func delete(_ skill: Skill) {
        Task {
            do { _ = try await session.send(.deleteSkill(skill.id)); selected = nil; try await session.loadSkills() } catch { self.error = String(describing: error) }
        }
    }

    private func bulkDelete() {
        let ids = deletable.map(\.id)
        guard !ids.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await session.deleteSkills(ids)
                if let s = selected, ids.contains(s.id) { selected = nil }
                picked.subtract(ids)
            } catch { self.error = String(describing: error) }
        }
    }

    /// Opens the import sheet on the folder an imported skill came from, focused on that skill.
    private func reimport(_ skill: Skill) {
        guard let source = skill.sourcePath else { return }
        let folder = (source as NSString).lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame
            ? (source as NSString).deletingLastPathComponent : source
        importRequest = SkillImportRequest(path: folder, focus: skill.name)
    }

    /// Going back to an earlier version saves a copy of it as the newest, so agents pick it up and the history
    /// keeps every step.
    private func restore(_ old: Skill) async {
        guard let newest = versions(of: old).max(by: { $0.version < $1.version }), newest.id != old.id else { return }
        var copy = old
        copy.id = SkillID()
        copy.version = newest.version + 1
        copy.previousVersionID = newest.id
        copy.createdAt = Date()
        copy.outcomes = []
        await save(copy, select: true)
    }

    private func save(_ skill: Skill, select: Bool = false) async {
        var s = skill
        s.updatedAt = Date()
        do {
            _ = try await session.send(.updateSkill(s))
            try await session.loadSkills()
            if select { selected = s }
        } catch { self.error = String(describing: error) }
    }
}

// MARK: - Presentation

/// How a skill is named and pictured in the interface.
enum SkillPresentation {
    /// "inbox-drafts" → "Inbox drafts". Names already written for people (spaces or capitals) stay as they are.
    static func title(_ name: String) -> String {
        guard !name.contains(" "), name == name.lowercased(), name.contains(where: { $0 == "-" || $0 == "_" }) else { return name }
        let words = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word -> String in
            let w = String(word)
            if let proper = properNames[w] { return proper }
            return acronyms.contains(w) ? w.uppercased() : w
        }
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    private static let acronyms: Set<String> = ["sre", "api", "ai", "ui", "ux", "cli", "mcp", "pr", "ci", "cd", "qa", "seo", "crm", "sql", "aws", "gcp", "llm", "pdf", "csv", "ssh", "dns", "cdn", "hr"]
    private static let properNames: [String: String] = ["linkedin": "LinkedIn", "youtube": "YouTube", "github": "GitHub", "gitlab": "GitLab", "hubspot": "HubSpot", "macos": "macOS", "ios": "iOS", "iphone": "iPhone", "chatgpt": "ChatGPT", "openai": "OpenAI", "outlook": "Outlook", "slack": "Slack", "notion": "Notion"]

    /// A job symbol for the skill, found the same way as an agent's flag; built-ins get a toolbox.
    static func glyph(for skill: Skill) -> AgentGlyph {
        if let g = AgentGlyph.guess(name: title(skill.name), role: skill.purpose) { return g }
        switch skill.origin {
        case "builtin": return .wrench
        case "taught": return .camera
        default: return .sparkle
        }
    }

    static func origin(_ skill: Skill, agentName: String?) -> String {
        switch skill.origin {
        case "builtin": return "Built in"
        case "imported": return "Imported"
        case "taught": return "Taught by you"
        case "learned": return agentName.map { "Learned by \($0)" } ?? "Learned"
        default: return skill.origin.capitalized
        }
    }
}

/// A skill's picture: its job symbol on a quiet tile. Turned-off skills fade.
struct SkillTile: View {
    var skill: Skill
    var size: CGFloat = 36
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(PennantTheme.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(PennantTheme.border))
            .overlay {
                Image(systemName: SkillPresentation.glyph(for: skill).symbol)
                    .font(.zoomed(size: size * 0.42, weight: .medium))
                    .foregroundStyle(PennantTheme.inkSecondary)
            }
            .frame(width: size, height: size)
            .opacity(skill.status == .disabled ? 0.5 : 1)
            .accessibilityHidden(true)
    }
}

struct SkillRow: View {
    var skill: Skill
    /// How many versions of this skill exist (the row shows the newest).
    var versionCount = 1
    /// Times used, across its versions.
    var uses = 0
    var body: some View {
        HStack(spacing: 12) {
            SkillTile(skill: skill)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SkillPresentation.title(skill.name)).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if skill.status == .provisional {
                        Text("Provisional").font(.zoomed(.caption2).weight(.semibold)).foregroundStyle(PennantTheme.warning)
                    }
                    if uses > 0 {
                        Text("\(uses) use\(uses == 1 ? "" : "s")").font(.zoomed(.caption2).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    if versionCount > 1 {
                        Text("v\(skill.version)").font(.zoomed(.caption2).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
                    }
                }
                if !skill.purpose.isEmpty {
                    Text(skill.purpose).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                }
            }
        }
        .opacity(skill.status == .disabled ? 0.6 : 1)
    }
}

// MARK: - Detail

struct SkillDetail: View {
    @Environment(\.hostSession) private var session
    var skill: Skill
    var onEdit: () -> Void
    var onToggle: () -> Void
    var onDelete: () -> Void
    /// Re-import from the folder the skill came from; only imported skills with a source path offer it.
    var onReimport: (() -> Void)? = nil
    /// Every version of this skill, newest first; `skill` may be an older one the user opened.
    var versions: [Skill] = []
    var onSelectVersion: ((Skill) -> Void)? = nil
    var onDeleteOlder: (() -> Void)? = nil
    /// Makes this (older) version the one agents use, as a new version.
    var onRestore: ((Skill) -> Void)? = nil
    @State private var confirmDelete = false
    @State private var showChanges = false
    @State private var confirmDeleteOlder = false
    @State private var openScripts: Set<String> = []

    private var title: String { SkillPresentation.title(skill.name) }
    private var versionIDs: Set<SkillID> { Set((versions.isEmpty ? [skill] : versions).map(\.id)) }
    /// Scheduled jobs that run this skill (any version).
    private var schedules: [ScheduledJob] { session.state.schedules.filter { $0.skillID.map { versionIDs.contains($0) } ?? false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let newest = versions.first, newest.id != skill.id { olderBanner(newest) }
                facts
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        mainColumn.frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)
                        if hasSide { sideColumn.frame(width: 280) }
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        mainColumn
                        if hasSide { sideColumn }
                    }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            .padding(16)
            #else
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            #endif
        }
        .confirmationDialog("Delete this skill?", isPresented: $confirmDelete) {
            Button("Delete \"\(title)\"", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Agents will no longer find or use it.") }
        .confirmationDialog("Delete the older versions?", isPresented: $confirmDeleteOlder) {
            Button("Delete \(versions.count - 1) older version\(versions.count == 2 ? "" : "s")", role: .destructive) { onDeleteOlder?() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Agents always use the newest version, v\(versions.first?.version ?? skill.version). Older versions only keep the history.") }
    }

    // MARK: Header and facts

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            SkillTile(skill: skill, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.zoomed(.title2).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                if title != skill.name {
                    Text(skill.name).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkTertiary).textSelection(.enabled)
                }
                if !skill.purpose.isEmpty {
                    Text(skill.purpose).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Toggle("On", isOn: Binding(get: { skill.status != .disabled }, set: { _ in onToggle() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(skill.status == .disabled ? "Turned off: agents don't see it" : "On: agents can find and use it")
                Button("Edit", action: onEdit).buttonStyle(.pennantCompact).fixedSize()
                Menu {
                    if skill.origin == "imported", skill.sourcePath != nil, let onReimport {
                        Button("Re-import from its folder", action: onReimport)
                    }
                    if onDeleteOlder != nil, versions.count > 1, versions.dropFirst().contains(where: { $0.origin != "builtin" }) {
                        Button("Delete older versions…") { confirmDeleteOlder = true }
                    }
                    if skill.origin != "builtin" {
                        Divider()
                        Button("Delete skill…", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .menuStyle(.button)
                .buttonStyle(.pennantIcon)
                .fixedSize()
                .accessibilityLabel("More actions")
            }
        }
    }

    private var facts: some View {
        let wins = skill.outcomes.filter(\.succeeded).count
        let runs = skill.outcomes.count
        let agentName = skill.createdByAgentID.flatMap { session.state.agent($0)?.name }
        return FlowLayout(spacing: 10) {
            fact("Status") {
                HStack(spacing: 5) {
                    Circle().fill(SkillOriginStyle.statusColor(skill.status)).frame(width: 7, height: 7)
                    Text(skill.status == .disabled ? "Turned off" : SkillOriginStyle.statusTitle(skill.status))
                }
            }
            fact("Version") { Text("v\(skill.version)") }
            fact("Runs") { Text(runs == 0 ? "None yet" : "\(runs) · \(Int((Double(wins) / Double(runs) * 100).rounded()))% succeeded") }
            if let last = skill.outcomes.map(\.at).max() { fact("Last run") { Text(relativeTime(last)) } }
            fact("Origin") { Text(SkillPresentation.origin(skill, agentName: agentName)) }
        }
    }

    private func fact<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            value().font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
    }

    private func olderBanner(_ newest: Skill) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(PennantTheme.warning)
            Text("You're looking at v\(skill.version), an older version. Agents use v\(newest.version).")
                .font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onRestore { Button("Use this version") { onRestore(skill) }.buttonStyle(.pennantPrimaryCompact).fixedSize() }
            Button("Show newest") { onSelectVersion?(newest) }.buttonStyle(.pennantCompact).fixedSize()
        }
        .padding(10)
        .background(PennantTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
    }

    // MARK: Main column: what the skill does

    /// The version this one replaced.
    private var predecessor: Skill? { versions.filter { $0.version < skill.version }.max { $0.version < $1.version } }

    @ViewBuilder private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showChanges, let before = predecessor {
                section("Changes from v\(before.version)") { SkillDiffView(old: before, new: skill) }
            }
            if !skill.applicability.isEmpty { section("When to use") { prose(skill.applicability) } }
            if !skill.steps.isEmpty { section("Steps") { steps } }
            if skill.steps.isEmpty, !skill.body.isEmpty { section("Instructions") { PennantMarkdown(skill.body).textSelection(.enabled) } }
            if skill.steps.isEmpty, skill.body.isEmpty {
                Text("This skill has no steps recorded yet.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            }
            if !skill.expectedResult.isEmpty { section("Expected result") { prose(skill.expectedResult) } }
            if !skill.prerequisites.isEmpty { section("Prerequisites") { bullets(skill.prerequisites) } }
            if !skill.inputs.isEmpty { section("Inputs") { bullets(skill.inputs) } }
            if !skill.failureConditions.isEmpty { section("When it fails") { bullets(skill.failureConditions, symbol: "exclamationmark.triangle") } }
        }
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.zoomed(.subheadline).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prose(_ text: String) -> some View {
        Text(text).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func bullets(_ items: [String], symbol: String = "circle.fill") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.zoomed(size: symbol == "circle.fill" ? 5 : 11))
                        .foregroundStyle(PennantTheme.inkTertiary)
                        .frame(width: 12)
                    Text(item).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Numbered steps joined by a thin line, each with its check and tool underneath.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(skill.steps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.zoomed(.caption).weight(.semibold).monospacedDigit())
                        .foregroundStyle(PennantTheme.ink)
                        .frame(width: 24, height: 24)
                        .background(PennantTheme.cardBackground, in: Circle())
                        .overlay(Circle().strokeBorder(PennantTheme.border))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.instruction).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                        if !step.check.isEmpty {
                            Label(step.check, systemImage: "checkmark.circle")
                                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if step.tool != nil || step.uncertain {
                            HStack(spacing: 4) {
                                if let tool = step.tool { Chip(tool, color: PennantTheme.info) }
                                if step.uncertain { Chip("uncertain", color: PennantTheme.warning) }
                            }
                        }
                    }
                    .padding(.bottom, i < skill.steps.count - 1 ? 14 : 0)
                }
                .background(alignment: .topLeading) {
                    if i < skill.steps.count - 1 {
                        Rectangle().fill(PennantTheme.border).frame(width: 1).padding(.top, 24).offset(x: 11.5)
                    }
                }
            }
        }
    }

    // MARK: Side column: what it produces, where it runs, its history

    private var hasSide: Bool {
        (skill.outputs.map { !$0.isEmpty } ?? false) || !schedules.isEmpty || !skill.scripts.isEmpty
            || versions.count > 1 || !skill.outcomes.isEmpty || skill.sourcePath != nil
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let outputs = skill.outputs, !outputs.isEmpty { side("Produces") { produces(outputs) } }
            if !schedules.isEmpty {
                side("Runs on a schedule") {
                    ForEach(schedules) { job in
                        HStack(spacing: 8) {
                            if let agent = session.state.agent(job.agentID) { AgentAvatar(agent: agent, size: 20) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(scheduleLabel(job.name)).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                                Text(SchedulePhrasing.summary(for: job.schedule, timeZone: job.timeZone).text)
                                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if !skill.scripts.isEmpty { side("Scripts") { scripts } }
            if versions.count > 1 { side("Versions") { versionList } }
            if !skill.outcomes.isEmpty { side("Recent runs") { recentRuns } }
            if let path = skill.sourcePath {
                side("Folder") {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkSecondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PennantTheme.cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
    }

    private func side<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkTertiary)
            content()
        }
    }

    private func produces(_ o: SkillOutputs) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = o.report {
                Label { VStack(alignment: .leading, spacing: 1) {
                    Text("A report card").font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                    Text(r.title).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                } } icon: { Image(systemName: "doc.text").foregroundStyle(PennantTheme.info) }
            }
            if let a = o.approval {
                Label { VStack(alignment: .leading, spacing: 1) {
                    Text("An approval before it goes out").font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                    Text(a.destination + (a.label.map { " · \($0)" } ?? "")).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                } } icon: { Image(systemName: "checkmark.seal").foregroundStyle(PennantTheme.color(for: AgentStatus.waitingForUser)) }
            }
        }
    }

    private var scripts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(skill.scripts.keys.sorted(), id: \.self) { name in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if openScripts.contains(name) { openScripts.remove(name) } else { openScripts.insert(name) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.zoomed(.caption2).weight(.semibold))
                                .rotationEffect(.degrees(openScripts.contains(name) ? 90 : 0))
                                .foregroundStyle(PennantTheme.inkTertiary)
                            Text(name).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.ink).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if openScripts.contains(name) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(skill.scripts[name] ?? "")
                                .font(.zoomed(.caption2).monospaced())
                                .foregroundStyle(PennantTheme.ink)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .background(PennantTheme.windowBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                    }
                }
            }
        }
    }

    private var versionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(versions.enumerated()), id: \.element.id) { index, v in
                Button { onSelectVersion?(v) } label: {
                    HStack(spacing: 8) {
                        Text("v\(v.version)").font(.zoomed(.callout).weight(.semibold).monospacedDigit()).foregroundStyle(PennantTheme.ink).frame(width: 34, alignment: .leading)
                        Text(index == 0 ? "In use" : v.updatedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.zoomed(.caption)).foregroundStyle(index == 0 ? PennantTheme.brandInk : PennantTheme.inkSecondary)
                        Spacer(minLength: 4)
                        if v.id == skill.id { Image(systemName: "eye").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let before = predecessor {
                Button(showChanges ? "Hide changes" : "Show changes from v\(before.version)") { withAnimation(.snappy) { showChanges.toggle() } }
                    .buttonStyle(.pennantGhostCompact)
                    .padding(.top, 4)
            }
        }
    }

    private var recentRuns: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(skill.outcomes.suffix(5).reversed().enumerated()), id: \.offset) { _, o in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: o.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.zoomed(.caption))
                        .foregroundStyle(o.succeeded ? PennantTheme.success : PennantTheme.danger)
                    Text(o.note.isEmpty ? (o.succeeded ? "Succeeded" : "Failed") : o.note).font(.zoomed(.caption)).foregroundStyle(PennantTheme.ink).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(relativeTime(o.at)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
                }
            }
        }
    }
}

// MARK: - Editor

struct SkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var skill: Skill
    var isNew: Bool
    var onSave: (Skill) -> Void

    init(skill: Skill, isNew: Bool = false, onSave: @escaping (Skill) -> Void) {
        _skill = State(initialValue: skill)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var canSave: Bool { !skill.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            PaneHeader(isNew ? "New skill" : "Edit skill")
            Divider().overlay(PennantTheme.divider)
            content
            Divider().overlay(PennantTheme.divider)
            footer
        }
        .background(PennantTheme.windowBackground)
        .frame(minWidth: 540, minHeight: 600)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                content
                Divider().overlay(PennantTheme.divider)
                footer
            }
            .background(PennantTheme.windowBackground)
            .navigationTitle(isNew ? "New skill" : "Edit skill")
            .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PennantTextField("Name", placeholder: "File the monthly invoices", text: $skill.name)
                PennantTextField("Purpose", placeholder: "One line on what this achieves", text: $skill.purpose, lines: 1 ... 3)
                PennantTextField("When to use", placeholder: "The situation that calls for it", text: $skill.applicability, lines: 1 ... 3)
                PennantTextField("Expected result", placeholder: "What is true when it worked", text: $skill.expectedResult, lines: 1 ... 3)
                steps
                PennantTextField("Prerequisites", placeholder: "One per line", text: lines($skill.prerequisites), lines: 2 ... 6)
                PennantTextField("Failure conditions", placeholder: "One per line", text: lines($skill.failureConditions), lines: 2 ... 6)
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Steps")
            ForEach(Array($skill.steps.enumerated()), id: \.element.id) { i, $step in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Step \(i + 1)").font(.zoomed(.subheadline).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        Spacer(minLength: 0)
                        Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.pennantIcon).disabled(i == 0).help("Move up")
                        Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.pennantIcon).disabled(i == skill.steps.count - 1).help("Move down")
                        Button("Remove") { skill.steps.remove(at: i) }.buttonStyle(.pennantCompact)
                    }
                    PennantTextField(placeholder: "What to do", text: $step.instruction, lines: 1 ... 3)
                    PennantTextField("Check", placeholder: "How to tell it worked", text: $step.check)
                    Toggle(isOn: $step.uncertain) {
                        Text("Revalidate before trusting").font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(PennantTheme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(elevated: true)
            }
            Button("Add step", systemImage: "plus") { skill.steps.append(SkillStep(instruction: "")) }
                .buttonStyle(.pennantCompact)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost)
            Spacer()
            Button(isNew ? "Create skill" : "Save changes") { onSave(skill); dismiss() }
                .buttonStyle(.pennantPrimary)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard skill.steps.indices.contains(target) else { return }
        skill.steps.swapAt(index, target)
    }

    private func lines(_ items: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { items.wrappedValue.joined(separator: "\n") },
            set: { items.wrappedValue = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        )
    }
}

// MARK: - Version diff

/// What changed between two versions of a skill, line by line: removed lines struck in red, added in green.
struct SkillDiffView: View {
    var old: Skill
    var new: Skill

    var body: some View {
        let lines = SkillDiff.lines(from: SkillDiff.text(old), to: SkillDiff.text(new)).filter { $0.kind != .same }
        if lines.isEmpty {
            Text("No changes to the instructions; only the details around them.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.kind == .added ? "+" : "−").font(.zoomed(.callout).monospaced().weight(.semibold))
                        Text(line.text).font(.zoomed(.callout)).fixedSize(horizontal: false, vertical: true)
                            .strikethrough(line.kind == .removed, color: PennantTheme.danger.opacity(0.6))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(line.kind == .added ? Color(hex: "#1F8636") : PennantTheme.danger)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background((line.kind == .added ? PennantTheme.success : PennantTheme.danger).opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .textSelection(.enabled)
        }
    }
}

enum SkillDiff {
    enum Kind { case same, added, removed }
    struct Line { var kind: Kind; var text: String }

    /// A skill as the lines a person would compare.
    static func text(_ s: Skill) -> [String] {
        var out: [String] = []
        if !s.purpose.isEmpty { out.append("Purpose: " + s.purpose) }
        if !s.applicability.isEmpty { out.append("When to use: " + s.applicability) }
        out += s.steps.enumerated().map { "\($0.offset + 1). " + $0.element.instruction }
        out += s.body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !s.expectedResult.isEmpty { out.append("Expected result: " + s.expectedResult) }
        out += s.prerequisites.map { "Needs: " + $0 }
        out += s.inputs.map { "Input: " + $0 }
        out += s.failureConditions.map { "Fails when: " + $0 }
        return out
    }

    /// Longest-common-subsequence diff; skills are short enough for the plain table.
    static func lines(from a: [String], to b: [String]) -> [Line] {
        let n = a.count, m = b.count
        var t = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: [Line] = [], i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { out.append(Line(kind: .same, text: a[i])); i += 1; j += 1 }
            // On a tie the old line goes first, so a replaced line reads as "− old, + new".
            else if i < n, j == m || t[i + 1][j] >= t[i][j + 1] { out.append(Line(kind: .removed, text: a[i])); i += 1 }
            else { out.append(Line(kind: .added, text: b[j])); j += 1 }
        }
        return out
    }
}
