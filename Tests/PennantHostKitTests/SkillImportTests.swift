import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Skill import preview, filtered import, git sources, and remembered folders. Git cases skip when `git` is missing.
final class SkillImportTests: XCTestCase {
    private var root: URL!
    private var paths: HostPaths!
    private var store: SQLiteStore!
    private let bus = EventBus()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        store = try SQLiteStore(paths: paths)
    }

    override func tearDown() async throws {
        await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
        if let paths { try? FileManager.default.removeItem(at: paths.root) }
    }

    /// Writes `<folder>/<name>/SKILL.md` and returns the SKILL.md path.
    @discardableResult
    private func writeSkill(_ name: String, in folder: URL, description: String = "Does the thing.", steps: [String] = ["Open the app.", "Press go."]) throws -> URL {
        let dir = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let file = dir.appendingPathComponent("SKILL.md")
        try "---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func samePath(_ a: String, _ b: URL) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    private func preview(_ path: String) async -> SkillImportPreview {
        await SkillImporter.preview(path: path, store: store, workingDirectory: root.path)
    }

    private func importAll(_ path: String, only: [String]? = nil) async -> SkillImporter.ImportResult {
        await SkillImporter.importAll(path: path, only: only, store: store, eventBus: bus, workingDirectory: root.path)
    }

    // MARK: Preview and filtering

    func testPreviewReportsNewThenExistingAndUnchanged() async throws {
        let folder = root.appendingPathComponent("skills")
        let deploy = try writeSkill("deploy", in: folder)
        try writeSkill("notes", in: folder, steps: ["Write it down."])

        let first = await preview(folder.path)
        XCTAssertEqual(first.items.map(\.name), ["deploy", "notes"])
        XCTAssertTrue(first.warnings.isEmpty, first.warnings.joined(separator: "; "))
        XCTAssertTrue(first.items.allSatisfy { $0.existingVersion == nil && !$0.unchanged })
        XCTAssertEqual(first.items[0].stepCount, 2)
        XCTAssertEqual(first.items[0].purpose, "Does the thing.")
        XCTAssertTrue(samePath(first.items[0].sourcePath, deploy), first.items[0].sourcePath)
        XCTAssertTrue(samePath(first.root, folder))
        let untouched = try await store.listSkills(includeDisabled: true)
        XCTAssertTrue(untouched.isEmpty, "preview writes nothing")

        // Import one; the preview now knows it and reports it unchanged.
        let imported = await importAll(folder.path, only: [first.items[0].sourcePath])
        XCTAssertEqual(imported.skills.map(\.name), ["deploy"])
        let second = await preview(folder.path)
        let deployItem = try XCTUnwrap(second.items.first { $0.name == "deploy" })
        XCTAssertEqual(deployItem.existingVersion, 1)
        XCTAssertTrue(deployItem.unchanged)
        let notesItem = try XCTUnwrap(second.items.first { $0.name == "notes" })
        XCTAssertNil(notesItem.existingVersion)
        XCTAssertFalse(notesItem.unchanged)

        // Change the file: the preview reports an update of v1, and importing makes v2.
        try writeSkill("deploy", in: folder, steps: ["Open the app.", "Press go.", "Check the result."])
        let third = await preview(folder.path)
        let changed = try XCTUnwrap(third.items.first { $0.name == "deploy" })
        XCTAssertEqual(changed.existingVersion, 1)
        XCTAssertFalse(changed.unchanged)
        XCTAssertEqual(changed.stepCount, 3)
        let reimported = await importAll(folder.path, only: [changed.sourcePath])
        XCTAssertEqual(reimported.skills.map(\.version), [2])

        // An empty folder previews with a warning and no items.
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let nothing = await preview(empty.path)
        XCTAssertTrue(nothing.items.isEmpty)
        XCTAssertEqual(nothing.warnings.count, 1)
    }

    func testImportOnlyLimitsToChosenSkills() async throws {
        let folder = root.appendingPathComponent("skills")
        try writeSkill("alpha", in: folder)
        let beta = try writeSkill("beta", in: folder)
        try writeSkill("gamma", in: folder)

        let one = await importAll(folder.path, only: [beta.path])
        XCTAssertEqual(one.skills.map(\.name), ["beta"])
        XCTAssertTrue(one.warnings.isEmpty, one.warnings.joined(separator: "; "))
        let stored = try await store.listSkills(includeDisabled: true).map(\.name)
        XCTAssertEqual(stored, ["beta"])

        // Paths that are not under the folder import nothing and say so.
        let none = await importAll(folder.path, only: [root.appendingPathComponent("elsewhere/SKILL.md").path])
        XCTAssertTrue(none.skills.isEmpty)
        XCTAssertEqual(none.warnings.count, 1)

        // Without a filter the rest come in and beta is skipped as unchanged.
        let rest = await importAll(folder.path)
        XCTAssertEqual(rest.skills.map(\.name), ["alpha", "gamma"])
        XCTAssertEqual(rest.warnings, ["beta: unchanged, skipped"])
    }

    // MARK: Git sources

    func testGitURLDetection() {
        XCTAssertTrue(SkillImporter.isGitURL("https://github.com/acme/skills"))
        XCTAssertTrue(SkillImporter.isGitURL("git@github.com:acme/skills.git"))
        XCTAssertTrue(SkillImporter.isGitURL("ssh://git@host/skills"))
        XCTAssertTrue(SkillImporter.isGitURL("/srv/git/skills.git"))
        XCTAssertTrue(SkillImporter.isGitURL("  https://example.com/x  "))
        XCTAssertFalse(SkillImporter.isGitURL("~/.claude/skills"))
        XCTAssertFalse(SkillImporter.isGitURL("/tmp/skills"))
        XCTAssertFalse(SkillImporter.isGitURL("gitlab-notes"))
    }

    private func requireGit() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { throw XCTSkip("git is not available: \(error)") }
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw XCTSkip("git is not on PATH") }
    }

    private func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "user.name=Pennant Tests", "-c", "user.email=tests@pennant.local", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        p.currentDirectoryURL = dir
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ToolError.failed("git \(args.joined(separator: " ")) failed: \(String(decoding: data, as: UTF8.self))") }
    }

    func testGitSourceClonesThenPulls() async throws {
        try requireGit()
        // Author a repository with one skill, then a bare clone stands in for the remote.
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try writeSkill("triage", in: work)
        try git(["init", "--quiet"], in: work)
        try git(["add", "."], in: work)
        try git(["commit", "--quiet", "-m", "skills"], in: work)
        let bare = root.appendingPathComponent("skills-remote.git")
        try git(["clone", "--quiet", "--bare", work.path, bare.path], in: root)
        let url = "file://" + bare.path
        XCTAssertTrue(SkillImporter.isGitURL(url))

        let reposRoot = paths.root.appendingPathComponent("skills/repos")
        let checkout = try SkillImporter.materialize(gitURL: url, reposRoot: reposRoot)
        XCTAssertEqual(checkout.lastPathComponent, "skills-remote")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("triage/SKILL.md").path))
        let first = await preview(checkout.path)
        XCTAssertEqual(first.items.map(\.name), ["triage"])
        let imported = await importAll(checkout.path)
        XCTAssertEqual(imported.skills.map(\.name), ["triage"])

        // A new skill upstream arrives with the next materialize (a pull, not a fresh clone).
        try writeSkill("followup", in: work)
        try git(["add", "."], in: work)
        try git(["commit", "--quiet", "-m", "more"], in: work)
        try git(["push", "--quiet", bare.path, "main"], in: work)
        let marker = checkout.appendingPathComponent(".pennant-marker")
        try "still here".write(to: marker, atomically: true, encoding: .utf8)
        let again = try SkillImporter.materialize(gitURL: url, reposRoot: reposRoot)
        XCTAssertEqual(again.path, checkout.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "an existing checkout is pulled, not re-cloned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("followup/SKILL.md").path))
        let second = await preview(checkout.path)
        XCTAssertEqual(second.items.map(\.name), ["followup", "triage"])
        XCTAssertEqual(second.items.first { $0.name == "triage" }?.existingVersion, 1)
        XCTAssertEqual(second.items.first { $0.name == "triage" }?.unchanged, true)
        XCTAssertNil(second.items.first { $0.name == "followup" }?.existingVersion)
        let more = await importAll(checkout.path)
        XCTAssertEqual(more.skills.map(\.name), ["followup"])

        // A URL that cannot be cloned reports git's complaint instead of hanging or crashing.
        XCTAssertThrowsError(try SkillImporter.materialize(gitURL: "file://" + root.appendingPathComponent("missing.git").path, reposRoot: reposRoot))
    }

    // MARK: Remembered folders

    func testLocationsIncludeCustomFoldersAndRepos() async throws {
        let custom = root.appendingPathComponent("mine")
        try writeSkill("a", in: custom)
        try writeSkill("b", in: custom)
        let repo = root.appendingPathComponent("repos/tools")
        try writeSkill("c", in: repo)
        try await SkillImporter.setCustomFolders([custom.path, repo.path], store: store)
        try await SkillImporter.setRepos([repo.path: "https://example.com/tools.git"], store: store)

        let locations = await SkillImporter.locations(store: store, workingDirectory: root.path)
        let mine = try XCTUnwrap(locations.first { $0.path == custom.path })
        XCTAssertEqual(mine.kind, "custom")
        XCTAssertEqual(mine.skillCount, 2)
        XCTAssertNil(mine.origin)
        XCTAssertEqual(mine.harness, "Your folder")
        let cloned = try XCTUnwrap(locations.first { $0.path == repo.path })
        XCTAssertEqual(cloned.kind, "git")
        XCTAssertEqual(cloned.origin, "https://example.com/tools.git")
        XCTAssertEqual(cloned.skillCount, 1)
        XCTAssertTrue(locations.filter { $0.kind == "known" }.allSatisfy { $0.origin == nil })
        XCTAssertEqual(locations.map(\.path).count, Set(locations.map(\.path)).count, "no duplicates")

        // A repository registered on its own (no folder entry) still shows; a forgotten folder disappears.
        let only = root.appendingPathComponent("repos/only")
        try writeSkill("d", in: only)
        try await SkillImporter.setCustomFolders([custom.path], store: store)
        try await SkillImporter.setRepos([only.path: "git@github.com:acme/only.git"], store: store)
        let again = await SkillImporter.locations(store: store, workingDirectory: root.path)
        XCTAssertEqual(again.first { $0.path == only.path }?.kind, "git")
        XCTAssertEqual(again.first { $0.path == only.path }?.origin, "git@github.com:acme/only.git")
        XCTAssertFalse(again.contains { $0.path == repo.path })
        let folders = await SkillImporter.customFolders(store: store)
        XCTAssertEqual(folders, [custom.path])
    }

    /// A skill can ask for more thinking (`effort: high`) than the model's default, never less.
    func testASkillCanRaiseTheEffortButNeverLowerIt() {
        XCTAssertEqual(SkillImporter.outputs(["effort": "High"])?.effort, "high")
        XCTAssertNil(SkillImporter.outputs(["effort": "enormous"]))
        XCTAssertEqual(TaskRuntime.raise("medium", to: "high"), "high")
        XCTAssertEqual(TaskRuntime.raise("xhigh", to: "high"), "xhigh")
        XCTAssertNil(TaskRuntime.raise(nil, to: "high"), "a model without effort settings gets none")
        XCTAssertEqual(TaskRuntime.raise("low", to: nil), "low")
    }
}
