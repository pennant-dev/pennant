import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class ChannelCardTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func json(_ v: JSONValue) -> String { String(decoding: try! JSONEncoder().encode(v), as: UTF8.self) }

    func testCardsCarryTheirContentAndButtons() throws {
        var a = ApprovalRequest(taskID: TaskID(), title: "LinkedIn post: LaunchConf booth", destination: "Harbor LinkedIn", text: "Meet us at booth 1748.", notes: "")
        guard case .card(let pending, let fallback) = ChannelCards.approval(a, agentName: "Poster") else { return XCTFail("a card") }
        let pj = json(pending)
        XCTAssertTrue(pj.contains("Action.Submit") && pj.contains("\"verdict\":\"approve\"") && pj.contains("\"verdict\":\"requestChanges\"") && pj.contains(a.id))
        XCTAssertTrue(pj.contains("Meet us at booth 1748."))
        XCTAssertTrue(fallback.contains("Poster needs your approval"))

        a.state = .approved
        a.decidedBy = MessageAuthor(id: PersonID("p"), name: "Maya")
        guard case .card(let decided, _) = ChannelCards.approval(a, agentName: "Poster") else { return XCTFail("a card") }
        XCTAssertFalse(json(decided).contains("Action.Submit"), "a decided card has no buttons")
        XCTAssertTrue(json(decided).contains("Approved by Maya"))

        let q = ChoiceQuestion(items: [.init(question: "Which PRs?", header: "Cleanup", multiSelect: true, options: [.init(label: "#60"), .init(label: "#67")]),
                                      .init(question: "Post comments?", options: [.init(label: "Yes"), .init(label: "No")])])
        guard case .card(let choices, let choiceText) = ChannelCards.choices(q, taskID: TaskID(), agentName: "Coder") else { return XCTFail("a card") }
        XCTAssertTrue(json(choices).contains("Input.ChoiceSet"))
        XCTAssertTrue(choiceText.contains("1. #60"), "numbered options where there are no cards")
        let answers = ChannelCards.answers(q, from: ["q0": "#60,#67", "q1": "", "q1_other": "Only on #60"])
        XCTAssertEqual(answers["Which PRs?"], "#60, #67")
        XCTAssertEqual(answers["Post comments?"], "Only on #60")

        guard case .card(_, let simpleText) = ChannelCards.simple(title: "Deploy?", text: "v2.3 is ready", facts: [("Env", "prod")], buttons: ["Ship it", "Wait"]) else { return XCTFail("a card") }
        XCTAssertTrue(simpleText.contains("Reply with: Ship it / Wait"))
    }

    func testApprovalsReachPeopleWhoAskedAndTheirTapsDecideAsThem() async throws {
        let store = try SQLiteStore(paths: paths)
        let bus = EventBus()
        let channels = ChannelService(paths: paths, keychain: KeychainStore(service: "test.cards", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true), store: store, eventBus: bus)
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var cards: [(String, String)] = []
            var texts: [(String, String)] = []
            var decisions: [(ApprovalDecision, String)] = []
            var answers: [[String: String]] = []
        }
        let box = Box()
        await channels.useSender { c, t in box.lock.withLock { box.texts.append((c.name, t)) } }
        await channels.useCardSender { c, card in
            box.lock.withLock { box.cards.append((c.name, String(decoding: try! JSONEncoder().encode(card), as: UTF8.self))) }
            return "activity-\(c.name)"
        }
        await channels.start(.init(submit: { _, c, _, _ in c ?? ConversationID() }, defaultAgent: { AgentID() }, notice: { _ in },
                                   decideApproval: { d, by in box.lock.withLock { box.decisions.append((d, by.name)) } },
                                   answerChoices: { _, _, a, _ in box.lock.withLock { box.answers.append(a) } },
                                   agentName: { _ in "Poster" }))
        var maya = ChannelContact(kind: .teams, address: "a:1", name: "Maya", personID: PersonID("owner"), allowed: true)
        maya.forwardApprovals = true
        maya.details = ["serviceURL": "https://smba.example/", "aad": "oid-h"]
        var sam = ChannelContact(kind: .telegram, address: "42", name: "Sam", allowed: true)
        sam.forwardApprovals = true
        try await channels.upsert(maya)
        try await channels.upsert(sam)
        try await Task.sleep(for: .milliseconds(100))

        // Poster asks for approval in its own conversation.
        let approval = ApprovalRequest(taskID: TaskID(), title: "LinkedIn post", destination: "Harbor LinkedIn", text: "Booth 1748", notes: "")
        let message = Message(conversationID: ConversationID(), agentID: AgentID(), role: .assistant, parts: [.approval(approval)])
        await bus.publish(HostEvent(seq: 0, payload: .messageAppended(message)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.lock.withLock { box.cards.map(\.0) }, ["Maya"], "Teams gets the card")
        XCTAssertTrue(box.lock.withLock { box.texts.contains { $0.0 == "Sam" && $0.1.contains("Poster needs your approval") } }, "Telegram gets its text")

        // Maya taps Request changes without a note, then with one.
        await channels.cardSubmitted(["pennant": "approval", "approvalID": approval.id, "verdict": "requestChanges"], from: maya.id)
        XCTAssertTrue(box.lock.withLock { box.decisions.isEmpty })
        XCTAssertTrue(box.lock.withLock { box.texts.contains { $0.0 == "Maya" && $0.1.contains("Add a note") } })
        await channels.cardSubmitted(["pennant": "approval", "approvalID": approval.id, "verdict": "approve"], from: maya.id)
        XCTAssertEqual(box.lock.withLock { box.decisions.first?.0.verdict }, .approve)
        XCTAssertEqual(box.lock.withLock { box.decisions.first?.1 }, "Maya", "decided as the person who tapped")

        // Decided: the card is replaced, without buttons.
        var decided = approval
        decided.state = .approved
        decided.decidedBy = MessageAuthor(id: PersonID("owner"), name: "Maya")
        var updated = message
        updated.parts = [.approval(decided)]
        await bus.publish(HostEvent(seq: 0, payload: .messageFinalized(updated)))
        try await Task.sleep(for: .milliseconds(200))
        let last = box.lock.withLock { box.cards.last?.1 ?? "" }
        XCTAssertTrue(last.contains("Approved by Maya") && !last.contains("Action.Submit"))
        await channels.stop()
    }

    /// From Teams, Pennant asks Coder; Coder stops for permission in its own conversation, which nobody watches.
    /// The card goes to the Teams chat the request came from.
    func testADelegatedAgentsApprovalsReachThePersonWhoStartedIt() async throws {
        let store = try SQLiteStore(paths: paths)
        let bus = EventBus()
        let channels = ChannelService(paths: paths, keychain: KeychainStore(service: "test.cards", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true), store: store, eventBus: bus)
        final class Box: @unchecked Sendable { let lock = NSLock(); var cards: [String] = [] }
        let box = Box()
        await channels.useCardSender { c, _ in box.lock.withLock { box.cards.append(c.name) }; return "a1" }
        await channels.start(.init(submit: { _, c, _, _ in c ?? ConversationID() }, defaultAgent: { AgentID() }, notice: { _ in }, agentName: { _ in "Coder" }))

        let pennant = AgentID(), coder = AgentID()
        let teamsThread = ConversationID(), coderConversation = ConversationID()
        var maya = ChannelContact(kind: .teams, address: "a:1", name: "Maya", personID: PersonID("owner"), allowed: true, agentID: pennant, conversationID: teamsThread)
        maya.details = ["serviceURL": "https://smba.example/"]
        try await channels.upsert(maya)
        let asking = TaskRecord(agentID: pennant, conversationID: teamsThread, title: "fix the build", objective: "fix the build")
        try await store.upsertTask(asking)
        var coding = TaskRecord(agentID: coder, conversationID: coderConversation, title: "fix it", objective: "fix it")
        coding.requestedByTaskID = asking.id
        try await store.upsertTask(coding)
        try await Task.sleep(for: .milliseconds(100))

        let permission = ApprovalRequest(taskID: coding.id, title: "Run a command", destination: "Coder · ~/app", text: "swift build | head", notes: "")
        await bus.publish(HostEvent(seq: 0, payload: .messageAppended(Message(conversationID: coderConversation, agentID: coder, taskID: coding.id, role: .assistant, parts: [.approval(permission)]))))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.lock.withLock { box.cards }, ["Maya"])
        await channels.stop()
    }
}
