import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class ChannelTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var sent: [(String, String)] = []
        var submitted: [(AgentID, ConversationID?, String, String)] = []
    }

    func testRepliesGoWhereTheyShouldAndOnlyOwnThreadsAreRelayed() async throws {
        let store = try SQLiteStore(paths: paths)
        let bus = EventBus()
        let channels = ChannelService(paths: paths, keychain: KeychainStore(service: "test.channels", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true), store: store, eventBus: bus)
        let rec = Recorder()
        let assistant = AgentID(), coder = AgentID()
        let ownThread = ConversationID(), outreach = ConversationID()
        await channels.useSender { c, text in rec.lock.withLock { rec.sent.append((c.name, text)) } }
        await channels.start(.init(
            submit: { agent, conversation, text, author in
                rec.lock.withLock { rec.submitted.append((agent, conversation, text, author.name)) }
                return conversation ?? ownThread
            },
            defaultAgent: { assistant }, notice: { _ in }))

        let sam = ChannelContact(kind: .telegram, address: "4242", name: "Sam", allowed: true)
        try await channels.upsert(sam)

        // Sam writes first: their own thread with the built-in assistant.
        await channels.received("hi, what's on today?", from: sam.id)
        XCTAssertEqual(rec.submitted.last?.0, assistant)
        XCTAssertEqual(rec.submitted.last?.3, "Sam")
        XCTAssertTrue(rec.submitted.last?.2.hasSuffix("[via Telegram]") == true)

        // Coder reaches out from its own conversation: the next reply goes there.
        guard case .sent = try await channels.send("Can I merge the billing PR?", to: sam, from: coder, conversationID: outreach) else { return XCTFail("allowed contacts get it at once") }
        XCTAssertEqual(rec.sent.last?.1, "Can I merge the billing PR?")
        await channels.received("yes, go ahead", from: sam.id)
        XCTAssertEqual(rec.submitted.last?.0, coder)
        XCTAssertEqual(rec.submitted.last?.1, outreach)

        // That was the one reply; what they send next is a new request to Pennant in their own thread.
        await channels.received("can you also check the PR cleanup?", from: sam.id)
        XCTAssertEqual(rec.submitted.last?.0, assistant)
        XCTAssertEqual(rec.submitted.last?.1, ownThread)
        await channels.stop()
    }

    /// An answer goes back as soon as it's written; narration (words with a tool call) doesn't; and the task's
    /// end doesn't send the same answer again.
    func testRepliesAreRelayedAsTheyAreWrittenAndOnlyOnce() async throws {
        let store = try SQLiteStore(paths: paths)
        let bus = EventBus()
        let channels = ChannelService(paths: paths, keychain: KeychainStore(service: "test.channels", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true), store: store, eventBus: bus)
        let rec = Recorder()
        await channels.useSender { _, text in rec.lock.withLock { rec.sent.append(("", text)) } }
        let agent = AgentID(), thread = ConversationID()
        await channels.start(.init(submit: { _, c, _, _ in c ?? thread }, defaultAgent: { agent }, notice: { _ in }))
        var sam = ChannelContact(kind: .telegram, address: "1", name: "Sam", allowed: true, agentID: agent, conversationID: thread)
        sam.linkedAt = Date()
        try await channels.upsert(sam)
        try await Task.sleep(for: .milliseconds(100))

        let task = TaskRecord(agentID: agent, conversationID: thread, title: "hi", objective: "hi", completionCriteria: "")
        try await store.upsertTask(task)
        let narration = Message(conversationID: thread, agentID: agent, taskID: task.id, role: .assistant,
                                parts: [.text("Checking your calendar."), .toolCall(ToolCall(id: ToolCallID("c1"), name: "calendar_events", arguments: [:]))])
        let answer = Message(conversationID: thread, agentID: agent, taskID: task.id, role: .assistant, parts: [.text("You're free after 3.")])
        for m in [narration, answer] {
            try await store.appendMessage(m)
            await bus.publish(HostEvent(seq: 0, payload: .messageAppended(m)))
        }
        await bus.publish(HostEvent(seq: 0, payload: .taskTransition(TaskTransition(taskID: task.id, from: .running, to: .completed))))
        try await Task.sleep(for: .milliseconds(300))
        let sent = rec.lock.withLock { rec.sent.map(\.1) }
        XCTAssertEqual(sent, ["You're free after 3."])
        await channels.stop()
    }

    /// A channels.json from before a field existed loads whole; it isn't read as empty (and then saved empty).
    func testStateSavedByAnOlderVersionStillLoads() async throws {
        let old = #"{"contacts":[{"id":"c1","kind":"teams","address":"a:1","name":"Maya","allowed":true,"linkedAt":"2026-09-25T22:26:00Z"}],"enabled":{"teams":true},"links":{},"telegramOffset":0,"imessageRowID":0,"refusedChats":[],"teams":{"appID":"11111111-2222-3333-4444-555555555555","tenantID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","publicURL":"https://x.ts.net/api/teams/messages"}}"#
        try Data(old.utf8).write(to: paths.root.appendingPathComponent("channels.json"))
        let channels = ChannelService(paths: paths, keychain: KeychainStore(service: "test.channels", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true), store: try SQLiteStore(paths: paths), eventBus: EventBus())
        let contacts = await channels.contacts
        XCTAssertEqual(contacts.map(\.name), ["Maya"])
    }

    func testMessagesToPeopleNotAllowedWaitForAnApprovalThatWorksOnce() async throws {
        let store = try SQLiteStore(paths: paths)
        let channels = ChannelService(paths: paths, keychain: KeychainStore(service: "test.channels", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true), store: store, eventBus: EventBus())
        let rec = Recorder()
        await channels.useSender { c, text in rec.lock.withLock { rec.sent.append((c.name, text)) } }
        let dana = ChannelContact(kind: .imessage, address: "+1 (415) 555-0100", name: "Dana", allowed: false)
        try await channels.upsert(dana)
        guard case .needsApproval(_, let token) = try await channels.send("Your invoice is ready", to: dana, from: AgentID(), conversationID: ConversationID()) else { return XCTFail("needs approval") }
        XCTAssertTrue(rec.sent.isEmpty, "nothing goes out before approval")
        let sentTo = try await channels.sendApproved(token: token, text: "Your invoice is ready (edited)")
        XCTAssertEqual(sentTo.name, "Dana")
        XCTAssertEqual(rec.sent.last?.1, "Your invoice is ready (edited)", "exactly the approved text")
        do { _ = try await channels.sendApproved(token: token, text: "again"); XCTFail("a token works once") } catch {}
    }

    func testFindingPeopleByNameOrNumber() async throws {
        let store = try SQLiteStore(paths: paths)
        let channels = ChannelService(paths: paths, keychain: KeychainStore(service: "test.channels", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true), store: store, eventBus: EventBus())
        try await channels.setEnabled(.imessage, true)
        try await channels.upsert(ChannelContact(kind: .imessage, address: "+1 (415) 555-0100", name: "Dana Kim", allowed: true))
        try await channels.upsert(ChannelContact(kind: .imessage, address: "sam@example.com", name: "Sam", allowed: true))
        let byNumber = await channels.resolve("415-555-0100", channel: nil)
        XCTAssertEqual(byNumber?.name, "Dana Kim")
        let byName = await channels.resolve("dana", channel: .imessage)
        XCTAssertEqual(byName?.name, "Dana Kim")
        let nobody = await channels.resolve("Zed", channel: nil)
        XCTAssertNil(nobody, "names without digits don't match every email-less contact")
        await channels.stop()
    }

    func testTelegramSplitsLongMessagesAndMessagesTextComesOutOfAttributedBody() {
        let long = (0 ..< 300).map { "Line \($0) of a long report." }.joined(separator: "\n")
        let pieces = TelegramBot.split(long, limit: 4000)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 4000 })
        XCTAssertEqual(pieces.joined(separator: "\n"), long)

        // The shape of an archived NSAttributedString: class name, then "+", a length byte, and the UTF-8 text.
        var blob = Data([0x04, 0x0B]) + "streamtyped".data(using: .utf8)! + Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84])
        blob += "NSString".data(using: .utf8)! + Data([0x01, 0x94, 0x84, 0x01, 0x2B, 0x0B]) + "Yes, go on!".data(using: .utf8)! + Data([0x86, 0x84])
        XCTAssertEqual(IMessageBridge.textFromAttributedBody(blob), "Yes, go on!")
        XCTAssertEqual(IMessageBridge.normalize("+1 (415) 555-0100"), IMessageBridge.normalize("4155550100"))
    }

    func testMessagesGetsPlainText() {
        let md = """
        ## Open PRs
        - **backend** [#65](https://github.com/harbor-labs/harbor-api/pull/65): `approvals`
        - [https://x.dev](https://x.dev)
        ```
        code
        ```
        """
        XCTAssertEqual(IMessageBridge.plainText(md), """
        Open PRs
        • backend #65 (https://github.com/harbor-labs/harbor-api/pull/65): approvals
        • https://x.dev
        code
        """)
    }
}
