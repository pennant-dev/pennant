import PennantCore
@testable import PennantHostKit
import XCTest

final class ClaudeCodeEngineTests: XCTestCase {
    private func parse(_ json: String) -> ClaudeCodeEngine.Event? { ClaudeCodeEngine.parse(Data(json.utf8)) }

    func testParsesTheStreamClaudeCodeWrites() throws {
        guard case .started(let sid, let model)? = parse(#"{"type":"system","subtype":"init","session_id":"s-1","model":"claude-opus-5-5"}"#) else { return XCTFail("init") }
        XCTAssertEqual(sid, "s-1"); XCTAssertEqual(model, "claude-opus-5-5")
        XCTAssertNil(parse(#"{"type":"system","subtype":"hook_started","session_id":"s-1"}"#), "hooks aren't chat")

        guard case .assistant(let pieces)? = parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/a.swift"}}]}}"#) else { return XCTFail("assistant") }
        XCTAssertEqual(pieces.count, 2)
        guard case .toolUse(let id, let name, let input) = pieces[1] else { return XCTFail("tool use") }
        XCTAssertEqual(id, "t1"); XCTAssertEqual(name, "Read"); XCTAssertEqual(input["file_path"]?.stringValue, "/tmp/a.swift")

        guard case .toolResults(let results)? = parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"1\thello"}],"is_error":false}]}}"#) else { return XCTFail("results") }
        XCTAssertEqual(results.first?.id, "t1"); XCTAssertEqual(results.first?.text, "1\thello")

        guard case .finished(let f)? = parse(#"{"type":"result","subtype":"success","is_error":false,"result":"hello","session_id":"s-1","total_cost_usd":0.145,"num_turns":2,"usage":{"input_tokens":4,"cache_creation_input_tokens":100,"cache_read_input_tokens":300,"output_tokens":131}}"#) else { return XCTFail("result") }
        XCTAssertEqual(f.text, "hello"); XCTAssertFalse(f.isError); XCTAssertEqual(f.costUSD, 0.145)
        XCTAssertEqual(f.inputTokens, 404); XCTAssertEqual(f.cachedInputTokens, 300); XCTAssertEqual(f.outputTokens, 131)
    }

    func testArgumentsResumeAndRoutePermissionsToPennant() {
        let engine = ClaudeCodeEngine(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let args = engine.arguments(prompt: "fix it", sessionID: "s-9", mcpConfig: URL(fileURLWithPath: "/tmp/mcp.json"))
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "fix it"])
        XCTAssertTrue(args.contains("acceptEdits"))
        XCTAssertEqual(args.last, "s-9")
        XCTAssertTrue(args.contains("mcp__pennant__approve"))
        XCTAssertTrue(args.contains("Bash(git status:*)"))
        XCTAssertFalse(args.contains { $0.hasPrefix("Bash(rm") }, "nothing destructive is pre-approved")
        XCTAssertTrue(args.contains("Bash(gh pr list:*)"), "GitHub reads don't ask")
        XCTAssertFalse(args.contains { $0.hasPrefix("Bash(gh api") || $0.hasPrefix("Bash(gh pr merge") || $0.hasPrefix("Bash(gh pr close") }, "GitHub writes still ask")
    }

    func testModeAndModelReachTheCLI() {
        let engine = ClaudeCodeEngine(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let plan = engine.arguments(prompt: "p", sessionID: nil, mcpConfig: nil, mode: .plan, model: "opus")
        XCTAssertEqual(plan[plan.firstIndex(of: "--permission-mode")! + 1], "plan")
        XCTAssertEqual(plan[plan.firstIndex(of: "--model")! + 1], "opus")
        let plain = engine.arguments(prompt: "p", sessionID: nil, mcpConfig: nil)
        XCTAssertEqual(plain[plain.firstIndex(of: "--permission-mode")! + 1], "acceptEdits")
        XCTAssertFalse(plain.contains("--model"), "no model: the CLI's default")
    }

    func testAskUserQuestionBecomesAChoiceCard() throws {
        let raw = #"{"questions":[{"options":[{"label":"Close platform #60 (Recommended)","description":"Safe to close."},{"label":"Close core-infra #67","description":"Less clear-cut."}],"multiSelect":true,"header":"Cleanup","question":"Which PRs should I clean up?"},{"question":"Post comments?","header":"","options":[{"label":"Yes"},{"label":"No"}]}]}"#
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        let q = try XCTUnwrap(ChoiceQuestion(claudeInput: input))
        XCTAssertEqual(q.items.count, 2)
        XCTAssertEqual(q.items[0].header, "Cleanup")
        XCTAssertTrue(q.items[0].multiSelect)
        XCTAssertEqual(q.items[0].options.map(\.label), ["Close platform #60 (Recommended)", "Close core-infra #67"])
        XCTAssertEqual(q.items[0].options[0].description, "Safe to close.")
        XCTAssertFalse(q.items[1].multiSelect)
        XCTAssertNil(ChoiceQuestion(claudeInput: .object([:])), "no questions, no card")

        // The card survives the wire as a message part, answers included.
        var answered = q
        answered.answers = ["Which PRs should I clean up?": "Close platform #60 (Recommended)", "Post comments?": "No"]
        let data = try JSONEncoder().encode(ContentPart.choices(answered))
        guard case .choices(let back) = try JSONDecoder().decode(ContentPart.self, from: data) else { return XCTFail("part") }
        XCTAssertEqual(back, answered)
        XCTAssertTrue(back.summary.contains("Post comments? → No"))
    }
}
