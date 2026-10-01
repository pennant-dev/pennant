import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class ReportTests: XCTestCase {
    func testAgentsLooseJSONBecomesACardAndReadsBackAsMarkdown() throws {
        let json = #"""
        {"title": "Infrastructure · Thu", "verdict": "Healthy with 1 thing to watch", "status": "warning",
         "sections": [
           {"title": "At a glance", "stats": [{"label": "Nodes ready", "value": 27, "status": "ok"}, {"label": "5xx", "value": "0.2%"}]},
           {"table": {"columns": ["System", "Status"], "rows": [["Prod east", {"text": "Healthy", "status": "healthy"}], ["Cloudflare", "Not checked"]]}},
           {"title": "Watching", "items": ["Node memory 104%", {"text": "Karpenter can't add nodes", "detail": "general pool", "status": "critical"}]}
         ]}
        """#
        let r = try JSONDecoder().decode(ReportCard.self, from: Data(json.utf8))
        XCTAssertEqual(r.status, .watch)
        XCTAssertEqual(r.sections[0].stats?.first?.value, "27")
        XCTAssertEqual(r.sections[0].stats?.first?.status, .good)
        XCTAssertEqual(r.sections[1].table?.rows[0][1].status, .good)
        XCTAssertEqual(r.sections[1].table?.rows[1][1].text, "Not checked")
        XCTAssertEqual(r.sections[2].items?.first?.text, "Node memory 104%")
        XCTAssertEqual(r.sections[2].items?.last?.status, .bad)
        let md = r.markdown
        XCTAssertTrue(md.contains("Watch: Healthy with 1 thing to watch"))
        XCTAssertTrue(md.contains("| Prod east | Healthy (Good) |"))
        XCTAssertTrue(md.contains("- [Needs action] Karpenter can't add nodes: general pool"))
        // A message carrying it survives the store's round trip.
        let part = ContentPart.report(r)
        XCTAssertEqual(try JSONDecoder().decode(ContentPart.self, from: JSONEncoder().encode(part)), part)
    }

    func testPostReportPutsACardInTheConversation() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let post = ToolCall(id: ToolCallID("r1"), name: "post_report", arguments: ["title": "Run summary", "verdict": "2 drafts waiting", "status": "good",
                                                                                   "sections": .array([.object(["stats": .array([.object(["label": "Drafts", "value": "2"])])])])])
        let provider = ScriptedProvider([.init(toolCalls: [post]), .init(text: "Report posted.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Summarize", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await s.store.task(taskID)?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let card = messages.flatMap(\.parts).compactMap { if case .report(let r) = $0 { return r }; return nil }.first
        XCTAssertEqual(card?.verdict, "2 drafts waiting")
        XCTAssertEqual(card?.sections.first?.stats?.first?.value, "2")
        // The model sees it as Markdown on the next turn.
        let seen = provider.requests.last?.messages.map(\.text).joined() ?? ""
        XCTAssertTrue(seen.contains("[report card]"), seen)
        await s.stop()
    }

    func testSkillsDeclareTheirCardsInFrontMatter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        ---
        name: inbox
        description: Draft replies.
        report: Inbox · {date}
        report-sections: At a glance; Drafts waiting; FYI
        approval: Outlook · reply
        approval-label: Approve & send
        approval-action: microsoft_365__mail_reply
        approval-text-field: body
        ---
        Do the thing.
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let skill = try SkillImporter.parse(skillFile: dir.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(skill.outputs?.report?.sections, ["At a glance", "Drafts waiting", "FYI"])
        XCTAssertEqual(skill.outputs?.approval?.action, "microsoft_365__mail_reply")
        let guide = try XCTUnwrap(skill.outputs?.guide)
        XCTAssertTrue(guide.contains("post_report"))
        XCTAssertTrue(guide.contains("on_approve {tool: \"microsoft_365__mail_reply\", text_field: \"body\"}"))
        // A plain skill declares nothing.
        XCTAssertNil(SkillImporter.outputs(["name": "x"]))
    }
}
