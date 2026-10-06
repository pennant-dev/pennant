import PennantCore
import Foundation

/// Claude Code's skills, linked rather than copied: the owner's own (`~/.claude/skills`) and those of the plugins they
/// have enabled. They stay in step with their files: an edit there becomes a new version here, and a skill that's gone
/// there (or a plugin turned off) is removed here. They're read-only in Pennant; Claude Code is where they're edited.
///
/// Pennant follows a linked skill itself, unless it leans on what only Claude Code has (subagents, a forked context,
/// commands run as it loads): `needsClaudeCode` says why, and use_skill hands it to a Claude Code run.
public enum ClaudeCodeSkills {
    public static let origin = "claude-code"

    /// One SKILL.md to link: the owner's own, or a plugin's (named "plugin:skill", as Claude Code names it).
    struct Source: Equatable {
        var file: URL
        var plugin: String?
        var pluginRoot: URL?
    }

    public struct SyncResult: Sendable, Equatable {
        public var added: [String] = []
        public var updated: [String] = []
        public var removed: [String] = []
        /// Skills left out, and why (a Pennant skill already has the name, the file didn't parse).
        public var skipped: [String] = []
        public var changed: Bool { !added.isEmpty || !updated.isEmpty || !removed.isEmpty }
    }

    // MARK: Finding them

    /// The SKILL.md files Claude Code would load for the owner: `~/.claude/skills/<name>/SKILL.md`, the skills of their
    /// Claude account (which Claude Code keeps in `skills/synced/<account>/<name>`), then each enabled, user-installed
    /// plugin's skills (its `skills/` folder, plus any folders its manifest lists).
    static func sources(home: URL) -> [Source] {
        let claude = home.appendingPathComponent(".claude")
        var out = skillFiles(in: claude.appendingPathComponent("skills")).map { Source(file: $0) }
        let synced = claude.appendingPathComponent("skills/synced")
        for account in ((try? FileManager.default.contentsOfDirectory(at: synced, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
            out += skillFiles(in: account).map { Source(file: $0) }
        }
        for plugin in enabledPlugins(claude: claude) {
            let manifest = readJSON(plugin.root.appendingPathComponent(".claude-plugin/plugin.json")) ?? readJSON(plugin.root.appendingPathComponent("plugin.json")) ?? [:]
            let name = (manifest["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? plugin.key
            var folders = ["skills"]
            if let one = manifest["skills"] as? String { folders.append(one) }
            if let many = manifest["skills"] as? [String] { folders += many }
            var seen = Set<String>()
            for folder in folders {
                let dir = plugin.root.appendingPathComponent(folder).standardizedFileURL
                for file in skillFiles(in: dir) where seen.insert(file.path).inserted {
                    out.append(Source(file: file, plugin: name, pluginRoot: plugin.root))
                }
            }
        }
        return out
    }

    /// A folder that is itself a skill, or the skills one level inside it. Deeper SKILL.md files (a plugin's own
    /// templates and assets) aren't skills Claude Code loads.
    static func skillFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: direct.path) { return [direct] }
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return children.filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { $0.appendingPathComponent("SKILL.md") }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    /// Plugins installed for the user (not for one project) and switched on in Claude Code's settings.
    static func enabledPlugins(claude: URL) -> [(key: String, root: URL)] {
        let settings = readJSON(claude.appendingPathComponent("settings.json")) ?? [:]
        let enabled = (settings["enabledPlugins"] as? [String: Any] ?? [:]).filter { ($0.value as? Bool) == true }.map(\.key)
        let installed = readJSON(claude.appendingPathComponent("plugins/installed_plugins.json"))?["plugins"] as? [String: Any] ?? [:]
        return enabled.sorted().compactMap { id in
            let installs = installed[id] as? [[String: Any]] ?? []
            guard let path = installs.first(where: { ($0["scope"] as? String ?? "user") == "user" })?["installPath"] as? String,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return (String(id.split(separator: "@").first ?? Substring(id)), URL(fileURLWithPath: path))
        }
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Reading one

    /// The skill a source becomes here: parsed as any SKILL.md, named as Claude Code names it, with the plugin's and the
    /// skill's folders filled in where its instructions refer to them.
    static func skill(from source: Source) throws -> Skill {
        var skill = try SkillImporter.parse(skillFile: source.file)
        let (front, raw) = SkillImporter.splitFrontMatter(try String(contentsOf: source.file, encoding: .utf8))
        if let plugin = source.plugin { skill.name = "\(plugin):\(skill.name)" }
        skill.origin = origin
        var body = skill.body.replacingOccurrences(of: "${CLAUDE_SKILL_DIR}", with: source.file.deletingLastPathComponent().path)
        if let root = source.pluginRoot { body = body.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: root.path) }
        skill.body = body
        skill.needsClaudeCode = needsClaudeCode(front: front, body: raw)
        return skill
    }

    /// Why a skill can only run in Claude Code, or nil when Pennant can follow it.
    static func needsClaudeCode(front: [String: String], body: String) -> String? {
        if front["context"]?.lowercased() == "fork" || !(front["agent"] ?? "").isEmpty { return "it runs as an agent of its own in Claude Code" }
        if !(front["hooks"] ?? "").isEmpty { return "it sets Claude Code hooks" }
        func has(_ pattern: String) -> Bool { body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        // Tools named as Claude Code names them (mcp__server__tool) aren't the names Pennant's tools go by.
        if let tool = body.range(of: #"mcp__[A-Za-z0-9-]+(_[A-Za-z0-9-]+)*"#, options: .regularExpression) { return "it uses Claude Code's \(body[tool]) tools" }
        if has(#"\b(task|agent) tool\b|\bsub-?agents?\b|subagent_type"#) { return "it starts subagents" }
        if has(#"\bskill tool\b"#) { return "it calls other Claude Code skills" }
        if body.contains("!`") { return "it runs commands as Claude Code loads it" }
        return nil
    }

    // MARK: Keeping in step

    /// Brings the linked skills in line with Claude Code's files. Off, every linked skill is removed.
    public static func sync(enabled: Bool, store: SQLiteStore, eventBus: EventBus, home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> SyncResult {
        var result = SyncResult()
        let all = (try? await store.listSkills(includeDisabled: true)) ?? []
        let linked = Dictionary(grouping: all.filter { $0.origin == origin }, by: { $0.name.lowercased() })
        let others = Set(all.filter { $0.origin != origin }.map { $0.name.lowercased() })
        var present = Set<String>()
        for source in enabled ? sources(home: home) : [] {
            var skill: Skill
            do { skill = try self.skill(from: source) } catch {
                result.skipped.append("\(source.file.path): \(error)")
                continue
            }
            let key = skill.name.lowercased()
            guard present.insert(key).inserted else { continue }
            // Pennant's skills go by name, so one of its own keeps the name.
            if others.contains(key) {
                result.skipped.append("\(skill.name): one of Pennant's skills has this name")
                continue
            }
            if let latest = linked[key]?.max(by: { $0.version < $1.version }) {
                if latest.body == skill.body, latest.scripts == skill.scripts, latest.purpose == skill.purpose, latest.outputs == skill.outputs,
                   latest.needsClaudeCode == skill.needsClaudeCode, latest.sourcePath == skill.sourcePath { continue }
                skill.version = latest.version + 1
                skill.previousVersionID = latest.id
                // Turned off here, it stays off through Claude Code's edits.
                if latest.status == .disabled { skill.status = .disabled }
                result.updated.append(skill.name)
            } else {
                result.added.append(skill.name)
            }
            try? await store.upsertSkill(skill)
            if let event = try? await store.appendEvent(.skillUpserted(skill)) { await eventBus.publish(event) }
        }
        for (key, versions) in linked where !present.contains(key) {
            for version in versions {
                try? await store.deleteSkill(version.id)
                if let event = try? await store.appendEvent(.skillRemoved(version.id)) { await eventBus.publish(event) }
            }
            if let name = versions.first?.name { result.removed.append(name) }
        }
        return result
    }
}
