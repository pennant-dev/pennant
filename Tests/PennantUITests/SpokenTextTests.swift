@testable import PennantUI
import XCTest

/// Talk mode reads a reply aloud a sentence at a time, as it streams, without what reads badly aloud.
final class SpokenTextTests: XCTestCase {
    func testWholeSentencesComeOutAsTheyStreamAndTheRestWaits() {
        let first = SpokenText.sentences(in: "Sure. I checked the flights and the cheap", from: 0, final: false)
        XCTAssertEqual(first.sentences, ["Sure."])
        let more = "Sure. I checked the flights and the cheapest is $452 on Delta. Want it?"
        let second = SpokenText.sentences(in: more, from: first.offset, final: false)
        XCTAssertEqual(second.sentences, ["I checked the flights and the cheapest is $452 on Delta."])
        let last = SpokenText.sentences(in: more, from: second.offset, final: true)
        XCTAssertEqual(last.sentences, ["Want it?"])
        XCTAssertEqual(last.offset, more.count)
    }

    func testDecimalsAndAbbreviationsDontSplitASentence() {
        let r = SpokenText.sentences(in: "It's 3.5 hours via St.Louis today", from: 0, final: true)
        XCTAssertEqual(r.sentences, ["It's 3.5 hours via St.Louis today"])
    }

    func testMarkdownLinksCodeAndEmojiAreNotReadOut() {
        XCTAssertEqual(SpokenText.clean("**Done:** the post is [live](https://example.com) 🎉"), "Done: the post is live")
        XCTAssertEqual(SpokenText.clean("- Run `pennant chrome` once"), "Run pennant chrome once")
        XCTAssertEqual(SpokenText.clean("## Flights"), "Flights")
        XCTAssertNil(SpokenText.clean("```swift\nlet x = 1\n```"))
        XCTAssertNil(SpokenText.clean("https://example.com/report"))
        XCTAssertEqual(SpokenText.clean("| Delta | $452 |"), "Delta, $452")
    }

    func testItsOwnVoiceComingBackIsNotTakenForTheOwner() {
        XCTAssertTrue(SpokenText.isEcho("the cheapest is", of: "I checked the flights and the cheapest is $452 on Delta."))
        XCTAssertFalse(SpokenText.isEcho("stop that", of: "I checked the flights and the cheapest is $452 on Delta."))
        // Without echo cancellation, a garbled echo is still mostly its own words; the owner's aren't.
        XCTAssertGreaterThanOrEqual(SpokenText.echoShare("checked the flight and the cheapest", of: "I checked the flights and the cheapest is $452 on Delta."), 0.5)
        XCTAssertLessThan(SpokenText.echoShare("no wait book the Delta one", of: "I checked the flights and the cheapest is $452 on Delta."), 0.5)
    }

    /// A spoken reply is read out; a report with links and details is said in a sentence or two instead.
    func testLongMessagesAreSaidAsTheirGist() {
        XCTAssertFalse(SpokenText.isLong("Sure, I'll check your calendar and tell you what's free tomorrow morning."))
        XCTAssertTrue(SpokenText.isLong("The pull request is up: https://github.com/o/r/pull/36\n\nIt's the one line, main.tf:97, the org name now reads ${var.namespace}-${var.environment}, so new orgs come out as app-dev, app-stage, app-prod. Linked to #35, checks are green. I didn't run a plan or touch the three existing orgs; renaming those and applying this still sit with you."))
    }
}
