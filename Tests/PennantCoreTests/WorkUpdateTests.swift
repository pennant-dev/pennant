@testable import PennantCore
import Foundation
import XCTest

/// Updates from threads in the Pennant chat, and the chat's flag, as they travel between host and apps.
final class WorkUpdateTests: XCTestCase {
    func testAnUpdateTravelsAsAMessagePart() throws {
        let update = WorkUpdate(kind: .approval, threadID: ConversationID("c-123456789"), taskID: TaskID("t-1"), thread: "LinkedIn post", text: "Post: launch",
                                approvalID: "a-1", outcome: "Approved")
        let data = try JSONEncoder().encode(ContentPart.update(update))
        guard case .update(let back) = try JSONDecoder().decode(ContentPart.self, from: data) else { return XCTFail("not an update") }
        XCTAssertEqual(back, update)
        XCTAssertTrue(back.modelLine.contains("“LinkedIn post” (thread c-123456)") && back.modelLine.contains("Approved"), back.modelLine)
    }

    func testAKindFromANewerHostReadsAsAResult() throws {
        let json = #"{"id":"u1","kind":"celebrated","threadID":"c1","thread":"T","text":"Yay","createdAt":0}"#
        let update = try JSONDecoder().decode(WorkUpdate.self, from: Data(json.utf8))
        XCTAssertEqual(update.kind, .finished)
    }

    func testConversationsFromBeforeTheChatArentIt() throws {
        let json = #"{"id":"c1","agentID":"a1","createdAt":0,"updatedAt":0}"#
        let c = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertFalse(c.isMain)
        var chat = Conversation(agentID: AgentID("a1"), title: "Pennant")
        chat.isMain = true
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat))
        XCTAssertTrue(back.isMain)
    }
}
