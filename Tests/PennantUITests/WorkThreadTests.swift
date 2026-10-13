import PennantCore
@testable import PennantClientKit
import XCTest

/// The Work list: Pennant's threads. One started inside another thread (a skill run in Claude Code) opens from its
/// thread, and is listed too while it works, so nothing runs out of sight.
@MainActor
final class WorkThreadTests: XCTestCase {
    func testARunInsideAThreadIsListedWhileItWorks() {
        let s = ClientState()
        let pennant = AgentProfile(name: "Pennant", role: "lead")
        s.agents = [pennant]
        var chat = Conversation(agentID: pennant.id, title: "Pennant")
        chat.isMain = true
        let thread = Conversation(agentID: pennant.id, title: "Make the launch video")
        var inside = Conversation(agentID: pennant.id, title: "/make-video the launch")
        inside.parentID = thread.id
        s.conversations = [chat, thread, inside]
        var run = TaskRecord(agentID: pennant.id, conversationID: inside.id, title: "/make-video", objective: "/make-video the launch", state: .running)
        s.tasks = [run]

        XCTAssertFalse(s.isWorkThread(chat))
        XCTAssertTrue(s.isWorkThread(thread))
        XCTAssertTrue(s.isWorkThread(inside), "listed while it works")
        run.state = .cancelled
        s.tasks = [run]
        XCTAssertFalse(s.isWorkThread(inside), "done, it opens from its thread")
    }
}
