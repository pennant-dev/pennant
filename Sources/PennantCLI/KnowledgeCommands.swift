import PennantClientKit
import PennantCore
import Foundation
import UniformTypeIdentifiers

// What Pennant knows: memory, skills (import, preview, folders), teach mode, and the Library.

func describe(_ location: SkillLocation) -> String {
    let origin = location.origin.map { "  ← \($0)" } ?? ""
    return "\(location.path)  (\(location.harness), \(location.skillCount) skill\(location.skillCount == 1 ? "" : "s")) [\(location.kind)]\(origin)"
}

func printLocations(_ locations: [SkillLocation]) {
    if locations.isEmpty { out("No skill folders known. Add one with `pennant skills folders add <path>`, or import directly: pennant skills import <folder|url>") }
    for l in locations { out(describe(l)) }
}

func describe(_ item: SkillPreviewItem) -> String {
    let state: String
    if item.unchanged { state = "unchanged, v\(item.existingVersion ?? 1) already in the library" }
    else if let v = item.existingVersion { state = "update of v\(v)" }
    else { state = "new" }
    let scripts = item.scriptCount == 0 ? "" : ", \(item.scriptCount) script\(item.scriptCount == 1 ? "" : "s")"
    var lines = ["\(item.name)  [\(state)]  \(item.stepCount) step\(item.stepCount == 1 ? "" : "s")\(scripts)"]
    if !item.purpose.isEmpty { lines.append("    \(item.purpose.prefix(120))") }
    lines.append("    \(item.sourcePath)")
    return lines.joined(separator: "\n")
}

/// `pennant library [list|add|notes]`.
@MainActor
func runLibrary(_ sub: String, args: [String], options: CLIOptions) async throws {
    let session = try await connect(options)
    var index: LibraryIndex
    switch sub {
    case "list":
        index = try await session.listLibrary()
    case "add":
        guard args.count >= 2 else { await session.disconnect(); fail("Usage: pennant library add <collection> <file>… [--notes N]") }
        var files: [String] = []
        var notes = ""
        var i = 1
        while i < args.count {
            if args[i] == "--notes", i + 1 < args.count { notes = args[i + 1]; i += 2; continue }
            files.append(args[i]); i += 1
        }
        index = try await session.listLibrary()
        for path in files {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { out("! cannot read \(path)"); continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            index = try await session.uploadLibraryAsset(data, collection: args[0], fileName: url.lastPathComponent, mimeType: mime, notes: notes)
        }
    case "notes":
        guard args.count >= 2 else { await session.disconnect(); fail("Usage: pennant library notes <collection> <text>") }
        index = try await session.saveLibraryCollection(LibraryCollection(name: args[0], notes: args.dropFirst().joined(separator: " ")))
    default:
        await session.disconnect()
        fail("Unknown library subcommand '\(sub)'. Try: list, add, notes")
    }
    for c in index.collections {
        out("\(c.name)")
        if !c.notes.isEmpty { out("  guidance: \(c.notes.prefix(160))") }
        for a in index.assets where a.collection == c.name { out("  \(a.name)  \(a.path)") }
    }
    await session.disconnect()
}

/// `pennant skills import|preview|folders|delete …`. Listing stays in `run`.
@MainActor
func runSkills(_ sub: String, args: [String], options: CLIOptions) async throws {
    let session = try await connect(options)
    switch sub {
    case "preview":
        guard let source = args.first else { await session.disconnect(); fail("Usage: pennant skills preview <folder|url>") }
        let r = try await session.send(.previewSkillImport(path: source), timeout: 300)
        guard case .skillPreview(let preview) = r else { await session.disconnect(); fail(replyError(r)) }
        out("\(preview.root): \(preview.items.count) skill(s)")
        for item in preview.items { out(describe(item)) }
        for w in preview.warnings { out("  ! \(w)") }

    case "import":
        var only: [String] = []
        var positional: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--only" {
                i += 1
                while i < args.count, !args[i].hasPrefix("--") { only.append(args[i]); i += 1 }
                continue
            }
            positional.append(args[i])
            i += 1
        }
        guard let source = positional.first else {
            let r = try await session.send(.scanSkillLocations)
            if case .skillLocations(let locs) = r { printLocations(locs) }
            out("Import with: pennant skills import <folder|url> [--only <name>…]")
            await session.disconnect()
            return
        }
        var path = source
        var chosen: [String]? = nil
        if !only.isEmpty {
            // Names come from the preview; the host wants SKILL.md paths.
            let r = try await session.send(.previewSkillImport(path: source), timeout: 300)
            guard case .skillPreview(let preview) = r else { await session.disconnect(); fail(replyError(r)) }
            var paths: [String] = []
            var missing: [String] = []
            for name in only {
                if let item = preview.items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { paths.append(item.sourcePath) } else { missing.append(name) }
            }
            if !missing.isEmpty {
                await session.disconnect()
                fail("Not found under \(preview.root): \(missing.joined(separator: ", ")). Available: \(preview.items.map(\.name).joined(separator: ", "))")
            }
            chosen = paths
            path = preview.root   // already cloned or resolved; no second pull
        }
        let r = try await session.send(.importSkills(path: path, only: chosen), timeout: 300)
        guard case .importedSkills(let skills, let warnings) = r else { await session.disconnect(); fail(replyError(r)) }
        out("Imported \(skills.count) skill(s)")
        for sk in skills { out("  \(sk.name) v\(sk.version)") }
        for w in warnings { out("  ! \(w)") }

    case "folders":
        let r: ReplyBody
        switch (args.first, args.dropFirst().first) {
        case ("add"?, let path?): r = try await session.send(.addSkillFolder(path: path))
        case ("remove"?, let path?): r = try await session.send(.removeSkillFolder(path: path))
        case (nil, _): r = try await session.send(.scanSkillLocations)
        default: await session.disconnect(); fail("Usage: pennant skills folders [add <path>|remove <path>]")
        }
        guard case .skillLocations(let locs) = r else { await session.disconnect(); fail(replyError(r)) }
        printLocations(locs)

    case "delete":
        guard !args.isEmpty else { await session.disconnect(); fail("Usage: pennant skills delete <id>…") }
        try await session.loadSkills()
        var ids: [SkillID] = []
        for ident in args {
            let matches = session.state.skills.filter { $0.id.rawValue == ident || $0.id.rawValue.hasPrefix(ident) }
            guard matches.count == 1, let match = matches.first else {
                await session.disconnect()
                fail(matches.isEmpty ? "No skill with id \(ident)" : "Ambiguous id \(ident): \(matches.map { String($0.id.rawValue.prefix(12)) }.joined(separator: ", "))")
            }
            ids.append(match.id)
        }
        let r = try await session.send(.deleteSkills(ids))
        guard case .ok = r else { await session.disconnect(); fail(replyError(r)) }
        out("Deleted \(ids.count) skill(s); built-in skills are kept (disable them instead)")

    default:
        await session.disconnect()
        fail("Unknown skills subcommand '\(sub)'")
    }
    await session.disconnect()
}

@MainActor
func memoryCommand(_ options: CLIOptions) async throws {
    // pennant memory forget <id>: a fact or a standing instruction, by its full id.
    if options.args.first == "forget", options.args.count == 2 {
        let id = options.args[1]
        let session = try await connect(options)
        var r = try await session.send(.forgetEntity(MemoryEntityID(id)), timeout: 30)
        if case .error = r { r = try await session.send(.forgetPreference(PreferenceID(id)), timeout: 30) }
        await session.disconnect()
        if case .error = r { fail(replyError(r)) }
        out("Forgot \(id).")
        return
    }
    guard options.args.first == "search", options.args.count >= 2 else { fail("Usage: pennant memory search <text…> | forget <id>") }
    let session = try await connect(options)
    // --facts searches as agents do: facts and what was said, not the standing instructions they already have.
    var words = Array(options.args.dropFirst())
    let factsOnly = words.contains("--facts")
    words.removeAll { $0 == "--facts" }
    let hits = try await session.searchMemory(MemoryQuery(text: words.joined(separator: " "), instructions: factsOnly ? false : nil))
    if hits.isEmpty { out("No matches.") }
    for hit in hits {
        let score = String(format: "%.2f", hit.score)
        switch hit.item {
        case .entity(let e): out("[\(score)] entity \(e.kind.rawValue) \(e.name) [\(e.status.rawValue)] \(e.summary.prefix(100))  (\(hit.reason))")
        case .relation(let r, let from, let to): out("[\(score)] \(from.name) -\(r.relation)-> \(to.name) [\(r.status.rawValue)]  (\(hit.reason))")
        case .preference(let p): out("[\(score)] preference v\(p.version) \(p.text.prefix(120))  (\(hit.reason))")
        case .message(let m): out("[\(score)] message \(m.role.rawValue) \(m.text.prefix(120))  (\(hit.reason))")
        case .passage(let p): out("[\(score)] said in \"\(p.title)\" (\(p.speaker), \(p.at.formatted(date: .abbreviated, time: .omitted))) \(p.text.replacingOccurrences(of: "\n", with: " ").prefix(160))  (\(hit.reason))")
        }
    }
    await session.disconnect()
}

@MainActor
func teachCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    let sub = options.args.first ?? "status"
    let rest = options.args.dropFirst().joined(separator: " ")
    func show(_ t: TeachingSession?) {
        guard let t else { out("No teaching session."); return }
        out("\(t.isRecording ? "● Recording" : (t.isDrafting ? "Drafting" : "Stopped")): \(t.goal.isEmpty ? "(no goal)" : t.goal) · \(t.events.count) step(s)")
        if let w = t.warning { out("  ! \(w)") }
        if let e = t.draftError { out("  ! \(e)") }
        if !t.events.isEmpty { out(t.transcript) }
    }
    switch sub {
    case "start":
        show(try await session.startTeaching(goal: rest))
    case "stop":
        show(try await session.stopTeaching())
    case "note":
        show(try await session.addTeachingNote(rest))
    case "cancel":
        try await session.cancelTeaching()
        out("Cancelled.")
    case "draft":
        let skill = try await session.draftSkillFromTeaching(goal: rest.isEmpty ? nil : rest)
        out("Drafted '\(skill.name)' v\(skill.version) [\(skill.status.rawValue)] — \(skill.purpose)")
        for (i, step) in skill.steps.enumerated() {
            out("  \(i + 1). \(step.instruction)\(step.check.isEmpty ? "" : "  ✓ \(step.check)")")
        }
    default:
        show(try await session.loadTeaching())
    }
    await session.disconnect()
}

@MainActor
func skillsListCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    try await session.loadSkills()
    if session.state.skills.isEmpty { out("No skills learned yet.") }
    for s in session.state.skills {
        let rate = s.successRate.map { String(format: " %.0f%% success", $0 * 100) } ?? ""
        out("\(s.name) v\(s.version) [\(s.status.rawValue)]\(rate) — \(s.purpose.prefix(100))")
    }
    await session.disconnect()
}
