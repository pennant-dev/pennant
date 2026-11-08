import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Report cards drawn with json-render's components: checked before they're posted, read as Markdown where they can't
/// be drawn, and sent to Teams as Adaptive Cards.
final class CardTests: XCTestCase {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Web/cards/samples")

    static func sample(_ name: String) throws -> JSONValue {
        try JSONValue.from(Data(contentsOf: samples.appendingPathComponent("\(name).json")))
    }

    func testTheSampleCardsPassTheCheck() throws {
        for name in ["morning-brief", "production"] {
            XCTAssertEqual(CardCatalog.problems(in: try Self.sample(name)), [], name)
        }
        XCTAssertTrue(CardCatalog.componentLines.contains("- Metric: { label: string, value: string"), CardCatalog.componentLines)
        XCTAssertFalse(CardCatalog.componentLines.contains("TextInput"), "form inputs are left out")
    }

    func testABrokenCardListsEveryProblem() throws {
        let spec = try JSONValue.parse(#"""
        {"root": "card", "elements": {
          "card": {"type": "Card", "props": {"title": "Harbor"}, "children": ["m", "chart", "gone", "words", "b1", "b2"]},
          "m": {"type": "Metric", "props": {"label": "Sign-ups", "trend": "sideways"}},
          "chart": {"type": "AreaChart", "props": {}},
          "words": {"type": "Text", "props": {"content": "Hi", "on": {"press": {"action": "reply"}}}, "children": ["m"]},
          "b1": {"type": "Button", "props": {"label": "Send it"}, "on": {"press": {"action": "reply", "params": {}}}},
          "b2": {"type": "Button", "props": {"label": "Tidy"}, "on": {"press": {"action": "setState", "params": {"statePath": "/x"}}}}
        }}
        """#)
        let problems = CardCatalog.problems(in: spec).joined(separator: "\n")
        for expected in [
            "m (Metric) props: \"value\" is missing.",
            "m (Metric) props.trend: \"sideways\" doesn't fit",
            "chart: \"AreaChart\" isn't a component here",
            "card: child \"gone\" isn't one of the elements.",
            "words: a Text holds no children",
            "words: \"on\" goes on the element, beside \"props\"",
            "b1 on.press: reply needs params.text",
            "b2 on.press: \"setState\" isn't an action here",
        ] {
            XCTAssertTrue(problems.contains(expected), "missing: \(expected)\n\(problems)")
        }
        XCTAssertEqual(CardCatalog.problems(in: ["elements": [:]]).count, 1)
    }

    func testACardReadsAsMarkdown() throws {
        let brief = CardSpec(try Self.sample("morning-brief")).plainText
        for line in ["**Good morning, Maya**", "- Mail that needs you: 3 ↓ (of 41 overnight)", "**Invoice 2026-118 is 9 days overdue**: Lena from Brandt",
                     "| From | Subject | Time |", "| Dana Okafor | Harbor renewal: redlines back | 6:12 |", "Sign-ups this week: Sun 42, Mon 61",
                     "Buttons: Send the nudge · Move Thursday's review · Later"] {
            XCTAssertTrue(brief.contains(line), "missing: \(line)\n\(brief)")
        }
        let production = CardSpec(try Self.sample("production")).plainText
        XCTAssertTrue(production.contains("**What happened**\n- 13:52 · EU West pool scaled from 5 to 8 nodes"), production)
        // The report's Markdown (the model's history, Copy) carries the card's words.
        let report = ReportCard(title: "Morning brief", verdict: "3 emails need you", spec: try Self.sample("morning-brief"))
        XCTAssertTrue(report.markdown.contains("- Harbor sign-ups: 489 ↑"), report.markdown)
    }

    func testTeamsGetsTheCardAsAnAdaptiveCard() throws {
        let report = ReportCard(title: "Morning brief", verdict: "3 emails need you", spec: try Self.sample("morning-brief"))
        guard case .card(let card, let fallback) = ChannelCards.report(report, agentName: "Pennant") else { return XCTFail("not a card") }
        let json = card.description
        XCTAssertTrue(json.contains("\"FactSet\""), json)
        XCTAssertTrue(json.contains("\"type\":\"Table\""), json)
        XCTAssertTrue(json.contains("Invoice 2026-118 is 9 days overdue"), json)
        let actions = card["actions"]?.arrayValue ?? []
        XCTAssertEqual(actions.compactMap { $0["title"]?.stringValue }, ["Send the nudge", "Move Thursday's review", "Later"])
        XCTAssertEqual(actions.first?["data"]?["text"]?.stringValue, "Send Lena the nudge")
        XCTAssertTrue(fallback.contains("Mail that needs you: 3"), fallback)
    }

    func testPostReportSendsABrokenCardBackAndPostsTheFixedOne() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let good = try Self.sample("morning-brief")
        var broken = good
        if case .object(var o) = broken, case .object(var elements)? = o["elements"] {
            elements["m1"] = ["type": "Metric", "props": ["label": "Mail that needs you"]]
            o["elements"] = .object(elements)
            broken = .object(o)
        }
        let args: (JSONValue) -> JSONValue = { ["title": "Morning brief", "verdict": "3 emails need you", "status": "watch", "card": $0] }
        let provider = ScriptedProvider([
            .init(toolCalls: [ToolCall(id: ToolCallID("r1"), name: "post_report", arguments: args(broken))]),
            .init(toolCalls: [ToolCall(id: ToolCallID("r2"), name: "post_report", arguments: args(good))]),
            .init(text: "Your morning's above."),
        ])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Brief me", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(taskID)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }

        let told = provider.requests.flatMap(\.messages).map(\.text).first { $0.contains("The card can't be drawn yet") } ?? ""
        XCTAssertTrue(told.contains("m1 (Metric) props: \"value\" is missing."), told)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let cards = messages.flatMap(\.parts).compactMap { if case .report(let r) = $0 { return r }; return nil }
        XCTAssertEqual(cards.count, 1, "only the fixed card is posted")
        XCTAssertEqual(cards.first?.spec, good)
        XCTAssertEqual(cards.first?.sections.first?.text?.contains("Mail that needs you: 3"), true, "apps from before cards see its words")
        XCTAssertEqual(cards.first?.markdown.components(separatedBy: "Mail that needs you").count, 2, "the words once, not twice")
        await s.stop()
    }
}
