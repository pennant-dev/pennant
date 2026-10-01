import PennantClientKit
import PennantCore
import SwiftUI

// MARK: - Request

/// What the Skills pane asks the import sheet to open with: nothing (browse), or a folder to preview
/// and a skill name to focus on (Re-import from the detail pane).
struct SkillImportRequest: Identifiable {
    let id = UUID()
    var path: String?
    var focus: String?
    init(path: String? = nil, focus: String? = nil) { self.path = path; self.focus = focus }
}

/// Client-side twin of the host's git detection, so the sheet can say "Cloning…" before the host replies.
func skillSourceIsGitURL(_ path: String) -> Bool {
    let p = path.trimmingCharacters(in: .whitespaces).lowercased()
    return p.hasPrefix("http://") || p.hasPrefix("https://") || p.hasPrefix("ssh://") || p.hasPrefix("git@") || p.hasPrefix("git://") || p.hasSuffix(".git")
}

/// "skills" for https://github.com/anthropics/skills.git; the last path component without .git.
func skillRepoName(_ origin: String) -> String {
    var name = origin.split(separator: "/").last.map(String.init) ?? origin
    if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
    if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
    return name.isEmpty ? origin : name
}

// MARK: - Sheet

/// Import skills in three steps on one sheet: pick a source (a harness folder, one of your folders, or a git
/// repository), tick the skills you want from what the host found there, then import them.
struct SkillImportSheet: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    var request: SkillImportRequest

    // Step 1: source
    @State private var locations: [SkillLocation] = []
    @State private var scanning = false
    @State private var started = false
    @State private var selectedPath: String?
    @State private var folderPath = ""
    @State private var gitURL = ""
    @State private var addingFolder = false
    @State private var confirmForget: SkillLocation?

    // Step 2: choose
    @State private var preview: SkillImportPreview?
    @State private var previewStatus: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var checked: Set<String> = []
    @State private var filter = ""
    @State private var focus: String?

    // Step 3: import
    @State private var importing = false
    @State private var imported: [Skill]?
    @State private var importWarnings: [String] = []
    @State private var error: String?

    init(request: SkillImportRequest = SkillImportRequest()) {
        self.request = request
        _focus = State(initialValue: request.focus)
    }

    private var connected: Bool { session.connection.isConnected }
    private var checkedCount: Int { preview.map { p in p.items.filter { checked.contains($0.sourcePath) }.count } ?? 0 }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            PaneHeader("Import skills")
            Divider().overlay(PennantTheme.divider)
            content
            Divider().overlay(PennantTheme.divider)
            footer
        }
        .background(PennantTheme.windowBackground)
        .frame(minWidth: 600, idealWidth: 640, minHeight: 620, idealHeight: 720)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                content
                Divider().overlay(PennantTheme.divider)
                footer
            }
            .background(PennantTheme.windowBackground)
            .navigationTitle("Import skills")
            .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sourceStep.zIndex(1) // the git field's suggestions drop over the step below
                chooseStep
                importStep
                if let error {
                    Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .task { start() }
        .confirmationDialog(
            "Forget this repository?",
            isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }),
            presenting: confirmForget
        ) { loc in
            Button("Forget \(skillRepoName(loc.origin ?? loc.path))", role: .destructive) { remove(loc) }
            Button("Cancel", role: .cancel) {}
        } message: { loc in
            Text("Pennant stops listing \(loc.origin ?? loc.path). The checkout stays at \((loc.path as NSString).abbreviatingWithTildeInPath), and skills you already imported are unaffected.")
        }
    }

    private func stepHeader(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.zoomed(.caption).weight(.semibold).monospacedDigit())
                .foregroundStyle(PennantTheme.inkSecondary)
                .frame(width: 22, height: 22)
                .background(PennantTheme.fieldBackground, in: Circle())
            Text(title).font(.zoomed(.subheadline).weight(.semibold)).foregroundStyle(PennantTheme.ink)
        }
    }

    // MARK: Step 1: source

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stepHeader(1, "Source")
                Spacer(minLength: 0)
                if scanning { ProgressView().controlSize(.small) }
                Button("Rescan") { scan() }
                    .buttonStyle(.pennantGhostCompact)
                    .disabled(scanning || !connected)
            }
            if locations.isEmpty {
                Text(scanning ? "Looking for skill folders from Claude Code, Codex, Cursor and similar tools…"
                    : (connected ? "No skill folders found yet. Add one below, or paste a git repository." : "Connect to the host to look for skill folders."))
                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                SkillSourceList(
                    locations: locations,
                    selectedPath: selectedPath,
                    busyPath: previewStatus == nil ? nil : selectedPath,
                    onSelect: { select($0) },
                    onRemove: { loc in if loc.kind == "git" { confirmForget = loc } else { remove(loc) } }
                )
            }
            addFolderField
            addGitField
        }
    }

    private var addFolderField: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(macOS)
            HStack(alignment: .bottom, spacing: 8) {
                PathField("Add folder…", path: $folderPath, directories: true, placeholder: "A skills folder anywhere on this Mac…")
                if addingFolder { ProgressView().controlSize(.small).padding(.bottom, 10) }
            }
            .onChange(of: folderPath) { _, p in if !p.trimmingCharacters(in: .whitespaces).isEmpty { addFolder(p) } }
            #else
            HStack(alignment: .bottom, spacing: 8) {
                PennantTextField("Add folder…", placeholder: "~/.claude/skills", text: $folderPath)
                    .onSubmit { addFolder(folderPath) }
                Button("Add") { addFolder(folderPath) }
                    .buttonStyle(.pennantCompact)
                    .disabled(folderPath.trimmingCharacters(in: .whitespaces).isEmpty || addingFolder || !connected)
                    .padding(.bottom, 2)
            }
            #endif
            Text("Pennant remembers the folder and lists it here from now on.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
        .disabled(!connected)
    }

    private var addGitField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                AutocompleteField("Add git repository", placeholder: "https://github.com/you/skills or git@host:you/skills.git", text: $gitURL, suggestions: gitSuggestions) { addGit($0.value) }
                    .onSubmit { addGit(gitURL) }
                Button("Add") { addGit(gitURL) }
                    .buttonStyle(.pennantCompact)
                    .disabled(gitURL.trimmingCharacters(in: .whitespaces).isEmpty || previewStatus != nil || !connected)
                    .padding(.bottom, 2)
            }
            Text("Cloned on the host and kept as a source; selecting it later pulls the latest.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
        .disabled(!connected)
    }

    private static let exampleRepos: [(url: String, note: String)] = [
        ("https://github.com/anthropics/skills", "Anthropic's public Agent Skills"),
        ("https://github.com/obra/superpowers", "Community skills library"),
    ]

    private func gitSuggestions(_ text: String) -> [ChoiceOption<String>] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        var out: [ChoiceOption<String>] = []
        for loc in locations where loc.kind == "git" {
            guard let origin = loc.origin, seen.insert(origin).inserted else { continue }
            out.append(ChoiceOption(origin, title: origin, subtitle: "Already cloned · \(loc.skillCount) skill\(loc.skillCount == 1 ? "" : "s")", symbol: "arrow.triangle.branch"))
        }
        for example in Self.exampleRepos where seen.insert(example.url).inserted {
            out.append(ChoiceOption(example.url, title: example.url, subtitle: example.note, symbol: "globe"))
        }
        guard !q.isEmpty else { return out }
        return out.filter { $0.title.lowercased().contains(q) }
    }

    // MARK: Step 2: choose

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stepHeader(2, "Choose")
                Spacer(minLength: 0)
                if let previewStatus {
                    ProgressView().controlSize(.small)
                    Text(previewStatus).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                } else if let preview, !preview.items.isEmpty {
                    Text("\(checkedCount) of \(preview.items.count) selected").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                }
            }
            if let preview {
                SkillImportChooser(items: preview.items, warnings: preview.warnings, checked: $checked, filter: $filter)
            } else if previewStatus == nil {
                Text("Pick a source above to see the skills it holds.")
                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: Step 3: import

    @ViewBuilder private var importStep: some View {
        if let preview, !preview.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                stepHeader(3, "Import")
                if let imported {
                    SkillImportResults(imported: imported, warnings: importWarnings)
                } else {
                    Text(importSummary(preview))
                        .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func importSummary(_ preview: SkillImportPreview) -> String {
        let picked = preview.items.filter { checked.contains($0.sourcePath) }
        guard !picked.isEmpty else { return "Nothing selected. Tick the skills to bring into your library." }
        let fresh = picked.filter { $0.existingVersion == nil }.count
        let updates = picked.filter { $0.existingVersion != nil && !$0.unchanged }.count
        let same = picked.filter(\.unchanged).count
        var parts: [String] = []
        if fresh > 0 { parts.append("\(fresh) new") }
        if updates > 0 { parts.append("\(updates) updated to a new version") }
        if same > 0 { parts.append("\(same) unchanged (skipped)") }
        return parts.joined(separator: ", ") + ". Imported skills are validated and ready for agents to use."
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(imported == nil ? "Cancel" : "Done") { previewTask?.cancel(); dismiss() }.buttonStyle(.pennantGhost)
            Spacer()
            if importing { ProgressView().controlSize(.small) }
            Button(checkedCount == 0 ? "Import" : "Import \(checkedCount) skill\(checkedCount == 1 ? "" : "s")") { runImport() }
                .buttonStyle(.pennantPrimary)
                .disabled(checkedCount == 0 || importing || previewStatus != nil || !connected)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func start() {
        guard !started else { return }
        started = true
        guard connected else { return }
        Task {
            await scanNow()
            if let path = request.path {
                if let loc = locations.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                    select(loc)
                } else {
                    selectedPath = path
                    runPreview(path, status: "Scanning…")
                }
            } else if locations.count == 1 {
                select(locations[0])
            }
        }
    }

    private func scan() { Task { await scanNow() } }

    private func scanNow() async {
        scanning = true
        defer { scanning = false }
        do { locations = try await session.scanSkillLocations() } catch { self.error = String(describing: error) }
    }

    private func select(_ loc: SkillLocation) {
        selectedPath = loc.path
        if loc.kind == "git", let origin = loc.origin {
            runPreview(origin, status: "Pulling…", fallback: loc.path)
        } else {
            runPreview(loc.path, status: "Scanning…")
        }
    }

    /// Asks the host what it would import from `source`. A git URL is cloned or pulled first; when that fails
    /// and `fallback` names the checkout on disk, the sheet shows that copy instead.
    private func runPreview(_ source: String, status: String, fallback: String? = nil, keepResults: Bool = false) {
        previewTask?.cancel()
        if !keepResults {
            // A fresh source: clear the old list and results. A post-import refresh keeps them on screen until the new list lands.
            preview = nil
            checked = []
            imported = nil
            importWarnings = []
        }
        error = nil
        previewStatus = status
        previewTask = Task {
            do {
                let p = try await session.previewSkillImport(path: source)
                guard !Task.isCancelled else { return }
                apply(p)
                if skillSourceIsGitURL(source) {
                    gitURL = ""
                    await scanNow()
                    selectedPath = locations.first { $0.path == p.root }?.path ?? p.root
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let fallback {
                    self.error = "Couldn't pull \(source): \(error). Showing the copy on disk."
                    do {
                        let p = try await session.previewSkillImport(path: fallback)
                        guard !Task.isCancelled else { return }
                        apply(p)
                    } catch { self.error = String(describing: error); previewStatus = nil }
                } else {
                    self.error = String(describing: error)
                    previewStatus = nil
                }
            }
        }
    }

    private func apply(_ p: SkillImportPreview) {
        preview = p
        previewStatus = nil
        if let focus, p.items.contains(where: { $0.name.caseInsensitiveCompare(focus) == .orderedSame }) {
            checked = Set(p.items.filter { $0.name.caseInsensitiveCompare(focus) == .orderedSame }.map(\.sourcePath))
            filter = focus
        } else {
            checked = Set(p.items.filter { !$0.unchanged }.map(\.sourcePath))
        }
        focus = nil
    }

    private func addFolder(_ raw: String) {
        let path = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty, !addingFolder else { return }
        addingFolder = true
        error = nil
        Task {
            defer { addingFolder = false }
            do {
                locations = try await session.addSkillFolder(path)
                folderPath = ""
                let standard = (path as NSString).standardizingPath
                if let loc = locations.first(where: { $0.path == path || ($0.path as NSString).standardizingPath == standard }) {
                    select(loc)
                } else {
                    selectedPath = path
                    runPreview(path, status: "Scanning…")
                }
            } catch { self.error = String(describing: error) }
        }
    }

    private func addGit(_ raw: String) {
        let url = raw.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, previewStatus == nil else { return }
        if let loc = locations.first(where: { $0.origin == url }) { select(loc); return }
        selectedPath = nil
        runPreview(url, status: "Cloning…")
    }

    private func remove(_ loc: SkillLocation) {
        error = nil
        Task {
            do {
                locations = try await session.removeSkillFolder(loc.path)
                if selectedPath == loc.path {
                    previewTask?.cancel()
                    selectedPath = nil
                    preview = nil
                    previewStatus = nil
                    checked = []
                }
            } catch { self.error = String(describing: error) }
        }
    }

    private func runImport() {
        guard let preview, !importing else { return }
        let only = preview.items.map(\.sourcePath).filter { checked.contains($0) }
        guard !only.isEmpty else { return }
        importing = true
        error = nil
        Task {
            defer { importing = false }
            do {
                let (skills, warns) = try await session.importSkills(path: preview.root, only: only)
                imported = skills
                importWarnings = warns
                try? await session.loadSkills()
                // Refresh the checklist so chips read "Unchanged" for what just landed.
                runPreview(preview.root, status: "Refreshing…", keepResults: true)
            } catch { self.error = String(describing: error) }
        }
    }
}

// MARK: - Source list

/// The locations the host knows: harness folders, folders you added, and cloned repositories.
struct SkillSourceList: View {
    var locations: [SkillLocation]
    var selectedPath: String?
    var busyPath: String?
    var onSelect: (SkillLocation) -> Void
    var onRemove: (SkillLocation) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(locations) { loc in
                SelectableRow(selected: selectedPath == loc.path, action: { onSelect(loc) }) {
                    SkillLocationRow(location: loc, selected: selectedPath == loc.path, busy: busyPath == loc.path,
                                     onRemove: loc.kind == "known" ? nil : { onRemove(loc) })
                }
            }
        }
        .padding(4)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
    }
}

struct SkillLocationRow: View {
    var location: SkillLocation
    var selected: Bool
    var busy: Bool
    var onRemove: (() -> Void)?

    private var isGit: Bool { location.kind == "git" }
    private var isCustom: Bool { location.kind == "custom" }

    private var title: String {
        switch location.kind {
        case "git": return skillRepoName(location.origin ?? location.path)
        case "custom": return (location.path as NSString).lastPathComponent
        default: return location.harness
        }
    }

    private var subtitle: String {
        isGit ? (location.origin ?? location.path) : (location.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isGit ? "arrow.triangle.branch" : "folder")
                .foregroundStyle(selected ? PennantTheme.ink : PennantTheme.inkSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    if isGit { Chip("Git", color: Color(hex: "#8B5CF6")) } else if isCustom { Chip("Your folder", color: Color(hex: "#1FA79E")) }
                }
                Text(subtitle)
                    .font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Chip("\(location.skillCount) skill\(location.skillCount == 1 ? "" : "s")")
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help(isGit ? "Forget this repository" : "Remove this folder")
                    .accessibilityLabel(isGit ? "Forget repository" : "Remove folder")
            }
        }
    }
}

// MARK: - Chooser

/// The checklist of what a source holds. Unchanged skills start unticked; everything else starts ticked.
struct SkillImportChooser: View {
    var items: [SkillPreviewItem]
    var warnings: [String]
    @Binding var checked: Set<String>
    @Binding var filter: String

    private var showsFilter: Bool { items.count > 8 || !filter.isEmpty }

    private var visible: [SkillPreviewItem] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(q) || $0.purpose.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                HStack(spacing: 8) {
                    if showsFilter { SearchField("Filter skills", text: $filter) }
                    Spacer(minLength: 0)
                    Button("Select all") { checked.formUnion(visible.map(\.sourcePath)) }
                        .buttonStyle(.pennantGhostCompact)
                        .disabled(visible.allSatisfy { checked.contains($0.sourcePath) })
                    Button("None") { checked.subtract(visible.map(\.sourcePath)) }
                        .buttonStyle(.pennantGhostCompact)
                        .disabled(!visible.contains { checked.contains($0.sourcePath) })
                }
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { i, item in
                        SkillPreviewRow(item: item, checked: binding(for: item))
                        if i < visible.count - 1 { Divider().overlay(PennantTheme.divider).padding(.leading, 36) }
                    }
                    if visible.isEmpty {
                        Text("No skills match \"\(filter)\".")
                            .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .padding(4)
                .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
            } else if warnings.isEmpty {
                Text("No SKILL.md files found here.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            }
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(PennantTheme.warning)
                    Text(w).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func binding(for item: SkillPreviewItem) -> Binding<Bool> {
        Binding(
            get: { checked.contains(item.sourcePath) },
            set: { on in if on { checked.insert(item.sourcePath) } else { checked.remove(item.sourcePath) } }
        )
    }
}

struct SkillPreviewRow: View {
    var item: SkillPreviewItem
    @Binding var checked: Bool

    private var counts: String {
        var parts: [String] = []
        if item.stepCount > 0 { parts.append("\(item.stepCount) step\(item.stepCount == 1 ? "" : "s")") }
        if item.scriptCount > 0 { parts.append("\(item.scriptCount) script\(item.scriptCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "Instructions only" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var chip: some View {
        if let existing = item.existingVersion {
            if item.unchanged {
                Chip("Unchanged", color: PennantTheme.inkTertiary)
            } else {
                Chip("v\(existing) → v\(existing + 1)", color: PennantTheme.info)
            }
        } else {
            Chip("New", color: PennantTheme.success)
        }
    }

    var body: some View {
        Toggle(isOn: $checked) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                        chip
                    }
                    if !item.purpose.isEmpty {
                        Text(item.purpose).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    }
                    Text(counts).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #else
        .toggleStyle(.switch)
        #endif
        .tint(PennantTheme.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Results

struct SkillImportResults: View {
    var imported: [Skill]
    var warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(imported.isEmpty ? "Nothing imported" : "Imported \(imported.count) skill\(imported.count == 1 ? "" : "s")")
                .font(.zoomed(.subheadline).weight(.semibold)).foregroundStyle(PennantTheme.ink)
            ForEach(imported) { s in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PennantTheme.success)
                    Text(s.name).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    Chip("v\(s.version)", color: s.version > 1 ? PennantTheme.info : PennantTheme.success)
                    Spacer(minLength: 0)
                }
            }
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(PennantTheme.warning)
                    Text(w).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(elevated: true)
    }
}
