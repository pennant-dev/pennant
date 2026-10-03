@testable import PennantUI
import XCTest

final class ThreadMarkTests: XCTestCase {
    func testEveryMarkAtTheStartGoesAndAGoalKeepsItsIcon() {
        let session = ThreadMark.strip("⏰ 🎯 Book the team's place · work")
        XCTAssertEqual(session.text, "Book the team's place · work")
        XCTAssertEqual(session.symbol, ThreadMark.goalSymbol)
        XCTAssertEqual(ThreadMark.strip("⏰ Inbox drafts · Oct 1").symbol, "clock")
        XCTAssertEqual(ThreadMark.strip("🎯 Work session.").text, "Work session.")
        let plain = ThreadMark.strip("Team offsite in Lisbon")
        XCTAssertNil(plain.symbol)
        XCTAssertEqual(plain.text, "Team offsite in Lisbon")
    }
}
