@testable import PennantUI
import XCTest

final class SkillDiffTests: XCTestCase {
    func testMarksRemovedAndAddedLinesAndKeepsTheRest() {
        let lines = SkillDiff.lines(from: ["1. Read mail", "2. Draft replies for everything", "3. Report"],
                                    to: ["1. Read mail", "2. Draft a reply only to people", "3. Report"])
        XCTAssertEqual(lines.map(\.kind), [.same, .removed, .added, .same])
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["2. Draft a reply only to people"])
    }

    func testIdenticalVersionsHaveNoChanges() {
        XCTAssertTrue(SkillDiff.lines(from: ["a", "b"], to: ["a", "b"]).allSatisfy { $0.kind == .same })
    }
}
