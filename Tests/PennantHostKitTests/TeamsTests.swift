import PennantCore
@testable import PennantHostKit
import Foundation
import Security
import XCTest

final class TeamsTests: XCTestCase {
    let config = TeamsBot.Config(appID: "11111111-2222-3333-4444-555555555555", tenantID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", publicURL: "https://mac.example.ts.net/api/teams/messages")

    /// A signing key and its published key set, as Microsoft's would be.
    struct Signer {
        let privateKey: SecKey
        let jwks: Data
        let kid = "test-key-1"

        init() throws {
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error), let pub = SecKeyCopyPublicKey(key),
                  let der = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { throw XCTSkip("no RSA key") }
            privateKey = key
            let (n, e) = Signer.modulusAndExponent(der)
            jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test-key-1", "n": Signer.b64(n), "e": Signer.b64(e), "endorsements": ["msteams"]]]])
        }

        func token(_ claims: [String: Any], kid: String? = nil) throws -> String {
            let head = Signer.b64(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT", "kid": kid ?? self.kid]))
            let body = Signer.b64(try JSONSerialization.data(withJSONObject: claims))
            var error: Unmanaged<CFError>?
            let sig = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(head).\(body)".utf8) as CFData, &error)! as Data
            return "\(head).\(body).\(Signer.b64(sig))"
        }

        static func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }

        /// Reads PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
        static func modulusAndExponent(_ der: Data) -> (Data, Data) {
            let b = [UInt8](der)
            var i = 0
            func length() -> Int {
                var l = Int(b[i]); i += 1
                if l & 0x80 != 0 { let count = l & 0x7F; l = 0; for _ in 0 ..< count { l = (l << 8) | Int(b[i]); i += 1 } }
                return l
            }
            i += 1; _ = length()                      // SEQUENCE
            i += 1; let nl = length(); let n = Data(b[i ..< i + nl]); i += nl
            i += 1; let el = length(); let e = Data(b[i ..< i + el])
            return (n, e)
        }
    }

    private func claims(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var c: [String: Any] = ["iss": "https://api.botframework.com", "aud": config.appID, "exp": Date().addingTimeInterval(600).timeIntervalSince1970,
                                "nbf": Date().addingTimeInterval(-60).timeIntervalSince1970, "serviceurl": "https://smba.trafficmanager.net/amer/"]
        for (k, v) in overrides { c[k] = v }
        return c
    }

    func testOnlyTokensSignedByMicrosoftForThisBotGetIn() async throws {
        let signer = try Signer()
        let jwks = signer.jwks
        let validator = TeamsTokenValidator { _ in jwks }

        let good = try signer.token(claims())
        let issuer = try await validator.validate(authorization: "Bearer \(good)", config: config)
        XCTAssertEqual(issuer, "https://api.botframework.com")

        let cases: [(String, String)] = [
            ("another bot", try signer.token(claims(["aud": "99999999-2222-3333-4444-555555555555"]))),
            ("expired", try signer.token(claims(["exp": Date().addingTimeInterval(-3600).timeIntervalSince1970]))),
            ("another issuer", try signer.token(claims(["iss": "https://evil.example"]))),
            ("unknown key", try signer.token(claims(), kid: "someone-elses-key")),
        ]
        for (label, token) in cases {
            do { try await validator.validate(authorization: "Bearer \(token)", config: config); XCTFail("accepted: \(label)") } catch {}
        }
        // A token whose claims were changed after signing.
        let parts = good.split(separator: ".").map(String.init)
        let forged = parts[0] + "." + Signer.b64(try JSONSerialization.data(withJSONObject: claims(["aud": config.appID, "extra": "x"]))) + "." + parts[2]
        do { try await validator.validate(authorization: "Bearer \(forged)", config: config); XCTFail("accepted a forged token") } catch {}
        do { try await validator.validate(authorization: nil, config: config); XCTFail("accepted no token") } catch {}
    }

    func testActivitiesAreReadAndHTMLBecomesWords() {
        let json: [String: Any] = [
            "type": "message", "text": "<at>Pennant</at> Can you check <b>Atlas</b>&nbsp;status?<br>Thanks",
            "serviceUrl": "https://smba.trafficmanager.net/amer/",
            "from": ["id": "29:abc", "aadObjectId": "oid-1", "name": "Sam Lee"],
            "recipient": ["id": "28:bot"],
            "conversation": ["id": "a:1xyz", "conversationType": "personal", "tenantId": config.tenantID],
        ]
        let a = TeamsBot.Activity(json)
        XCTAssertEqual(a?.text, "Can you check Atlas status?\nThanks")
        XCTAssertEqual(a?.fromAADObjectID, "oid-1")
        XCTAssertEqual(a?.tenantID, config.tenantID)
        XCTAssertNil(TeamsBot.Activity(["type": "message"]), "not an activity without a conversation and service")
    }

    func testTeammatesAreLinkedByTheirMicrosoftSignInAndStrangersAreNot() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let keychain = KeychainStore(service: "test.teams", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true)
        let channels = ChannelService(paths: paths, keychain: keychain, store: try SQLiteStore(paths: paths), eventBus: EventBus())
        try await channels.setTeams(appID: config.appID, tenantID: config.tenantID, publicURL: config.publicURL, secret: "s3cret")
        let sam = Person(name: "Sam Lee", email: "sam@example.com", identities: [LinkedIdentity(provider: .microsoft, subject: "oid-sam", email: "sam@example.com", tenantID: config.tenantID)])
        final class Box: @unchecked Sendable { var submitted: [(String, String)] = []; var sent: [String] = [] }
        let box = Box()
        await channels.useSender { contact, text in box.sent.append("\(contact.name): \(text)") }
        await channels.start(.init(submit: { _, c, text, author in box.submitted.append((author.name, text)); return c ?? ConversationID() },
                                   defaultAgent: { AgentID() }, notice: { _ in },
                                   personForMicrosoftID: { oid in oid == "oid-sam" ? sam : nil }))

        func activity(_ oid: String, _ text: String, tenant: String? = nil) -> TeamsBot.Activity {
            TeamsBot.Activity(["type": "message", "text": text, "serviceUrl": "https://smba.trafficmanager.net/amer/",
                               "from": ["id": "29:\(oid)", "aadObjectId": oid, "name": "Someone"], "recipient": ["id": "28:bot"],
                               "conversation": ["id": "a:\(oid)", "conversationType": "personal", "tenantId": tenant ?? config.tenantID]])!
        }
        await channels.teamsActivity(activity("oid-sam", "what's on my calendar?"))
        XCTAssertEqual(box.submitted.first?.0, "Sam Lee", "a known person is linked on their first message")
        let contacts = await channels.contacts
        XCTAssertEqual(contacts.first?.details?["serviceURL"], "https://smba.trafficmanager.net/amer/")
        XCTAssertEqual(contacts.first?.allowed, true)

        await channels.teamsActivity(activity("oid-other-org", "hello", tenant: "ffffffff-0000-0000-0000-000000000000"))
        let afterStranger = await channels.contacts
        XCTAssertEqual(afterStranger.count, 1, "people from other organisations are ignored")
        XCTAssertEqual(box.submitted.count, 1)
        await channels.stop()
    }

    /// A founders' channel: someone with a Pennant account connects it by mentioning the bot; after that anyone
    /// there can ask, each message says who asked, answers go to the thread, and approvals still need an account.
    func testATeamChannelIsConnectedByAPennantPersonAndSharedByEveryoneInIt() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let keychain = KeychainStore(service: "test.teams", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true)
        let channels = ChannelService(paths: paths, keychain: keychain, store: try SQLiteStore(paths: paths), eventBus: EventBus())
        try await channels.setTeams(appID: config.appID, tenantID: config.tenantID, publicURL: config.publicURL, secret: "s3cret")
        let sam = Person(name: "Sam Lee", email: "sam@example.com", identities: [LinkedIdentity(provider: .microsoft, subject: "oid-sam", email: "sam@example.com", tenantID: config.tenantID)])
        final class Box: @unchecked Sendable {
            var submitted: [(author: String, conversation: ConversationID?, text: String)] = []
            var sent: [(address: String, text: String)] = []
            var decided: [String] = []
        }
        let box = Box()
        let channelConversation = ConversationID()
        await channels.useSender { contact, text in box.sent.append((contact.address, text)) }
        await channels.start(.init(submit: { _, c, text, author in box.submitted.append((author.name, c, text)); return c ?? channelConversation },
                                   defaultAgent: { AgentID() }, notice: { _ in },
                                   personForMicrosoftID: { oid in oid == "oid-sam" ? sam : nil },
                                   decideApproval: { d, by in box.decided.append("\(by.name) \(d.verdict.rawValue)") }))

        let channel = "19:founders@thread.tacv2"
        func message(_ oid: String, _ name: String, _ text: String, thread: String, value: [String: Any]? = nil) -> TeamsBot.Activity {
            var json: [String: Any] = [
                "type": "message", "text": "<at>Pennant</at> \(text)", "serviceUrl": "https://smba.trafficmanager.net/amer/",
                "from": ["id": "29:\(oid)", "aadObjectId": oid, "name": name], "recipient": ["id": "28:bot", "name": "Pennant"],
                "conversation": ["id": "\(channel);messageid=\(thread)", "conversationType": "channel", "isGroup": true, "tenantId": config.tenantID],
                "channelData": ["teamsChannelId": channel, "channel": ["id": channel], "team": ["id": "19:team@thread.tacv2"], "tenant": ["id": config.tenantID]],
            ]
            if let value { json["value"] = value }
            return TeamsBot.Activity(json)!
        }

        // Added to the team: it says how to start.
        await channels.teamsActivity(TeamsBot.Activity([
            "type": "conversationUpdate", "serviceUrl": "https://smba.trafficmanager.net/amer/", "recipient": ["id": "28:bot"],
            "membersAdded": [["id": "28:bot"]],
            "conversation": ["id": channel, "conversationType": "channel", "isGroup": true, "tenantId": config.tenantID],
            "channelData": ["channel": ["id": channel], "team": ["id": "19:team@thread.tacv2", "name": "Founders"]],
        ])!)
        XCTAssertEqual(box.sent.count, 1)
        XCTAssertTrue(box.sent[0].text.contains("@mention me once"))

        // Before it's connected, someone without an account is told how, once, and nothing reaches an agent.
        await channels.teamsActivity(message("oid-priya", "Priya Shah", "what's our runway?", thread: "100"))
        await channels.teamsActivity(message("oid-priya", "Priya Shah", "hello?", thread: "101"))
        XCTAssertTrue(box.submitted.isEmpty)
        XCTAssertEqual(box.sent.count, 2, "the not-connected reply is sent once per channel")

        // Sam has a Pennant account: their mention connects the channel and goes to the agent as Sam.
        await channels.teamsActivity(message("oid-sam", "Sam Lee", "summarise this week's deploys", thread: "200"))
        XCTAssertEqual(box.submitted.count, 1)
        XCTAssertEqual(box.submitted[0].author, "Sam Lee")
        XCTAssertTrue(box.submitted[0].text.hasPrefix("summarise this week's deploys\n\n[Sam Lee, in the shared Microsoft Teams channel \"Teams channel\"."), box.submitted[0].text)
        XCTAssertTrue(box.submitted[0].text.contains("just answer"), "the agent is told its reply is what gets posted")
        var contacts = await channels.contacts
        XCTAssertEqual(contacts.count, 1)
        XCTAssertNil(contacts[0].personID, "the channel is shared, not Sam's")
        XCTAssertEqual(contacts[0].details?["group"], channel)

        // Now Priya can ask too, in another thread: same conversation, her name on it, answers go to her thread.
        await channels.teamsActivity(message("oid-priya", "Priya Shah", "and the Atlas bill?", thread: "300"))
        XCTAssertEqual(box.submitted.count, 2)
        XCTAssertEqual(box.submitted[1].author, "Priya Shah")
        XCTAssertEqual(box.submitted[1].conversation, channelConversation, "one conversation for the whole channel")
        contacts = await channels.contacts
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].address, "\(channel);messageid=300")

        // Approval buttons: Priya can't decide, Sam can.
        let approve: [String: Any] = ["pennant": "approval", "approvalID": "ap-1", "verdict": "approve"]
        await channels.teamsActivity(message("oid-priya", "Priya Shah", "", thread: "300", value: approve))
        XCTAssertTrue(box.decided.isEmpty)
        XCTAssertTrue(box.sent.last?.text.contains("Pennant account") ?? false)
        await channels.teamsActivity(message("oid-sam", "Sam Lee", "", thread: "300", value: approve))
        XCTAssertEqual(box.decided, ["Sam Lee approve"])

        // Sam's own one-to-one chat stays separate from the channel.
        await channels.teamsActivity(TeamsBot.Activity(["type": "message", "text": "just me", "serviceUrl": "https://smba.trafficmanager.net/amer/",
                                                        "from": ["id": "29:oid-sam", "aadObjectId": "oid-sam", "name": "Sam Lee"], "recipient": ["id": "28:bot"],
                                                        "conversation": ["id": "a:sam-dm", "conversationType": "personal", "tenantId": config.tenantID]])!)
        contacts = await channels.contacts
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts.first { $0.details?["group"] == nil }?.address, "a:sam-dm")
        XCTAssertEqual(contacts.first { $0.details?["group"] != nil }?.address, "\(channel);messageid=300")
        await channels.stop()
    }

    /// Teams sends go from Pennant's bot: into chats it's in, and one-to-one to colleagues (their reply comes back to
    /// the agent). Where it can't go the agent is told, and nothing goes from the owner's account.
    func testTeamsSendsGoFromPennant() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let keychain = KeychainStore(service: "test.teams", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true)
        let channels = ChannelService(paths: paths, keychain: keychain, store: try SQLiteStore(paths: paths), eventBus: EventBus())
        final class Box: @unchecked Sendable { var sent: [(String, String)] = [] }
        let box = Box()
        await channels.useSender { contact, text in box.sent.append((contact.address, text)) }
        let agent = AgentID(), conversation = ConversationID()
        let lookup: @Sendable (String) async -> (id: String, name: String)? = { $0 == "jonas@example.com" ? ("oid-jonas", "Jonas Lindqvist") : nil }
        func route(_ tool: String, _ args: JSONValue) async -> ChannelService.TeamsRoute? {
            await channels.routeTeamsSend(tool: "microsoft_365__" + tool, arguments: args, agentID: agent, conversationID: conversation, lookup: lookup)
        }

        // No Teams bot here: the connector sends as it always did.
        let unset = await route("teams_send_chat", ["chat_id": "19:x@thread.v2", "text": "hi"])
        XCTAssertNil(unset)

        try await channels.setTeams(appID: config.appID, tenantID: config.tenantID, publicURL: config.publicURL, secret: "s3cret")
        let chat = "19:founders@thread.v2"
        var group = ChannelContact(kind: .teams, address: chat, name: "Founders", allowed: true)
        group.details = ["serviceURL": "https://smba.trafficmanager.net/amer/", "group": chat, "type": "groupChat"]
        try await channels.upsert(group)

        guard case .handled(_, let failed)? = await route("teams_send_chat", ["chat_id": .string(chat), "text": "v1.15 is out."]) else { return XCTFail("not routed") }
        XCTAssertFalse(failed)
        XCTAssertEqual(box.sent.last?.0, chat)

        guard case .handled(let refusal, let refused)? = await route("teams_send_chat", ["chat_id": "19:elsewhere@thread.v2", "text": "hi"]) else { return XCTFail("not routed") }
        XCTAssertTrue(refused)
        XCTAssertTrue(refusal.contains("Pennant isn't in that chat"), refusal)
        XCTAssertEqual(box.sent.count, 1, "nothing goes from the owner's account instead")

        guard case .handled(let dm, let dmFailed)? = await route("teams_message_person", ["email": "Jonas@example.com", "text": "The release is out."]) else { return XCTFail("not routed") }
        XCTAssertFalse(dmFailed, dm)
        XCTAssertEqual(box.sent.last?.0, "a:oid-jonas")
        let jonas = await channels.contacts.first { $0.details?["aad"] == "oid-jonas" }
        XCTAssertEqual(jonas?.name, "Jonas Lindqvist")
        XCTAssertEqual(jonas?.replyConversationID, conversation, "his reply comes back to the agent that wrote")

        guard case .handled(_, let unknown)? = await route("teams_message_person", ["email": "nobody@example.com", "text": "hi"]) else { return XCTFail("not routed") }
        XCTAssertTrue(unknown)

    }

    func testAGroupChatIsKeyedByItsConversation() {
        let a = TeamsBot.Activity(["type": "message", "text": "<at>Pennant</at> hi", "serviceUrl": "https://smba.trafficmanager.net/amer/",
                                   "from": ["id": "29:x", "aadObjectId": "oid-x", "name": "X"], "recipient": ["id": "28:bot"],
                                   "conversation": ["id": "19:chat@thread.v2", "conversationType": "groupChat", "isGroup": true, "name": "Founders", "tenantId": config.tenantID]])!
        XCTAssertTrue(a.isGroup)
        XCTAssertEqual(a.groupKey, "19:chat@thread.v2")
        XCTAssertEqual(a.placeName, "Founders")
        XCTAssertEqual(a.text, "hi")
    }

    func testTheWebhookServerAnswersOnlyItsPathOnLoopback() async throws {
        let server = WebhookServer()
        let port = try await server.start(port: 0) { request in
            request.path == "/api/teams/messages" && request.method == "POST" && request.body == Data("{\"a\":1}".utf8) ? .ok : .notFound
        }
        defer { Task { await server.stop() } }
        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/teams/messages")!)
        post.httpMethod = "POST"
        post.httpBody = Data("{\"a\":1}".utf8)
        let (_, ok) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((ok as? HTTPURLResponse)?.statusCode, 200)
        let (_, other) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/anything")!)
        XCTAssertEqual((other as? HTTPURLResponse)?.statusCode, 404)
    }

    /// Changing the Teams settings restarts the server on the same fixed port; it must come back every time.
    func testTheWebhookServerRestartsOnTheSamePort() async throws {
        let server = WebhookServer()
        let port = try await server.start(port: 0) { _ in .notFound }
        for _ in 1...5 {
            let again = try await server.start(port: port) { _ in .ok }
            XCTAssertEqual(again, port)
        }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/teams/messages")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await server.stop()
    }
}

/// From a shared chat, a Teams message still goes out, from Pennant's bot: that isn't acting with the owner's account.
final class TeamsFromSharedChatTests: XCTestCase {
    struct FakeTeamsTool: Tool {
        var spec: ToolSpec { ToolSpec(name: "microsoft_365__teams_send_chat", description: "fake", inputSchema: JSONSchema.object([:]), isConsequential: true, source: "mcp:m365") }
        func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
            XCTFail("the owner's account must not be used")
            return .text(ToolCallID("x"), name: spec.name, "sent as the owner")
        }
    }

    func testATeamsPostFromASharedChatGoesFromPennant() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let chat = "19:founders@thread.v2"
        let post = ToolCall(id: ToolCallID("p1"), name: "microsoft_365__teams_send_chat", arguments: ["chat_id": .string(chat), "text": "Release is out."])
        let provider = ScriptedProvider([.init(text: "Hi."), .init(toolCalls: [post]), .init(text: "Posted.")])
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        final class Box: @unchecked Sendable { var sent: [String] = [] }
        let box = Box()
        await s.channels.useSender { contact, text in box.sent.append("\(contact.address): \(text)") }
        try await s.channels.setTeams(appID: "11111111-2222-3333-4444-555555555555", tenantID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", publicURL: "https://mac.example.ts.net/api/teams/messages", secret: "s")
        await s.broker.register([FakeTeamsTool()])
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversation, first) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "hello", attachments: [])
        var end = Date().addingTimeInterval(5)
        while try await s.store.task(first)?.state != .completed, Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        var group = ChannelContact(kind: .teams, address: chat, name: "Founders", allowed: true, conversationID: conversation)
        group.details = ["serviceURL": "https://smba.trafficmanager.net/amer/", "group": chat, "type": "groupChat"]
        try await s.channels.upsert(group)

        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: conversation, text: "Tell everyone the release is out", attachments: [])
        end = Date().addingTimeInterval(5)
        while try await s.store.task(task)?.state != .completed, Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        let records = try await s.store.toolRecords(taskID: task)
        XCTAssertEqual(records.first?.status, .succeeded, records.first?.resultSummary ?? "")
        XCTAssertTrue(box.sent.contains("\(chat): Release is out."), "\(box.sent)")
        await s.stop()
    }
}

/// iMessage on a person's own Apple ID: Pennant answers only texts addressed to it, labels its replies, and never
/// takes its own replies (which come back when the person texts themselves) for new questions.
final class IMessagePersonalTests: XCTestCase {
    func testOnlyTextsAddressedToPennantReachIt() {
        XCTAssertEqual(IMessageBridge.addressedToPennant("Pennant, what's on today?"), "what's on today?")
        XCTAssertEqual(IMessageBridge.addressedToPennant("hey pennant check the build"), "check the build")
        XCTAssertEqual(IMessageBridge.addressedToPennant("@Pennant: status"), "status")
        XCTAssertEqual(IMessageBridge.addressedToPennant("Pennant"), "Hi")
        XCTAssertNil(IMessageBridge.addressedToPennant("Dinner at 8?"))
        XCTAssertNil(IMessageBridge.addressedToPennant("I told Pennant about it"), "mentioning it isn't addressing it")
        XCTAssertNil(IMessageBridge.addressedToPennant("Pennants are flags"), "a word that starts with the name isn't it")
    }

    func testRepliesAreLabelledAndNotTakenBackAsQuestions() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let keychain = KeychainStore(service: "test.im", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true)
        let channels = ChannelService(paths: paths, keychain: keychain, store: try SQLiteStore(paths: paths), eventBus: EventBus())
        final class Box: @unchecked Sendable { var sent: [String] = [] }
        let box = Box()
        await channels.useSender { _, text in box.sent.append(text) }
        try await channels.setEnabled(.imessage, true)
        let me = ChannelContact(kind: .imessage, address: "+1 555 010 0000", name: "Maya", allowed: true)
        try await channels.upsert(me)
        _ = try await channels.send("Build is green.", to: me, from: AgentID(), conversationID: ConversationID())
        XCTAssertEqual(box.sent, ["[Pennant] Build is green."])
        let echoed = await channels.imessageAccepts("[Pennant] Build is green.")
        XCTAssertNil(echoed, "its own reply, back in the person's self-chat")
        let asked = await channels.imessageAccepts("Pennant, and the tests?")
        XCTAssertEqual(asked, "and the tests?")
        let theirs = await channels.imessageAccepts("see you at 8")
        XCTAssertNil(theirs)

        // Pennant's own Apple ID: everything from its contacts, unlabelled.
        try await channels.setIMessagePersonal(false)
        let all = await channels.imessageAccepts("see you at 8")
        XCTAssertEqual(all, "see you at 8")
        _ = try await channels.send("Hello.", to: me, from: AgentID(), conversationID: ConversationID())
        XCTAssertEqual(box.sent.last, "Hello.")
    }
}

final class IMessageGroupTests: XCTestCase {
    /// A small database shaped like Messages' own: a one-to-one chat with Jonas and the "Harbor" group chat.
    private func messagesDatabase(at url: URL) throws {
        let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT, display_name TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER,
                              item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        INSERT INTO handle VALUES (1, 'jonas@example.com'), (2, '+12015550100');
        INSERT INTO chat VALUES (1, 'iMessage;-;jonas@example.com', 45, 'jonas@example.com', ''), (2, 'any;+;chat42', 43, 'chat42', 'Harbor'),
                                (3, 'any;+;chat7', 43, 'chat7', '');
        INSERT INTO message VALUES (1, 1, 'Pennant, just me?', NULL, 0, 0, 0, 0), (2, 1, 'Pennant, status of the build?', NULL, 0, 0, 0, 0),
                                   (3, 0, 'Pennant, and the release?', NULL, 0, 1, 0, 0), (4, 2, 'Loved “x”', NULL, 0, 0, 0, 2000),
                                   (5, 2, 'renamed', NULL, 0, 0, 2, 0);
        INSERT INTO chat_message_join VALUES (1, 1), (2, 2), (2, 3), (2, 4), (2, 5);
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [url.path, sql]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testGroupMessagesBelongToTheGroupNotToTheSender() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = IMessageBridge.databaseURL
        defer { IMessageBridge.databaseURL = real }
        IMessageBridge.databaseURL = dir.appendingPathComponent("chat.db")
        try messagesDatabase(at: IMessageBridge.databaseURL)

        XCTAssertEqual(try IMessageBridge.groupChats(), [.init(identifier: "chat42", name: "Harbor")], "only named group chats")
        let direct = try IMessageBridge.received(after: 0, from: ["jonas@example.com", "+1 (201) 555-0100"])
        XCTAssertEqual(direct.map(\.text), ["Pennant, just me?"], "what Jonas says in the group isn't a text to his own thread")
        let group = try IMessageBridge.received(after: 0, inGroups: ["chat42"])
        XCTAssertEqual(group.map(\.text), ["Pennant, status of the build?", "Pennant, and the release?"], "reactions and renames aren't messages")
        XCTAssertEqual(group.map(\.fromMe), [false, true])
        XCTAssertEqual(group.first?.handle, "jonas@example.com")
        XCTAssertEqual(try IMessageBridge.received(after: 0, inGroups: ["chat7"]).count, 0)
    }

    func testAGroupChatIsFoundByNameAnswersOnlyWhenAddressedAndIsShared() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let keychain = KeychainStore(service: "test.im", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true)
        let channels = ChannelService(paths: paths, keychain: keychain, store: try SQLiteStore(paths: paths), eventBus: EventBus())
        final class Box: @unchecked Sendable { var sent: [(String, String)] = [] }
        let box = Box()
        await channels.useSender { c, text in box.sent.append((c.details?["group"] ?? c.address, text)) }
        try await channels.setEnabled(.imessage, true)
        var group = ChannelContact(kind: .imessage, address: "harbor", name: "Harbor", allowed: true)
        group.details = ["type": "group"]
        try await channels.upsert(group)
        let changed = await channels.resolveIMessageGroups([.init(identifier: "chat42", name: "Harbor")])
        XCTAssertTrue(changed)
        let resolved = await channels.contacts.first { $0.id == group.id }
        XCTAssertEqual(resolved?.details?["group"], "chat42")

        func message(_ text: String, fromMe: Bool) -> IMessageBridge.Incoming {
            .init(rowID: 1, handle: fromMe ? "" : "jonas@example.com", text: text, fromMe: fromMe, group: "chat42")
        }
        var asked = await channels.imessageGroupAccepts(message("Pennant, status?", fromMe: false))
        XCTAssertEqual(asked, "status?")
        asked = await channels.imessageGroupAccepts(message("lunch?", fromMe: false))
        XCTAssertNil(asked, "the group's own conversation stays theirs")
        asked = await channels.imessageGroupAccepts(message("Pennant, and the release?", fromMe: true))
        XCTAssertEqual(asked, "and the release?", "the owner asks from their own Apple ID")

        _ = try await channels.send("All green.", to: resolved!, from: AgentID(), conversationID: ConversationID())
        XCTAssertEqual(box.sent.last?.0, "chat42", "the answer goes to the group")
        XCTAssertEqual(box.sent.last?.1, "[Pennant] All green.")
        asked = await channels.imessageGroupAccepts(message("[Pennant] All green.", fromMe: true))
        XCTAssertNil(asked, "its own reply isn't a question")

        // With a review batch waiting in the group, a bare "approve all" is for Pennant, and is answered right there.
        asked = await channels.imessageGroupAccepts(message("approve all", fromMe: false), reviewOpen: true)
        XCTAssertEqual(asked, "approve all")
        await channels.useReviews(hook: { text, contact, keys, isGroup in
            text == "approve all" && isGroup && keys == ["imessage:jonas"] ? "Jonas approved on GitHub: backend #65." : nil
        }, open: { _ in true })
        await channels.received("approve all", from: group.id, speaker: MessageAuthor(id: PersonID("imessage:jonas"), name: "Jonas"))
        XCTAssertEqual(box.sent.last?.1, "[Pennant] Jonas approved on GitHub: backend #65.")

        // On Pennant's own Apple ID, what comes from this Mac is Pennant's.
        try await channels.setIMessagePersonal(false)
        asked = await channels.imessageGroupAccepts(message("Pennant, hello", fromMe: true))
        XCTAssertNil(asked)
        asked = await channels.imessageGroupAccepts(message("hello", fromMe: false))
        XCTAssertNil(asked, "a group always needs the name, even on Pennant's own Apple ID")
    }
}
