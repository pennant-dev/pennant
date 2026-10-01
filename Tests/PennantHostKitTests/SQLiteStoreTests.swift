import PennantCore
import XCTest
@testable import PennantHostKit

final class SQLiteStoreTests: XCTestCase {
    private var paths: HostPaths!
    private var store: SQLiteStore!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        store = try SQLiteStore(paths: paths)
    }

    override func tearDown() async throws {
        await store?.close()
        if let paths { try? FileManager.default.removeItem(at: paths.root) }
    }

    private func makeAgent(name: String = "Ada") -> AgentProfile {
        AgentProfile(name: name, role: "assistant")
    }

    private func makeMessage(conversation: ConversationID, agent: AgentID, role: MessageRole = .user, text: String, at: Date = Date()) -> Message {
        Message(conversationID: conversation, agentID: agent, role: role, parts: [.text(text)], createdAt: at)
    }

    // MARK: Events

    func testEventSequenceIsMonotonicAndReplayable() async throws {
        let agent = makeAgent()
        let e1 = try await store.appendEvent(.agentUpserted(agent))
        let e2 = try await store.appendEvent(.notice(level: .info, agentID: nil, text: "hello"))
        let e3 = try await store.appendEvent(.agentRemoved(agent.id))
        XCTAssertEqual(e1.seq, 1)
        XCTAssertEqual(e2.seq, 2)
        XCTAssertEqual(e3.seq, 3)
        let v1 = try await store.latestEventSeq()
        XCTAssertEqual(v1, 3)
        let v2 = try await store.eventCount()
        XCTAssertEqual(v2, 3)

        let replay = try await store.events(afterSeq: 1, limit: 10)
        XCTAssertEqual(replay.map(\.seq), [2, 3])
        if case .notice(_, _, let text) = replay[0].payload { XCTAssertEqual(text, "hello") } else { XCTFail("wrong payload") }
        if case .agentRemoved(let id) = replay[1].payload { XCTAssertEqual(id, agent.id) } else { XCTFail("wrong payload") }

        let limited = try await store.events(afterSeq: 0, limit: 2)
        XCTAssertEqual(limited.map(\.seq), [1, 2])
    }

    func testTransientEventsAreNotStored() async throws {
        let agent = makeAgent()
        let delta = MessageDelta(messageID: MessageID(), conversationID: ConversationID(), agentID: agent.id, textDelta: "hi")
        let event = try await store.appendEvent(.messageDelta(delta))
        XCTAssertEqual(event.seq, 0)
        let v3 = try await store.eventCount()
        XCTAssertEqual(v3, 0)
        let v4 = try await store.latestEventSeq()
        XCTAssertEqual(v4, 0)
        let durable = try await store.appendEvent(.agentUpserted(agent))
        XCTAssertEqual(durable.seq, 1)
    }

    // MARK: Agents and conversations

    func testAgentUpsertAndRetiredFilter() async throws {
        var agent = makeAgent()
        try await store.upsertAgent(agent)
        var retired = makeAgent(name: "Old")
        retired.status = .retired
        try await store.upsertAgent(retired)
        let v5 = try await store.listAgents(includeRetired: false).map(\.name)
        XCTAssertEqual(v5, ["Ada"])
        let v6 = try await store.listAgents(includeRetired: true).count
        XCTAssertEqual(v6, 2)
        agent.name = "Ada Lovelace"
        try await store.upsertAgent(agent)
        let v7 = try await store.agent(agent.id)?.name
        XCTAssertEqual(v7, "Ada Lovelace")
        let v8 = try await store.listAgents(includeRetired: true).count
        XCTAssertEqual(v8, 2)
    }

    // MARK: Tasks

    func testTaskUpsertAndTransitionsInOrder() async throws {
        let agent = makeAgent()
        let conversation = Conversation(agentID: agent.id, title: "t")
        try await store.upsertConversation(conversation)
        var task = TaskRecord(agentID: agent.id, conversationID: conversation.id, title: "Do it", objective: "Do the thing")
        try await store.upsertTask(task)
        let v9 = try await store.task(task.id)?.objective
        XCTAssertEqual(v9, "Do the thing")

        for (from, to) in [(TaskState.queued, TaskState.running), (.running, .waitingForTool), (.waitingForTool, .running), (.running, .completed)] {
            XCTAssertTrue(from.canTransition(to: to))
            try await store.recordTransition(TaskTransition(taskID: task.id, from: from, to: to, reason: "\(from)->\(to)"))
        }
        let transitions = try await store.transitions(taskID: task.id)
        XCTAssertEqual(transitions.map(\.to), [.running, .waitingForTool, .running, .completed])

        task.state = .completed
        try await store.upsertTask(task)
        let v10 = try await store.listTasks(agentID: agent.id, includeFinished: false).count
        XCTAssertEqual(v10, 0)
        let v11 = try await store.listTasks(agentID: agent.id, includeFinished: true).count
        XCTAssertEqual(v11, 1)
        let v12 = try await store.listTasks(agentID: nil, includeFinished: true).count
        XCTAssertEqual(v12, 1)

        let child = TaskRecord(agentID: agent.id, conversationID: conversation.id, parentTaskID: task.id, title: "child", objective: "sub")
        try await store.upsertTask(child)
        let v13 = try await store.childTasks(parentTaskID: task.id).map(\.id)
        XCTAssertEqual(v13, [child.id])
    }

    func testToolRecordsAndCheckpoints() async throws {
        let agent = makeAgent()
        let task = TaskRecord(agentID: agent.id, conversationID: ConversationID(), title: "t", objective: "o")
        var record = ToolRecord(taskID: task.id, agentID: agent.id, call: ToolCall(name: "shell", arguments: ["command": "ls"]))
        try await store.upsertToolRecord(record)
        let v14 = try await store.unresolvedToolRecords().map(\.id)
        XCTAssertEqual(v14, [record.id])
        record.status = .succeeded
        record.resultSummary = "ok"
        try await store.upsertToolRecord(record)
        let v15 = try await store.unresolvedToolRecords().count
        XCTAssertEqual(v15, 0)
        let v16 = try await store.toolRecords(taskID: task.id).first?.resultSummary
        XCTAssertEqual(v16, "ok")
        let v17 = try await store.toolRecord(record.id)?.status
        XCTAssertEqual(v17, .succeeded)
        let v18 = try await store.recentToolRecords(limit: 5).count
        XCTAssertEqual(v18, 1)

        let c1 = Checkpoint(taskID: task.id, agentID: agent.id, objective: "o", nextStep: "first", createdAt: Date(timeIntervalSinceNow: -10))
        let c2 = Checkpoint(taskID: task.id, agentID: agent.id, objective: "o", nextStep: "second")
        try await store.saveCheckpoint(c1)
        try await store.saveCheckpoint(c2)
        let v19 = try await store.latestCheckpoint(taskID: task.id)?.nextStep
        XCTAssertEqual(v19, "second")
        let v20 = try await store.checkpoints(taskID: task.id).map(\.nextStep)
        XCTAssertEqual(v20, ["first", "second"])
    }

    // MARK: Messages

    func testMessagePagingBothDirections() async throws {
        let agent = makeAgent()
        let conversation = Conversation(agentID: agent.id)
        try await store.upsertConversation(conversation)
        let base = Date()
        var ids: [MessageID] = []
        for i in 0 ..< 10 {
            let m = makeMessage(conversation: conversation.id, agent: agent.id, text: "message \(i)", at: base.addingTimeInterval(Double(i)))
            ids.append(m.id)
            try await store.appendMessage(m)
        }
        let v21 = try await store.messageCount()
        XCTAssertEqual(v21, 10)

        let newest = try await store.listMessages(conversationID: conversation.id, before: nil, limit: 3)
        XCTAssertEqual(newest.map(\.text), ["message 9", "message 8", "message 7"])
        let older = try await store.listMessages(conversationID: conversation.id, before: newest.last!.id, limit: 3)
        XCTAssertEqual(older.map(\.text), ["message 6", "message 5", "message 4"])

        let fromStart = try await store.messagesAfter(conversationID: conversation.id, after: nil, limit: 2)
        XCTAssertEqual(fromStart.map(\.text), ["message 0", "message 1"])
        let after = try await store.messagesAfter(conversationID: conversation.id, after: ids[7], limit: 10)
        XCTAssertEqual(after.map(\.text), ["message 8", "message 9"])

        let list = try await store.listConversations(agentID: agent.id)
        XCTAssertEqual(list.map(\.id), [conversation.id])
        let v22 = try await store.conversation(conversation.id)?.id
        XCTAssertEqual(v22, conversation.id)
    }

    func testMessagePagingWithIdenticalTimestamps() async throws {
        let agent = makeAgent()
        let conversation = Conversation(agentID: agent.id)
        let at = Date()
        for i in 0 ..< 5 {
            try await store.appendMessage(makeMessage(conversation: conversation.id, agent: agent.id, text: "same \(i)", at: at))
        }
        let page1 = try await store.listMessages(conversationID: conversation.id, before: nil, limit: 2)
        let page2 = try await store.listMessages(conversationID: conversation.id, before: page1.last!.id, limit: 2)
        let page3 = try await store.listMessages(conversationID: conversation.id, before: page2.last!.id, limit: 2)
        let all = (page1 + page2 + page3).map(\.text)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(Set(all).count, 5, "pages must not overlap")
    }

    func testMessageSearchAndUpdateReindexes() async throws {
        let agent = makeAgent()
        let other = makeAgent(name: "Bob")
        let conversation = Conversation(agentID: agent.id)
        var m1 = makeMessage(conversation: conversation.id, agent: agent.id, text: "Invoice 042 belongs to Project Atlas")
        let m2 = makeMessage(conversation: conversation.id, agent: other.id, text: "The C++ compiler flags for Atlas")
        let m3 = Message(conversationID: conversation.id, agentID: agent.id, role: .assistant, parts: [.reasoning("secret atlas thoughts"), .text("Done.")])
        try await store.appendMessage(m1)
        try await store.appendMessage(m2)
        try await store.appendMessage(m3)

        let v23 = try await store.searchMessages(text: "invoice 042 \"atlas\"", agentID: nil, limit: 10).map(\.id)
        XCTAssertEqual(v23, [m1.id])
        let v24 = try await store.searchMessages(text: "C++", agentID: nil, limit: 10).map(\.id)
        XCTAssertEqual(v24, [m2.id])
        let v25 = try await store.searchMessages(text: "atl", agentID: nil, limit: 10).count
        XCTAssertEqual(v25, 2, "prefix match, reasoning excluded")
        let v26 = try await store.searchMessages(text: "atlas", agentID: other.id, limit: 10).map(\.id)
        XCTAssertEqual(v26, [m2.id])
        let v27 = try await store.searchMessages(text: "   !!! ", agentID: nil, limit: 10).count
        XCTAssertEqual(v27, 0)

        m1.parts = [.text("Receipt 042 belongs to Project Borealis")]
        try await store.updateMessage(m1)
        let v28 = try await store.searchMessages(text: "invoice", agentID: nil, limit: 10).count
        XCTAssertEqual(v28, 0)
        let v29 = try await store.searchMessages(text: "borealis", agentID: nil, limit: 10).map(\.id)
        XCTAssertEqual(v29, [m1.id])
        let v30 = try await store.message(m1.id)?.text
        XCTAssertEqual(v30, "Receipt 042 belongs to Project Borealis")
    }

    func testFTSQueryBuilder() {
        XCTAssertEqual(SQLiteStore.ftsQuery(from: "invoice 042 \"atlas\""), "\"invoice\"* \"042\"* \"atlas\"*")
        XCTAssertEqual(SQLiteStore.ftsQuery(from: "C++"), "\"c\"*".replacingOccurrences(of: "c", with: "C"))
        XCTAssertNil(SQLiteStore.ftsQuery(from: "  -- ** \"\" "))
        XCTAssertEqual(SQLiteStore.ftsQuery(from: "café Zürich"), "\"café\"* \"Zürich\"*")
    }

    // MARK: Memory

    func testEntitySearchRelationsAndForget() async throws {
        let provenance = Provenance(sourceType: .userMessage, note: "test")
        let invoice = MemoryEntity(kind: .document, name: "Invoice 042", attributes: ["amount": 1200, "vendor": "Acme Tools"], summary: "March invoice", provenance: provenance)
        let atlas = MemoryEntity(kind: .project, name: "Project Atlas", summary: "Warehouse migration", scope: "shared", provenance: provenance)
        let scoped = MemoryEntity(kind: .person, name: "Dana", summary: "Atlas project manager", scope: "agent-1", provenance: provenance)
        try await store.upsertEntity(invoice)
        try await store.upsertEntity(atlas)
        try await store.upsertEntity(scoped)

        let byName = try await store.findEntities(name: "project atlas", kind: nil, scopes: [])
        XCTAssertEqual(byName.map(\.id), [atlas.id])
        let v31 = try await store.findEntities(name: "Dana", kind: .person, scopes: ["shared"]).count
        XCTAssertEqual(v31, 0)
        let v32 = try await store.findEntities(name: "Dana", kind: .person, scopes: ["shared", "agent-1"]).count
        XCTAssertEqual(v32, 1)

        let hits = try await store.searchEntities(text: "atlas", scopes: [], includeInactive: false, limit: 10)
        XCTAssertEqual(Set(hits.map(\.0.id)), Set([atlas.id, scoped.id]))
        XCTAssertTrue(hits.allSatisfy { $0.1 <= 0 }, "bm25 ranks are negative or zero")
        let v33 = try await store.searchEntities(text: "acme", scopes: [], includeInactive: false, limit: 10).map(\.0.id)
        XCTAssertEqual(v33, [invoice.id], "attributes are indexed")
        let v34 = try await store.searchEntities(text: "atlas", scopes: ["shared"], includeInactive: false, limit: 10).map(\.0.id)
        XCTAssertEqual(v34, [atlas.id])
        let v35 = try await store.listEntities(kind: .project, scope: nil, includeInactive: false, limit: 10).map(\.id)
        XCTAssertEqual(v35, [atlas.id])

        let relation = MemoryRelation(fromEntityID: invoice.id, relation: "belongs_to", toEntityID: atlas.id, provenance: provenance)
        try await store.upsertRelation(relation)
        let v36 = try await store.relations(entityID: atlas.id, includeInactive: false).map(\.id)
        XCTAssertEqual(v36, [relation.id])
        let v37 = try await store.relations(entityID: invoice.id, includeInactive: false).map(\.id)
        XCTAssertEqual(v37, [relation.id])

        try await store.forgetEntity(invoice.id)
        let forgotten = try await store.entity(invoice.id)
        XCTAssertEqual(forgotten?.status, .forgotten)
        XCTAssertEqual(forgotten?.name, "")
        XCTAssertEqual(forgotten?.summary, "")
        XCTAssertEqual(forgotten?.attributes, .object([:]))
        let v38 = try await store.searchEntities(text: "acme", scopes: [], includeInactive: true, limit: 10).count
        XCTAssertEqual(v38, 0, "forgotten rows leave the FTS index")
        let v39 = try await store.searchEntities(text: "invoice", scopes: [], includeInactive: true, limit: 10).count
        XCTAssertEqual(v39, 0)
        let v40 = try await store.listEntities(kind: nil, scope: nil, includeInactive: false, limit: 10).count
        XCTAssertEqual(v40, 2)
        let v41 = try await store.listEntities(kind: nil, scope: nil, includeInactive: true, limit: 10).count
        XCTAssertEqual(v41, 3)

        try await store.forgetRelation(relation.id)
        let v42 = try await store.relations(entityID: atlas.id, includeInactive: false).count
        XCTAssertEqual(v42, 0)
        let v43 = try await store.relation(relation.id)?.status
        XCTAssertEqual(v43, .forgotten)
    }

    func testPreferencesSearchAndForget() async throws {
        let provenance = Provenance(sourceType: .userMessage)
        let p1 = Preference(text: "Always file invoices under the project folder", provenance: provenance)
        let p2 = Preference(text: "Reply in Portuguese to Dana", scope: "agent-1", provenance: provenance)
        try await store.upsertPreference(p1)
        try await store.upsertPreference(p2)
        let v44 = try await store.listPreferences(scopes: nil, includeInactive: false).count
        XCTAssertEqual(v44, 2)
        let v45 = try await store.listPreferences(scopes: ["shared"], includeInactive: false).map(\.id)
        XCTAssertEqual(v45, [p1.id])
        let v46 = try await store.searchPreferences(text: "invoices folder", scopes: [], limit: 5).map(\.0.id)
        XCTAssertEqual(v46, [p1.id])
        let v47 = try await store.searchPreferences(text: "portug", scopes: ["shared"], limit: 5).count
        XCTAssertEqual(v47, 0)

        var superseded = p1
        superseded.status = .superseded
        try await store.upsertPreference(superseded)
        let v48 = try await store.searchPreferences(text: "invoices", scopes: [], limit: 5).count
        XCTAssertEqual(v48, 0)
        let v49 = try await store.listPreferences(scopes: nil, includeInactive: true).count
        XCTAssertEqual(v49, 2)

        try await store.forgetPreference(p2.id)
        let v50 = try await store.preference(p2.id)?.text
        XCTAssertEqual(v50, "")
        let v51 = try await store.preference(p2.id)?.status
        XCTAssertEqual(v51, .forgotten)
        let v52 = try await store.searchPreferences(text: "dana", scopes: [], limit: 5).count
        XCTAssertEqual(v52, 0)
    }

    func testEmbeddingsNearest() async throws {
        try await store.putEmbedding(kind: "entity", itemID: "a", vector: [1, 0, 0])
        try await store.putEmbedding(kind: "entity", itemID: "b", vector: [0.9, 0.1, 0])
        try await store.putEmbedding(kind: "entity", itemID: "c", vector: [0, 1, 0])
        try await store.putEmbedding(kind: "skill", itemID: "d", vector: [1, 0, 0])
        try await store.putEmbedding(kind: "entity", itemID: "wrong-dims", vector: [1, 0])
        let nearest = try await store.nearestEmbeddings(kind: "entity", vector: [1, 0, 0], limit: 2)
        XCTAssertEqual(nearest.map(\.itemID), ["a", "b"])
        XCTAssertEqual(nearest[0].similarity, 1, accuracy: 1e-6)
        let v53 = try await store.nearestEmbeddings(kind: "entity", vector: [0, 0, 0], limit: 2).count
        XCTAssertEqual(v53, 0)
        try await store.putEmbedding(kind: "entity", itemID: "a", vector: [0, 0, 1])
        let v54 = try await store.nearestEmbeddings(kind: "entity", vector: [1, 0, 0], limit: 1).map(\.itemID)
        XCTAssertEqual(v54, ["b"])
    }

    func testMemoryOverviewCounts() async throws {
        let provenance = Provenance(sourceType: .inference)
        let a = MemoryEntity(kind: .person, name: "A", provenance: provenance)
        let b = MemoryEntity(kind: .person, name: "B", provenance: provenance)
        try await store.upsertEntity(a)
        try await store.upsertEntity(b)
        try await store.upsertRelation(MemoryRelation(fromEntityID: a.id, relation: "knows", toEntityID: b.id, provenance: provenance))
        try await store.upsertPreference(Preference(text: "p", provenance: provenance))
        try await store.upsertSkill(Skill(name: "s", purpose: "p"))
        var disabled = Skill(name: "off", purpose: "p")
        disabled.status = .disabled
        try await store.upsertSkill(disabled)
        try await store.appendMessage(makeMessage(conversation: ConversationID(), agent: a.id.rawValue == "" ? AgentID() : AgentID(), text: "m"))
        try await store.forgetEntity(b.id)
        let overview = try await store.memoryOverview()
        XCTAssertEqual(overview.entityCount, 1)
        XCTAssertEqual(overview.relationCount, 1)
        XCTAssertEqual(overview.preferenceCount, 1)
        XCTAssertEqual(overview.messageCount, 1)
        XCTAssertEqual(overview.skillCount, 1)
        XCTAssertGreaterThan(overview.databaseBytes, 0)
    }

    // MARK: Skills and MCP

    func testSkillsSearchAndDelete() async throws {
        let skill = Skill(name: "File invoice", purpose: "File a vendor invoice PDF into the project folder", applicability: "When a new invoice arrives by email")
        let other = Skill(name: "Book meeting", purpose: "Create a calendar event", applicability: "Scheduling")
        var disabled = Skill(name: "Old invoice flow", purpose: "Legacy invoice handling")
        disabled.status = .disabled
        try await store.upsertSkill(skill)
        try await store.upsertSkill(other)
        try await store.upsertSkill(disabled)
        let v55 = try await store.searchSkills(text: "invoice", limit: 10).map(\.id)
        XCTAssertEqual(v55, [skill.id])
        let v56 = try await store.searchSkills(text: "email arrives", limit: 10).map(\.id)
        XCTAssertEqual(v56, [skill.id])
        let v57 = try await store.listSkills(includeDisabled: false).count
        XCTAssertEqual(v57, 2)
        let v58 = try await store.listSkills(includeDisabled: true).count
        XCTAssertEqual(v58, 3)
        let v59 = try await store.skill(skill.id)?.name
        XCTAssertEqual(v59, "File invoice")
        try await store.deleteSkill(skill.id)
        let v60 = try await store.skill(skill.id)
        XCTAssertNil(v60)
        let v61 = try await store.searchSkills(text: "invoice", limit: 10).count
        XCTAssertEqual(v61, 0)
    }

    func testMCPServersAndSettings() async throws {
        let config = MCPServerConfig(name: "fs", transport: .stdio(command: "npx", arguments: ["-y", "server-filesystem"], environment: [:]))
        try await store.upsertMCPServer(config)
        let remote = MCPServerConfig(name: "remote", transport: .http(url: URL(string: "https://example.com/mcp")!))
        try await store.upsertMCPServer(remote)
        let v62 = try await store.listMCPServers().map(\.name)
        XCTAssertEqual(v62, ["fs", "remote"])
        try await store.removeMCPServer(config.id)
        let v63 = try await store.listMCPServers().map(\.name)
        XCTAssertEqual(v63, ["remote"])

        try await store.setSetting("token", value: "abc")
        let v64 = try await store.setting("token")
        XCTAssertEqual(v64, "abc")
        try await store.setSetting("token", value: "def")
        let v65 = try await store.setting("token")
        XCTAssertEqual(v65, "def")
        let v66 = try await store.setting("missing")
        XCTAssertNil(v66)
    }

    // MARK: Artifacts and backup

    func testArtifactsRoundTripAndDelete() async throws {
        let record = ArtifactRecord(kind: "screenshot", mimeType: "image/jpeg", byteCount: 0, fileName: "shot.jpg")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try await store.putArtifact(record, data: bytes)
        let v67 = try await store.artifact(record.id)?.byteCount
        XCTAssertEqual(v67, bytes.count)
        let v68 = try await store.artifactData(record.id)
        XCTAssertEqual(v68, bytes)
        try await store.deleteArtifact(record.id)
        let v69 = try await store.artifact(record.id)
        XCTAssertNil(v69)
        let v70 = try await store.artifactData(record.id)
        XCTAssertNil(v70)
    }

    func testBackupProducesConsistentCopy() async throws {
        let agent = makeAgent()
        for i in 0 ..< 25 {
            _ = try await store.appendEvent(.notice(level: .info, agentID: agent.id, text: "event \(i)"))
        }
        let artifact = ArtifactRecord(kind: "file", mimeType: "text/plain", byteCount: 0, fileName: "note.txt")
        try await store.putArtifact(artifact, data: Data("hello".utf8))

        let backupDir = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backupDir) }
        try await store.backup(to: backupDir)

        // The original keeps working after the backup.
        _ = try await store.appendEvent(.notice(level: .info, agentID: agent.id, text: "after backup"))
        let v71 = try await store.eventCount()
        XCTAssertEqual(v71, 26)

        let restored = try SQLiteStore(paths: HostPaths(root: backupDir))
        let v72 = try await restored.eventCount()
        XCTAssertEqual(v72, 25)
        let v73 = try await restored.latestEventSeq()
        XCTAssertEqual(v73, 25)
        let v74 = try await restored.artifactData(artifact.id)
        XCTAssertEqual(v74, Data("hello".utf8))
        await restored.close()
    }

    func testReopenKeepsDataAndDoesNotRerunMigrations() async throws {
        let agent = makeAgent()
        try await store.upsertAgent(agent)
        _ = try await store.appendEvent(.agentUpserted(agent))
        await store.close()
        let reopened = try SQLiteStore(paths: paths)
        let v75 = try await reopened.agent(agent.id)?.name
        XCTAssertEqual(v75, "Ada")
        let v76 = try await reopened.eventCount()
        XCTAssertEqual(v76, 1)
        await reopened.close()
        store = try SQLiteStore(paths: paths)
    }

    func testUndecodableRowsAreSkippedNotFatal() async throws {
        try await store.upsertSkill(Skill(name: "good", purpose: "p"))
        try await store.db.execute("INSERT INTO skills(id, name, status, version, updated_at, json) VALUES ('bad', 'bad', 'provisional', 1, 0, '{not json')")
        let skills = try await store.listSkills(includeDisabled: true)
        XCTAssertEqual(skills.map(\.name), ["good"])
    }

    // MARK: Conversation previews

    func testAppendMessageUpdatesConversationPreviewAndOrder() async throws {
        let agent = makeAgent()
        let old = Date(timeIntervalSinceNow: -3600)
        let a = Conversation(agentID: agent.id, title: "a", createdAt: old, updatedAt: old)
        let b = Conversation(agentID: agent.id, title: "b", createdAt: old.addingTimeInterval(60), updatedAt: old.addingTimeInterval(60))
        try await store.upsertConversation(a)
        try await store.upsertConversation(b)
        let before = try await store.listConversations(agentID: agent.id).map(\.id)
        XCTAssertEqual(before, [b.id, a.id])

        // A user message sets the preview (first line, markdown stripped) and moves the conversation to the top.
        try await store.appendMessage(makeMessage(conversation: a.id, agent: agent.id, text: "# Plan the trip\nSecond line"))
        var stored = try await store.conversation(a.id)
        XCTAssertEqual(stored?.preview, "Plan the trip")
        XCTAssertGreaterThan(stored?.updatedAt ?? old, old)
        let after = try await store.listConversations(agentID: agent.id).map(\.id)
        XCTAssertEqual(after, [a.id, b.id], "the updated_at column drives the order")

        // Tool and system messages, blank bodies, and streaming placeholders leave the row alone.
        let previewAt = stored?.updatedAt
        try await store.appendMessage(Message(conversationID: a.id, agentID: agent.id, role: .tool, parts: [.toolResult(ToolResult.text(ToolCallID("c1"), name: "shell", "listing"))]))
        try await store.appendMessage(Message(conversationID: a.id, agentID: agent.id, role: .system, parts: [.text("system note")]))
        try await store.appendMessage(Message(conversationID: a.id, agentID: agent.id, role: .assistant, parts: [.text("   ")]))
        var reply = Message(conversationID: a.id, agentID: agent.id, role: .assistant, parts: [], isStreaming: true, createdAt: Date(timeIntervalSinceNow: -1))
        try await store.appendMessage(reply)
        stored = try await store.conversation(a.id)
        XCTAssertEqual(stored?.preview, "Plan the trip")
        XCTAssertEqual(stored?.updatedAt, previewAt)

        // Finalising the streamed reply through updateMessage shows its first line and moves the row again.
        reply.parts = [.reasoning("thinking"), .text("**Sure**, here is the plan.\nDetails follow.")]
        reply.isStreaming = false
        try await store.updateMessage(reply)
        stored = try await store.conversation(a.id)
        XCTAssertEqual(stored?.preview, "Sure, here is the plan.")
        XCTAssertGreaterThanOrEqual(stored?.updatedAt ?? .distantPast, reply.createdAt)
        // Times are stored to the second, so within the same second "later" reads as equal.
        XCTAssertGreaterThanOrEqual(stored?.updatedAt ?? .distantPast, previewAt ?? .distantFuture)

        // A message whose conversation is not stored yet is still kept.
        let orphan = makeMessage(conversation: ConversationID(), agent: agent.id, text: "orphan")
        try await store.appendMessage(orphan)
        let keptOrphan = try await store.message(orphan.id)
        XCTAssertNotNil(keptOrphan)
    }
}
