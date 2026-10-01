import PennantCore
import XCTest

final class CoreTests: XCTestCase {
    func testTaskStateMachine() {
        XCTAssertTrue(TaskState.queued.canTransition(to: .running))
        XCTAssertTrue(TaskState.running.canTransition(to: .waitingForDesktop))
        XCTAssertTrue(TaskState.waitingForUser.canTransition(to: .queued))
        XCTAssertFalse(TaskState.completed.canTransition(to: .running))
        XCTAssertFalse(TaskState.queued.canTransition(to: .completed))
        XCTAssertFalse(TaskState.running.canTransition(to: .running))
        for s in TaskState.allCases where s.isTerminal { XCTAssertTrue(TaskState.allCases.allSatisfy { !s.canTransition(to: $0) }) }
    }

    func testWireMessageRoundTrip() throws {
        let agent = AgentProfile(name: "Pennant", role: "assistant")
        let event = HostEvent(seq: 42, payload: .agentUpserted(agent))
        let data = try WireMessage.event(event).encoded()
        let back = try WireMessage.decode(data)
        guard case .event(let e) = back, case .agentUpserted(let a) = e.payload else { return XCTFail() }
        XCTAssertEqual(a.id, agent.id)
        XCTAssertEqual(e.seq, 42)

        let cmd = ClientCommand(body: .sendMessage(agentID: agent.id, conversationID: nil, text: "hi", attachments: []))
        let back2 = try WireMessage.decode(try WireMessage.command(cmd).encoded())
        guard case .command(let c) = back2, case .sendMessage(let id, _, let text, _) = c.body else { return XCTFail() }
        XCTAssertEqual(id, agent.id)
        XCTAssertEqual(text, "hi")

    }

    func testScreenFrameCodec() throws {
        let header = ScreenFrameHeader(sequence: 7, width: 100, height: 50, owner: .human)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let encoded = try ScreenFrameCodec.encode(header: header, jpeg: jpeg)
        let (h, d) = try ScreenFrameCodec.decode(encoded)
        XCTAssertEqual(h.sequence, 7)
        XCTAssertEqual(h.owner, .human)
        XCTAssertEqual(d, jpeg)
        XCTAssertThrowsError(try ScreenFrameCodec.decode(Data([0, 0])))
    }

    func testJSONValueAndContentParts() throws {
        let v: JSONValue = ["a": 1, "b": [true, "x", nil], "c": ["d": 2.5]]
        let text = v.compactText
        let parsed = try JSONValue.parse(text)
        XCTAssertEqual(parsed, v)
        XCTAssertEqual(parsed["c"]?["d"]?.doubleValue, 2.5)
        XCTAssertEqual(parsed["a"]?.intValue, 1)
        let call = ToolCall(name: "click", arguments: ["x": 10])
        let parts: [ContentPart] = [.text("hi"), .reasoning("thinking"), .toolCall(call), .toolResult(ToolResult.text(call.id, name: "click", "ok"))]
        let data = try JSONCodec.encode(parts)
        let back = try JSONCodec.decode([ContentPart].self, from: data)
        XCTAssertEqual(back, parts)
    }

    func testKeyChordParsing() {
        let chord = KeyChord(parsing: "cmd+shift+s")
        XCTAssertTrue(chord.command && chord.shift && !chord.option)
        XCTAssertEqual(chord.key, "s")
        XCTAssertEqual(KeyChord(parsing: "return").key, "return")
    }

    func testTransientEvents() {
        XCTAssertTrue(EventPayload.hostStatus(HostInfo(hostName: "m", version: "1", startedAt: Date(), mode: .everyday, inferenceEndpoint: "", inferenceModel: "", inferenceReachable: false, databasePath: "", activeTaskCount: 0, connectedClients: 0)).isTransient)
        XCTAssertFalse(EventPayload.agentRemoved(AgentID()).isTransient)
    }
}
