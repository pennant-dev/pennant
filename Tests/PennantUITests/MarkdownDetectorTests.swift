@testable import PennantUI
import XCTest

final class MarkdownDetectorTests: XCTestCase {
    func testMarkdownIsRecognised() {
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("## Plan\nShip on Friday."))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("Two things:\n- the release notes\n- the checksum"))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("Steps:\n1. Build\n2. Notarize"))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("This is **important** to get right."))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("Run `make release` first."))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("See [the docs](https://pennant.dev/docs)."))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("| Name | Cost |\n|---|---:|\n| A | 1 |"))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("```swift\nlet x = 1\n```"))
        XCTAssertTrue(MarkdownDetector.looksLikeMarkdown("> Quoted from the brief"))
    }

    func testPlainTextStaysPlain() {
        XCTAssertFalse(MarkdownDetector.looksLikeMarkdown("Hi Sam,\n\nThanks for the call today. I'll send the deck by Friday.\n\nBest,\nHelder"))
        XCTAssertFalse(MarkdownDetector.looksLikeMarkdown("We shipped 3 features this week #buildinpublic #ai"))
        XCTAssertFalse(MarkdownDetector.looksLikeMarkdown("One thing:\n- the release notes"), "a single dash line isn't a list")
        XCTAssertFalse(MarkdownDetector.looksLikeMarkdown("Price: 5 * 3 = 15, and 2*4 is 8"))
        XCTAssertFalse(MarkdownDetector.looksLikeMarkdown("Read more at https://pennant.dev"))
    }
}
