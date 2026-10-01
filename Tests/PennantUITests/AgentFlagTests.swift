import PennantCore
@testable import PennantUI
import SwiftUI
import XCTest

final class AgentFlagTests: XCTestCase {
    func testFlagTokensRoundTrip() {
        for glyph in AgentGlyph.allCases {
            XCTAssertEqual(AgentGlyph.parse(glyph.token), glyph)
        }
        XCTAssertNil(AgentGlyph.parse("shape:wave"))
        XCTAssertNil(AgentGlyph.parse("flag:unknown"))
    }

    func testOwnFlagWinsOverTheGuess() {
        XCTAssertEqual(AgentGlyph.resolve(avatar: "flag:camera", name: "Inbox", role: "email"), .camera)
    }

    func testLegacyAgentsGetAFlagForTheirJob() {
        let cases: [(String, String, AgentGlyph)] = [
            ("Emailer", "Keeps my email under control", .envelope),
            ("Poster", "Researches trends and drafts LinkedIn posts", .megaphone),
            ("Demo Recorder", "Records product demos", .play),
            ("Acme Ops", "Releases, deploys and infrastructure health", .pulse),
            ("Architect", "Knows the codebase and draws diagrams", .nodes),
            ("Pennant", "personal assistant who operates this Mac", .compass),
        ]
        for (name, role, glyph) in cases {
            XCTAssertEqual(AgentGlyph.resolve(avatar: "shape:circle", name: name, role: role), glyph, name)
        }
    }

    func testTheNameIsReadBeforeTheRole() {
        // "operates" is not "ops": only whole-word prefixes count, and the name decides first.
        XCTAssertEqual(AgentGlyph.guess(name: "Pennant", role: "operates this Mac"), .compass)
        XCTAssertNil(AgentGlyph.guess(name: "Zed", role: "does things"))
    }

    func testUnknownAgentsFallBackToTheirOldShapeThenTheDefault() {
        XCTAssertEqual(AgentGlyph.resolve(avatar: "shape:cloud", name: "Zed", role: "does things"), .moon)
        XCTAssertEqual(AgentGlyph.resolve(avatar: "🙂", name: "Zed", role: "does things"), AgentGlyph.defaultGlyph)
    }
}
