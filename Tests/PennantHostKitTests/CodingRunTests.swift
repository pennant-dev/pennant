import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Coding runs: Pennant's `code` tool hands a change to the coding engine in a thread of its own, in the project asked
/// for by name, or the default one.
final class CodingRunTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func folder(_ name: String) throws -> String {
        let url = paths.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// `code` starts a coding run in a thread of its own under the one that asked, in the project it named. (On the
    /// Pennant engine with a scripted model, so no real coding CLI runs.)
    func testCodeStartsACodingThreadUnderTheOneThatAskedInTheProjectItNamed() async throws {
        let app = try folder("app"), site = try folder("site")
        let code = ToolCall(id: ToolCallID("c1"), name: "code", arguments: ["request": "Fix the typo in the README", "folder": "SITE"])
        let provider = ScriptedProvider([.init(toolCalls: [code]), .init(text: "Started a coding run.")])
        provider.codingTurns = [.init(text: "There was no typo to fix.")]
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.coding = HostConfig.Coding(engine: .pennant, projects: [CodingProject(path: app), CodingProject(path: site)])
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, asking, taskID) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "Fix the README typo", attachments: [])
        for _ in 0..<400 where !(try await s.store.task(taskID)?.state.isTerminal ?? false) { try await Task.sleep(for: .milliseconds(20)) }

        // The lead was told which projects there are.
        let leadPrompt = provider.requests.first?.messages.first?.text ?? ""
        XCTAssertTrue(leadPrompt.contains("## Coding projects") && leadPrompt.contains("- site: \(site)"), leadPrompt)
        let threads = try await s.store.listConversations(agentID: pennant.id)
        let run = try XCTUnwrap(threads.first { $0.isCodingRun }, "a coding thread was started")
        XCTAssertEqual(run.parentID, asking, "it sits under the thread that asked")
        XCTAssertEqual(run.agentID, pennant.id)
        XCTAssertEqual(run.engine, .pennant)
        XCTAssertEqual(run.workingDirectory, site, "the project named, whatever its case")
        let runTasks = try await s.store.listTasks(agentID: pennant.id, includeFinished: true).filter { $0.conversationID == run.id }
        XCTAssertEqual(runTasks.first?.requestedByTaskID, taskID)
        await s.stop()
    }

    /// A request names a project, a folder's path, or nothing (the first project); an unknown name says which exist.
    func testARequestFindsItsProjectByNameOrFallsBackToTheDefault() throws {
        let coding = HostConfig.Coding(projects: [CodingProject(path: "/work/app"), CodingProject(name: "Marketing site", path: "/work/www")])
        XCTAssertEqual(try TaskRuntime.projectFolder(nil, in: coding), "/work/app")
        XCTAssertEqual(try TaskRuntime.projectFolder("  ", in: coding), "/work/app")
        XCTAssertEqual(try TaskRuntime.projectFolder("marketing site", in: coding), "/work/www")
        XCTAssertEqual(try TaskRuntime.projectFolder("/work/other", in: coding), "/work/other")
        XCTAssertEqual(try TaskRuntime.projectFolder("~/x", in: coding), (NSHomeDirectory() as NSString).appendingPathComponent("x"))
        XCTAssertThrowsError(try TaskRuntime.projectFolder("blog", in: coding)) { error in
            XCTAssertTrue("\(error)".contains("Projects: app, Marketing site"), "\(error)")
        }
        XCTAssertThrowsError(try TaskRuntime.projectFolder(nil, in: HostConfig.Coding()), "no projects, no default")
    }
}
