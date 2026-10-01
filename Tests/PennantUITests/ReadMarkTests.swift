import PennantCore
@testable import PennantClientKit
import XCTest

@MainActor
final class ReadMarkTests: XCTestCase {
    private func state(_ defaults: UserDefaults) -> ClientState {
        let s = ClientState()
        s.persistReadMarks(in: defaults)
        return s
    }

    private func freshDefaults() -> UserDefaults {
        let name = "ReadMarkTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testOldHistoryIsReadAndNewRepliesAreNot() {
        let s = state(freshDefaults())
        let agent = AgentProfile(name: "Emailer", role: "email")
        s.agents = [agent]
        s.conversations = [Conversation(agentID: agent.id, updatedAt: Date().addingTimeInterval(-3600))]
        XCTAssertFalse(s.hasUnread(agentID: agent.id), "history from before the first launch counts as read")
        let fresh = Conversation(agentID: agent.id, updatedAt: Date().addingTimeInterval(5))
        s.conversations.append(fresh)
        XCTAssertTrue(s.hasUnread(agentID: agent.id), "a reply after launch is unread")
        XCTAssertFalse(s.needsUser(agentID: agent.id), "but unread alone isn't \"needs you\": that flag is for questions and approvals")
        XCTAssertEqual(s.conversationToOpen(agentID: agent.id), fresh.id)
        s.markRead(fresh.id)
        XCTAssertFalse(s.hasUnread(agentID: agent.id))
    }

    func testOpeningAnAgentGoesToWhatNeedsYouEvenWhenItIsOlder() {
        let s = state(freshDefaults())
        let agent = AgentProfile(name: "Coder", role: "code")
        s.agents = [agent]
        let waiting = Conversation(agentID: agent.id, updatedAt: Date().addingTimeInterval(-7200))
        let newer = (0 ..< 6).map { i in Conversation(agentID: agent.id, updatedAt: Date().addingTimeInterval(Double(-60 * i))) }
        s.conversations = [waiting] + newer
        var task = TaskRecord(agentID: agent.id, conversationID: waiting.id, title: "fix", objective: "fix")
        task.state = .waitingForUser
        s.tasks = [task]
        XCTAssertTrue(s.needsUser(agentID: agent.id))
        XCTAssertTrue(s.conversationNeedsUser(waiting.id))
        XCTAssertEqual(s.conversationToOpen(agentID: agent.id), waiting.id, "buried under six newer threads, it still comes first")
        s.markAllRead(agentID: agent.id)
        XCTAssertFalse(s.hasUnread(agentID: agent.id))
    }

    func testReadMarksSurviveARelaunch() {
        let d = freshDefaults()
        let agent = AgentProfile(name: "Poster", role: "posts")
        let convo = Conversation(agentID: agent.id, updatedAt: Date().addingTimeInterval(10))
        let first = state(d)
        first.conversations = [convo]
        first.markRead(convo.id)
        let second = state(d)
        second.conversations = [convo]
        XCTAssertFalse(second.hasUnread(agentID: agent.id))
    }

    func testWaitingForTheUserRaisesTheFlag() {
        let s = state(freshDefaults())
        var agent = AgentProfile(name: "Ops", role: "ops")
        agent.status = .waitingForUser
        s.agents = [agent]
        XCTAssertTrue(s.needsUser(agentID: agent.id))
    }
}
