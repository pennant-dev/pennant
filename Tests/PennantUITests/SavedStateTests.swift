import PennantCore
@testable import PennantClientKit
import XCTest

@MainActor
final class SavedStateTests: XCTestCase {
    private func host() -> HostInfo {
        HostInfo(hostName: "Maya's Mac", version: "0.3.4", startedAt: Date(), mode: .everyday, inferenceEndpoint: "", inferenceModel: "harbor", inferenceReachable: true,
                 databasePath: "", activeTaskCount: 0, connectedClients: 1)
    }

    func testWhatWasShownOpensBeforeTheHostAnswers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let agent = AgentProfile(name: "Pennant", role: "assistant")
        let chat = Conversation(agentID: agent.id, title: "Pennant")
        let state = ClientState()
        state.apply(snapshot: StateSnapshot(host: host(), agents: [agent], tasks: [], conversations: [chat], desktop: DesktopStatus(), mcpServers: [], latestEventSeq: 42))
        let said = Message(conversationID: chat.id, agentID: agent.id, role: .assistant, parts: [.text("Maya lands at 7:55.")])
        state.setMessages([said], for: chat.id, prepend: false)
        state.save(to: url)

        let opened = ClientState()
        XCTAssertTrue(opened.restore(from: url))
        XCTAssertEqual(opened.host?.hostName, "Maya's Mac")
        XCTAssertEqual(opened.messages[chat.id]?.map(\.text), ["Maya lands at 7:55."])
        XCTAssertEqual(opened.lastEventSeq, 0, "the host's own snapshot decides what to replay")
        XCTAssertTrue(opened.restoredFromDisk)
        XCTAssertFalse(opened.restore(from: url), "only before the host answers")
    }

    func testASentMessageShowsUntilTheHostsCopyArrives() {
        let state = ClientState()
        let chat = ConversationID()
        let mine = Message(conversationID: chat, agentID: AgentID(), role: .user, parts: [.text("Book Dana's table")])
        state.addSending(mine)
        XCTAssertEqual(state.sending[chat]?.count, 1)
        var echoed = mine
        echoed.id = MessageID()
        state.apply(event: HostEvent(seq: 1, payload: .messageAppended(echoed)))
        XCTAssertEqual(state.sending[chat]?.count, 0)
        XCTAssertEqual(state.messages[chat]?.map(\.text), ["Book Dana's table"])
    }
}
