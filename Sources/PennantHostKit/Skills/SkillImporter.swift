import PennantCore
import Foundation

/// Imports skills written in the SKILL.md format shared by Claude Code, Codex, and the Agent Skills standard:
/// a folder with `SKILL.md` (YAML front matter `name`, `description`, then Markdown instructions) and optional
/// `scripts/`, `references/`, `assets/` files. The body becomes the skill's instructions; numbered steps in it
/// become steps; small text files come along as scripts.
public enum SkillImporter {
    public static let textExtensions: Set<String> = ["md", "txt", "sh", "zsh", "bash", "py", "js", "ts", "mjs", "rb", "swift", "json", "yaml", "yml", "toml", "applescript", "scpt", "jxa", "csv", "html", "css", "xml", "sql"]
    public static let maxFileBytes = 200_000
    public static let maxFilesPerSkill = 40

    public struct ImportResult: Sendable {
        public var skills: [Skill]
        public var warnings: [String]
    }

    /// Well-known skill folders of other harnesses that exist on this machine.
    public static func knownLocations(workingDirectory: String) -> [SkillLocation] {
        let home = NSHomeDirectory()
        let candidates: [(String, String)] = [
            ("\(home)/.claude/skills", "Claude Code (user)"),
            ("\(workingDirectory)/.claude/skills", "Claude Code (project)"),
            ("\(home)/.codex/skills", "Codex (user)"),
            ("\(workingDirectory)/.codex/skills", "Codex (project)"),
            ("\(home)/.agents/skills", "Agent Skills (user)"),
            ("\(workingDirectory)/.agents/skills", "Agent Skills (project)"),
            ("\(home)/.cursor/skills", "Cursor"),
            ("\(home)/.gemini/skills", "Gemini CLI"),
        ]
        var out: [SkillLocation] = []
        var seen = Set<String>()
        for (path, harness) in candidates {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted, FileManager.default.fileExists(atPath: standardized) else { continue }
            let count = findSkillFiles(under: URL(fileURLWithPath: standardized)).count
            if count > 0 { out.append(SkillLocation(path: standardized, harness: harness, skillCount: count)) }
        }
        return out
    }

    /// All SKILL.md files under a path (or the path itself when it is a SKILL.md), a few levels deep.
    public static func findSkillFiles(under root: URL, maxDepth: Int = 4) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return root.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame ? [root] : [] }
        let direct = root.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: direct.path) { return [direct] }
        var out: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if item.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame { out.append(item); continue }
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if fm.fileExists(atPath: item.appendingPathComponent("SKILL.md").path) { out.append(item.appendingPathComponent("SKILL.md")) }
                    else { walk(item, depth: depth + 1) }
                }
            }
        }
        walk(root, depth: 1)
        return out
    }

    /// Parse one SKILL.md into a skill (no persistence).
    public static func parse(skillFile: URL) throws -> Skill {
        let raw = try String(contentsOf: skillFile, encoding: .utf8)
        let (front, body) = splitFrontMatter(raw)
        let folder = skillFile.deletingLastPathComponent()
        let name = front["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        let description = front["description"] ?? firstParagraph(body)
        var steps = numberedSteps(in: body)
        if steps.isEmpty { steps = [SkillStep(instruction: "Follow the skill's instructions (shown by use_skill) exactly, adapting to the inputs.", check: "The expected result described in the instructions is present.")] }
        var scripts: [String: String] = [:]
        let fm = FileManager.default
        // Relative subpaths avoid /var vs /private/var mismatches between the folder and enumerated URLs.
        for rel in ((try? fm.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted() where scripts.count < maxFilesPerSkill {
            guard rel != "SKILL.md", !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let full = folder.appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: full.path), (attrs[.type] as? String) == FileAttributeType.typeRegular.rawValue else { continue }
            guard textExtensions.contains(full.pathExtension.lowercased()), ((attrs[.size] as? Int) ?? 0) <= maxFileBytes else { continue }
            if let text = try? String(contentsOf: full, encoding: .utf8) { scripts[rel] = text }
        }
        var prerequisites: [String] = []
        if let tools = front["allowed-tools"] ?? front["allowed_tools"], !tools.isEmpty { prerequisites.append("Originally allowed tools: \(tools)") }
        if let license = front["license"], !license.isEmpty { prerequisites.append("License: \(license)") }
        return Skill(name: name, purpose: String(description.prefix(500)), applicability: front["when"] ?? "", prerequisites: prerequisites, steps: steps, scripts: scripts, status: .validated, origin: "imported", body: String(body.prefix(60_000)), sourcePath: skillFile.path, outputs: outputs(front))
    }

    /// report / report-sections / approval / approval-label / approval-action / approval-text-field / approval-details / effort.
    static func outputs(_ front: [String: String]) -> SkillOutputs? {
        func list(_ key: String) -> [String] {
            (front[key] ?? "").split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func value(_ key: String) -> String? { front[key].flatMap { $0.isEmpty ? nil : $0 } }
        var out = SkillOutputs()
        if let title = value("report") { out.report = .init(title: ["yes", "true"].contains(title.lowercased()) ? "Report · {date}" : title, sections: list("report-sections")) }
        if let destination = value("approval") {
            out.approval = .init(destination: destination, label: value("approval-label"), action: value("approval-action"), textField: value("approval-text-field"), details: list("approval-details"))
        }
        if let effort = value("effort")?.lowercased(), TaskRuntime.effortLevels.contains(effort) { out.effort = effort }
        return out.isEmpty ? nil : out
    }

    /// Import everything under a path, versioning skills that already exist by name.
    public static func importAll(path: String, only: [String]? = nil, store: any StoreProtocol, eventBus: EventBus, workingDirectory: String) async -> ImportResult {
        let root = URL(fileURLWithPath: PathResolver.resolve(path, base: workingDirectory))
        var files = findSkillFiles(under: root)
        if let only { let wanted = Set(only.map { URL(fileURLWithPath: $0).standardizedFileURL.path }); files = files.filter { wanted.contains($0.standardizedFileURL.path) } }
        var result = ImportResult(skills: [], warnings: [])
        if files.isEmpty { result.warnings.append(only == nil ? "No SKILL.md found under \(root.path)" : "None of the chosen skills were found under \(root.path)") ; return result }
        let existing = (try? await store.listSkills(includeDisabled: true)) ?? []
        for file in files {
            do {
                var skill = try parse(skillFile: file)
                if let latest = existing.filter({ $0.name.caseInsensitiveCompare(skill.name) == .orderedSame }).max(by: { $0.version < $1.version }) {
                    if latest.body == skill.body, latest.scripts == skill.scripts, latest.outputs == skill.outputs { result.warnings.append("\(skill.name): unchanged, skipped"); continue }
                    skill.version = latest.version + 1
                    skill.previousVersionID = latest.id
                }
                try await store.upsertSkill(skill)
                if let event = try? await store.appendEvent(.skillUpserted(skill)) { await eventBus.publish(event) }
                result.skills.append(skill)
            } catch {
                result.warnings.append("\(file.path): \(error)")
            }
        }
        return result
    }

    // MARK: Parsing helpers

    static func splitFrontMatter(_ text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], text) }
        var front: [String: String] = [:]
        var i = 1
        var lastKey: String?
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                if value == ">" || value == "|" || value == ">-" || value == "|-" { value = "" }
                front[key] = value
                lastKey = key
            } else if let key = lastKey {
                front[key] = (front[key] ?? "") + (front[key]?.isEmpty == false ? " " : "") + line.trimmingCharacters(in: .whitespaces)
            }
            i += 1
        }
        let body = lines.dropFirst(i + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (front, body)
    }

    static func firstParagraph(_ body: String) -> String {
        for block in body.components(separatedBy: "\n\n") {
            let t = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.hasPrefix("#") { return t.replacingOccurrences(of: "\n", with: " ") }
        }
        return ""
    }

    static func numberedSteps(in body: String) -> [SkillStep] {
        var steps: [SkillStep] = []
        for line in body.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty else { continue }
            let instruction = t[t.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            if !instruction.isEmpty, steps.count < 30 { steps.append(SkillStep(instruction: instruction)) }
        }
        return steps
    }
}

// MARK: - Preview, folders, and git

extension SkillImporter {
    static let foldersKey = "skillFolders"
    static let reposKey = "skillRepos"

    /// Parses everything under a folder and reports what an import would do, without writing.
    public static func preview(path: String, store: any StoreProtocol, workingDirectory: String) async -> SkillImportPreview {
        let root = URL(fileURLWithPath: PathResolver.resolve(path, base: workingDirectory))
        let files = findSkillFiles(under: root)
        var items: [SkillPreviewItem] = []
        var warnings: [String] = []
        if files.isEmpty { warnings.append("No SKILL.md found under \(root.path)") }
        let existing = (try? await store.listSkills(includeDisabled: true)) ?? []
        for file in files {
            do {
                let skill = try parse(skillFile: file)
                let latest = existing.filter { $0.name.caseInsensitiveCompare(skill.name) == .orderedSame }.max { $0.version < $1.version }
                let unchanged = latest.map { $0.body == skill.body && $0.scripts == skill.scripts && $0.outputs == skill.outputs } ?? false
                items.append(SkillPreviewItem(name: skill.name, purpose: skill.purpose, sourcePath: file.path, stepCount: skill.steps.count, scriptCount: skill.scripts.count, existingVersion: latest?.version, unchanged: unchanged))
            } catch {
                warnings.append("\(file.path): \(error)")
            }
        }
        return SkillImportPreview(root: root.path, items: items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, warnings: warnings)
    }

    /// True for anything `git clone` understands: http(s), ssh, git@, or a path ending in .git.
    public static func isGitURL(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces).lowercased()
        return p.hasPrefix("http://") || p.hasPrefix("https://") || p.hasPrefix("ssh://") || p.hasPrefix("git@") || p.hasPrefix("git://") || p.hasSuffix(".git")
    }

    /// Clones a repository (shallow) under `reposRoot`, or pulls if it is already there. Returns the checkout folder.
    public static func materialize(gitURL: String, reposRoot: URL) throws -> URL {
        let url = gitURL.trimmingCharacters(in: .whitespaces)
        var name = URL(string: url)?.lastPathComponent ?? url.split(separator: "/").last.map(String.init) ?? "repo"
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        name = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        if name.isEmpty { name = "repo" }
        try FileManager.default.createDirectory(at: reposRoot, withIntermediateDirectories: true)
        let dest = reposRoot.appendingPathComponent(name)
        let args: [String]
        if FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path) {
            args = ["-C", dest.path, "pull", "--ff-only", "--quiet"]
        } else {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            args = ["clone", "--depth", "1", "--quiet", url, dest.path]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ToolError.failed("git \(args.first ?? "") failed (\(process.terminationStatus)): \(message.isEmpty ? "no output" : message)")
        }
        return dest
    }

    /// Folders the user added, stored in settings as a JSON array of paths.
    public static func customFolders(store: any StoreProtocol) async -> [String] {
        guard let raw = try? await store.setting(foldersKey), let data = raw.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    public static func setCustomFolders(_ folders: [String], store: any StoreProtocol) async throws {
        let data = try JSONEncoder().encode(folders)
        try await store.setSetting(foldersKey, value: String(decoding: data, as: UTF8.self))
    }

    /// Cloned repositories, stored in settings as a JSON map of checkout path to URL.
    public static func repos(store: any StoreProtocol) async -> [String: String] {
        guard let raw = try? await store.setting(reposKey), let data = raw.data(using: .utf8), let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public static func setRepos(_ repos: [String: String], store: any StoreProtocol) async throws {
        let data = try JSONEncoder().encode(repos)
        try await store.setSetting(reposKey, value: String(decoding: data, as: UTF8.self))
    }

    /// Known harness folders plus the user's folders and cloned repositories, each with a live skill count.
    public static func locations(store: any StoreProtocol, workingDirectory: String) async -> [SkillLocation] {
        var out = knownLocations(workingDirectory: workingDirectory)
        let repos = await repos(store: store)
        var seen = Set(out.map(\.path))
        let folders = await customFolders(store: store) + repos.keys.sorted()
        for folder in folders where seen.insert(folder).inserted {
            let url = URL(fileURLWithPath: PathResolver.resolve(folder, base: workingDirectory))
            let count = findSkillFiles(under: url).count
            if let origin = repos[folder] {
                out.append(SkillLocation(path: folder, harness: "Git repository", skillCount: count, kind: "git", origin: origin))
            } else {
                out.append(SkillLocation(path: folder, harness: "Your folder", skillCount: count, kind: "custom"))
            }
        }
        return out
    }
}

