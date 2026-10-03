import PennantCore
import XCTest

final class CommandRoundTripTests: XCTestCase {
    func testNoPayloadCommandsRoundTrip() throws {
        let bodies: [CommandBody] = [.listSkills, .scanSkillLocations, .listSchedules, .recheckPermissions, .memoryOverview, .getDiagnostics, .previewSchedule(expression: "hourly", timeZone: "UTC", count: 3)]
        for body in bodies {
            let data = try WireMessage.command(ClientCommand(body: body)).encoded()
            let back = try WireMessage.decode(data)
            guard case .command(let c) = back else { return XCTFail("not a command") }
            XCTAssertEqual(c.body, body, String(decoding: data, as: UTF8.self))
        }
    }

    /// The sign-in screen's first question. iPhone apps from before 0.1.0 decode this reply with a `password` flag
    /// and can't sign in without it, so it stays on the wire.
    func testSignInOptionsStillCarryTheFlagOlderIPhonesNeed() throws {
        let reply = WireMessage.reply(HostReply(commandID: CommandID(), result: .signInOptions([.microsoft], hostName: "Studio Mac")))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try reply.encoded()) as? [String: Any])
        let options = (((json["reply"] as? [String: Any])?["_0"] as? [String: Any])?["result"] as? [String: Any])?["signInOptions"] as? [String: Any]
        XCTAssertEqual(options?["password"] as? Bool, true)
        XCTAssertEqual(options?["hostName"] as? String, "Studio Mac")
        XCTAssertEqual(options?["_0"] as? [String], ["microsoft"])
    }

    func testCodingCommandsRoundTrip() throws {
        let bodies: [CommandBody] = [
            .checkGitHubApp(GitHubAppIdentity(appID: 42, installationID: 7, vaultEntry: "app-key", slug: "example-bot")),
            .setConversationCoding(ConversationID(), mode: .plan, model: "fast-profile"),
            .listProjects,
        ]
        for body in bodies {
            let data = try WireMessage.command(ClientCommand(body: body)).encoded()
            guard case .command(let c) = try WireMessage.decode(data) else { return XCTFail("not a command") }
            XCTAssertEqual(c.body, body, String(decoding: data, as: UTF8.self))
        }
    }

    func testSkillCommandsRoundTrip() throws {
        let bodies: [CommandBody] = [
            .retireAgent(AgentID()),
            .importSkills(path: "~/.claude/skills", only: nil),
            .importSkills(path: "https://github.com/acme/skills.git", only: ["/tmp/skills/deploy/SKILL.md", "/tmp/skills/notes/SKILL.md"]),
            .previewSkillImport(path: "/tmp/skills"),
            .deleteSkills([SkillID(), SkillID()]),
            .addSkillFolder(path: "/tmp/skills"),
            .removeSkillFolder(path: "/tmp/skills"),
        ]
        for body in bodies {
            let data = try WireMessage.command(ClientCommand(body: body)).encoded()
            guard case .command(let c) = try WireMessage.decode(data) else { return XCTFail("not a command") }
            XCTAssertEqual(c.body, body, String(decoding: data, as: UTF8.self))
        }
        // Replies carry the preview items and the location kinds.
        let item = SkillPreviewItem(name: "deploy", purpose: "Ship it", sourcePath: "/tmp/skills/deploy/SKILL.md", stepCount: 3, scriptCount: 1, existingVersion: 2, unchanged: false)
        let preview = SkillImportPreview(root: "/tmp/skills", items: [item], warnings: ["notes: unchanged, skipped"])
        let location = SkillLocation(path: "/tmp/repos/tools", harness: "Git repository", skillCount: 4, kind: "git", origin: "https://github.com/acme/tools.git")
        for result in [ReplyBody.skillPreview(preview), .skillLocations([location])] {
            let data = try WireMessage.reply(HostReply(commandID: CommandID(), result: result)).encoded()
            guard case .reply(let r) = try WireMessage.decode(data) else { return XCTFail("not a reply") }
            XCTAssertEqual(r.result, result)
        }
        // Payloads from before `kind`/`origin` and `preview` existed still decode.
        let legacyLocation = try JSONCodec.decode(SkillLocation.self, from: Data("{\"path\":\"/tmp/skills\",\"harness\":\"Claude Code (user)\",\"skillCount\":2}".utf8))
        XCTAssertEqual(legacyLocation.kind, "known")
        XCTAssertNil(legacyLocation.origin)
        let legacyConversation = try JSONCodec.decode(Conversation.self, from: Data("{\"id\":\"c1\",\"agentID\":\"a1\",\"title\":\"t\",\"createdAt\":\"2026-09-22T10:00:00.000Z\",\"updatedAt\":\"2026-09-22T10:00:00.000Z\"}".utf8))
        XCTAssertEqual(legacyConversation.preview, "")
        XCTAssertEqual(Conversation.previewLine("# **Hello** there\nmore"), "Hello there")
    }
}
