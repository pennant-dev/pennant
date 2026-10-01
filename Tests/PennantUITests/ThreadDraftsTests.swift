@testable import PennantUI
import PennantCore
import XCTest

/// What you type stays in the thread you typed it in.
final class ThreadDraftsTests: XCTestCase {
    func testEachThreadKeepsItsOwnDraft() {
        var drafts = ThreadDrafts()
        let a = ConversationID(), b = ConversationID()
        // Typed in A, switch to B: B's box is empty, not A's text.
        XCTAssertEqual(drafts.switching(from: a, to: b, leaving: .init(text: "half a thought")), .init())
        // Back to A: its text is there. B's (empty) draft doesn't linger.
        XCTAssertEqual(drafts.switching(from: b, to: a, leaving: .init()).text, "half a thought")
    }

    func testANewThreadHasItsOwnDraftUntilItStarts() {
        var drafts = ThreadDrafts()
        let a = ConversationID(), started = ConversationID()
        // Typed in an unstarted thread, then opened A: A doesn't get that text, and it comes back with the new thread.
        XCTAssertEqual(drafts.switching(from: nil, to: a, leaving: .init(text: "new idea")), .init())
        XCTAssertEqual(drafts.switching(from: a, to: nil, leaving: .init()).text, "new idea")
        // Sending the first message gives the new thread its id: the box stays as it is (empty after the send).
        drafts.startedHere = started
        XCTAssertEqual(drafts.switching(from: nil, to: started, leaving: .init()), .init())
        XCTAssertEqual(drafts.switching(from: started, to: nil, leaving: .init()), .init(), "the sent text doesn't come back")
    }
}
