import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// A stand-in embedding model: words hashed into a small vector, so texts that share words are close. It records
/// what it was asked to embed, to check the task prompts.
final class WordEmbeddings: EmbeddingProvider, @unchecked Sendable {
    let modelName: String
    private let lock = NSLock()
    private(set) var inputs: [String] = []
    init(model: String = "embeddinggemma") { modelName = model }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { inputs += texts }
        return texts.map { text in
            var v = [Float](repeating: 0, count: 64)
            // Only the content counts, not the task prompt around it.
            let content = text.replacingOccurrences(of: "task: search result | query:", with: "").replacingOccurrences(of: "title:", with: "").replacingOccurrences(of: "| text:", with: "")
            // FNV-1a: the same word lands in the same slot on every run (Swift's hashValue changes per process).
            for word in content.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count > 2 {
                var h: UInt64 = 0xcbf29ce484222325
                for byte in word.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
                v[Int(h % 64)] += 1
            }
            return v
        }
    }
}

final class MemoryRetrievalTests: XCTestCase {
    var paths: HostPaths!
    var store: SQLiteStore!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        store = try SQLiteStore(paths: paths)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private let told = Provenance(sourceType: .userMessage, note: "test")

    func testKeywordAndMeaningResultsAreFusedByRank() async throws {
        let embeddings = WordEmbeddings()
        let memory = MemoryService(store: store, eventBus: EventBus(), embeddings: embeddings)
        // Matches the words and the meaning; the other only shares a word.
        try await memory.assertEntity(kind: .project, name: "Atlas migration", summary: "moving billing to the new cluster", scope: "shared", status: .asserted, provenance: told)
        try await memory.assertEntity(kind: .project, name: "Atlas archive", summary: "old photos", scope: "shared", status: .asserted, provenance: told)
        let hits = try await memory.retrieve(MemoryQuery(text: "atlas billing cluster"), agent: nil, includeMessages: false)
        guard case .entity(let first)? = hits.first?.item else { return XCTFail("no hits") }
        XCTAssertEqual(first.name, "Atlas migration")
        XCTAssertTrue(embeddings.inputs.contains { $0.hasPrefix("task: search result | query: atlas billing cluster") }, "queries use EmbeddingGemma's search prompt")
        XCTAssertTrue(embeddings.inputs.contains { $0.hasPrefix("title: Atlas migration | text:") }, "memories use its document prompt")
    }

    /// The company's name is on most facts; the question's rarer word decides which one is meant.
    func testAWordOnMostFactsDoesntDecideTheAnswer() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus())
        for i in 0 ..< 24 {
            try await memory.assertEntity(kind: .account, name: "Acme account \(i)", summary: "Acme's account number \(i)", scope: "shared", status: .asserted, provenance: told)
        }
        try await memory.assertEntity(kind: .topic, name: "Summit 2026", summary: "The conference Acme exhibits at in November", scope: "shared", status: .inferred, provenance: told)
        let hits = try await memory.retrieve(MemoryQuery(text: "what conference is acme going to"), agent: nil, includeMessages: false)
        guard case .entity(let first)? = hits.first?.item else { return XCTFail("no hits") }
        XCTAssertEqual(first.name, "Summit 2026")
    }

    func testContradictedFactsStayOutOfAnAgentsContext() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus())
        try await memory.assertEntity(kind: .person, name: "Dana Kim", summary: "works at Globex", scope: "shared", status: .asserted, provenance: told)
        let guess = try await memory.assertEntity(kind: .person, name: "Dana Kim", summary: "works at Initech", scope: "shared", status: .inferred, provenance: Provenance(sourceType: .inference))
        XCTAssertEqual(guess.status, .contradicted)
        let context = try await memory.retrieve(MemoryQuery(text: "Dana Kim"), agent: nil, includeMessages: false, forContext: true)
        XCTAssertFalse(context.contains { if case .entity(let e) = $0.item { return e.status == .contradicted }; return false })
        let search = try await memory.retrieve(MemoryQuery(text: "Dana Kim"), agent: nil, includeMessages: false)
        XCTAssertTrue(search.contains { if case .entity(let e) = $0.item { return e.status == .contradicted }; return false }, "an explicit search still shows it, to settle")
    }

    func testAnotherAgentsPrivateMemoryDoesNotLeakThroughMeaning() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus(), embeddings: WordEmbeddings())
        try await memory.assertEntity(kind: .fact, name: "Salary review", summary: "private salary review notes", scope: "agent-a", status: .asserted, provenance: told)
        let other = AgentProfile(name: "B", role: "helper", memoryScope: MemoryScope(label: "agent-b"))
        let hits = try await memory.retrieve(MemoryQuery(text: "salary review notes"), agent: other, includeMessages: false)
        XCTAssertTrue(hits.isEmpty, "\(hits)")
    }

    func testAPrivateWriteUpdatesTheSharedFactInsteadOfCopyingIt() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus())
        try await memory.assertEntity(kind: .project, name: "Atlas", summary: "billing move", scope: "shared", status: .asserted, provenance: told)
        let updated = try await memory.assertEntity(kind: .project, name: "Atlas", summary: "billing move, due in May", scope: "agent-a", status: .asserted, provenance: told)
        XCTAssertEqual(updated.scope, "shared")
        let privateCopies = try await store.findEntities(name: "Atlas", kind: .project, scopes: ["agent-a"])
        XCTAssertTrue(privateCopies.isEmpty)
    }

    func testGraphNeighboursComeFromTheStrongestHitsNotTheAlphabet() async throws {
        let memory = MemoryService(store: store, eventBus: EventBus())
        // Six weak alphabetically-early matches, and the one that matches best, which has a relation.
        for i in 0 ..< 6 {
            try await memory.assertEntity(kind: .other, name: "Aardvark \(i) invoice", scope: "shared", status: .inferred, provenance: told)
        }
        try await memory.assertEntity(kind: .document, name: "Zulu invoice 77", summary: "invoice 77 from Zulu supplies", scope: "shared", status: .asserted, provenance: told)
        try await memory.relate(fromName: "Zulu invoice 77", fromKind: .document, relation: "belongs_to", toName: "Project Kite", toKind: .project, scope: "shared", status: .asserted, provenance: told)
        let hits = try await memory.retrieve(MemoryQuery(text: "invoice 77 zulu supplies", limit: 20), agent: nil, includeMessages: false)
        XCTAssertTrue(MemoryService.render(hits).contains("belongs_to"))
    }

    func testBackfillEmbedsOldMemoriesAndRedoesThemWhenTheModelChanges() async throws {
        // Saved with meaning search off.
        let plain = MemoryService(store: store, eventBus: EventBus())
        try await plain.assertEntity(kind: .person, name: "Sam Lee", summary: "designer", scope: "shared", status: .asserted, provenance: told)
        try await plain.addPreference(text: "Send drafts before noon", scope: "shared", provenance: told)
        let embedded0 = try await store.embeddedItemIDs(kind: "entity")
        XCTAssertTrue(embedded0.isEmpty)

        let first = WordEmbeddings(model: "embeddinggemma")
        await MemoryService(store: store, eventBus: EventBus(), embeddings: first).backfillEmbeddings()
        let entities = try await store.embeddedItemIDs(kind: "entity")
        let prefs = try await store.embeddedItemIDs(kind: "preference")
        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(prefs.count, 1)
        let recorded = try await store.setting("embedding_model")
        XCTAssertEqual(recorded, "embeddinggemma")

        // Nothing to do the second time; a new model re-embeds everything.
        let again = WordEmbeddings(model: "embeddinggemma")
        await MemoryService(store: store, eventBus: EventBus(), embeddings: again).backfillEmbeddings()
        XCTAssertTrue(again.inputs.isEmpty)
        let other = WordEmbeddings(model: "nomic-embed-text")
        await MemoryService(store: store, eventBus: EventBus(), embeddings: other).backfillEmbeddings()
        XCTAssertEqual(other.inputs.count, 2)
        XCTAssertFalse(other.inputs.contains { $0.hasPrefix("title:") }, "task prompts are only for EmbeddingGemma")
    }
}

final class MemoryEvidenceTests: XCTestCase {
    var paths: HostPaths!
    var store: SQLiteStore!
    var memory: MemoryService!
    let told = Provenance(sourceType: .userMessage, note: "test")

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        store = try SQLiteStore(paths: paths)
        memory = MemoryService(store: store, eventBus: EventBus(), embeddings: WordEmbeddings())
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    /// A conversation with an agent, as people had it.
    @discardableResult
    private func converse(_ agentName: String, title: String, _ lines: [(MessageRole, String)]) async throws -> (AgentProfile, Conversation) {
        let agents = try await store.listAgents(includeRetired: true)
        var agent = agents.first { $0.name == agentName }
        if agent == nil {
            agent = AgentProfile(name: agentName, role: "helper")
            try await store.upsertAgent(agent!)
        }
        var conversation = Conversation(agentID: agent!.id, title: title)
        try await store.upsertConversation(conversation)
        for (i, (role, text)) in lines.enumerated() {
            let m = Message(conversationID: conversation.id, agentID: agent!.id, role: role, parts: [.text(text)],
                            createdAt: Date().addingTimeInterval(Double(i)),
                            author: role == .user ? MessageAuthor(id: PersonID("p1"), name: "Maya") : nil)
            try await store.appendMessage(m)
        }
        conversation = try await store.conversation(conversation.id) ?? conversation
        return (agent!, conversation)
    }

    func testWhatWasSaidIsIndexedCitedAndKeptCurrent() async throws {
        let (_, pricing) = try await converse("Architect", title: "Pricing decision", [
            (.user, "We agreed the Team plan stays at 49 dollars per seat and Enterprise moves to annual contracts only."),
            (.assistant, "Noted: Team remains 49 dollars per seat per month, and Enterprise will be sold on annual contracts only, starting next quarter."),
        ])
        try await converse("Poster", title: "Launch post", [
            (.user, "Draft a post about the new dashboard for LinkedIn please, keep it short."),
        ])
        let indexed = await memory.syncPassages()
        XCTAssertEqual(indexed, 2)
        let again = await memory.syncPassages()
        XCTAssertEqual(again, 0, "unchanged conversations are skipped")

        let hits = try await memory.retrieve(MemoryQuery(text: "what did we decide about enterprise contracts"), agent: nil, includeMessages: true)
        guard case .passage(let p)? = hits.first?.item else { return XCTFail("expected a passage first, got \(hits.map(\.item))") }
        XCTAssertEqual(p.title, "Pricing decision")
        XCTAssertTrue(p.text.hasPrefix("Maya:"), "passages keep who spoke")
        XCTAssertTrue(MemoryService.render(hits).hasPrefix("[1] conversation \"Pricing decision\""))

        // The conversation being worked on isn't cited back to itself.
        let elsewhere = try await memory.retrieve(MemoryQuery(text: "enterprise annual contracts"), agent: nil, excludingConversation: pricing.id)
        XCTAssertFalse(elsewhere.contains { if case .passage(let p) = $0.item { return p.conversationID == pricing.id }; return false })

        // A deleted conversation's passages go with it.
        try await store.deleteConversations([pricing.id])
        await memory.syncPassages()
        let after = try await memory.retrieve(MemoryQuery(text: "enterprise annual contracts"), agent: nil)
        XCTAssertFalse(after.contains { if case .passage = $0.item { return true }; return false })
    }

    func testAFactShowsTheWordsBehindItAndRenamesKeepOldNames() async throws {
        try await converse("Architect", title: "Clusters", [
            (.user, "Project Kite is the new name for the billing migration, owned by Sam."),
        ])
        await memory.syncPassages()
        let kite = try await memory.assertEntity(kind: .project, name: "Project Kite", summary: "billing migration", scope: "shared", status: .asserted, provenance: told)
        let evidence = try await memory.evidence(for: kite.id)
        XCTAssertEqual(evidence.first?.title, "Clusters")

        // Renamed: agents still writing the old name update the renamed fact.
        let renamed = try await memory.rename(kite.id, to: "Kite")
        XCTAssertEqual(renamed.name, "Kite")
        let updated = try await memory.assertEntity(kind: .project, name: "project kite", summary: "billing migration, owned by Sam", scope: "shared", status: .asserted, provenance: told)
        XCTAssertEqual(updated.name, "Kite")
        let evidenceAfter = try await memory.evidence(for: updated.id)
        XCTAssertFalse(evidenceAfter.isEmpty, "the old name still finds the evidence")
    }

    func testMergingMovesRelationsAndRenamingOntoAnotherNameMerges() async throws {
        let bob = try await memory.assertEntity(kind: .person, name: "Bob", summary: "", scope: "shared", status: .inferred, provenance: told)
        let full = try await memory.assertEntity(kind: .person, name: "Bob Smith", summary: "finance lead", scope: "shared", status: .asserted, provenance: told)
        try await memory.relate(fromName: "Bob", fromKind: .person, relation: "owns", toName: "Budget 2027", toKind: .document, scope: "shared", status: .asserted, provenance: told)
        let merged = try await memory.rename(bob.id, to: "Bob Smith")
        XCTAssertEqual(merged.id, full.id)
        let rels = try await store.relations(entityID: full.id, includeInactive: false)
        XCTAssertTrue(rels.contains { $0.relation == "owns" })
        let again = try await memory.assertEntity(kind: .person, name: "bob", summary: "finance lead", scope: "shared", status: .asserted, provenance: told)
        XCTAssertEqual(again.name, "Bob Smith", "the merged name is an alias")
    }

    func testRemovedNamesStayRemovedUntilRestored() async throws {
        let e = try await memory.assertEntity(kind: .person, name: "The Old Vendor", summary: "no longer relevant", scope: "shared", status: .asserted, provenance: told)
        try await memory.forgetEntity(e.id)
        do {
            _ = try await memory.assertEntity(kind: .person, name: "old vendor", summary: "back again", scope: "shared", status: .inferred, provenance: told)
            XCTFail("a removed name came back")
        } catch {}
        let removed = try await memory.ignoredNames()
        XCTAssertEqual(removed.map(\.name), ["The Old Vendor"])
        try await memory.restore("The Old Vendor", kind: .person)
        let back = try await memory.assertEntity(kind: .person, name: "old vendor", summary: "relevant again", scope: "shared", status: .asserted, provenance: told)
        XCTAssertEqual(back.status, .asserted)
    }

    func testContradictionsWaitForReviewAndKeepingTheClaimMakesItTheFact() async throws {
        try await memory.assertEntity(kind: .person, name: "Dana", summary: "works at Globex", scope: "shared", status: .asserted, provenance: told)
        let claim = try await memory.assertEntity(kind: .person, name: "Dana", summary: "works at Initech", scope: "shared", status: .inferred, provenance: Provenance(sourceType: .inference))
        let conflicts = try await memory.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        let kept = try await memory.resolve(keep: claim.id, drop: conflicts[0].current.id)
        XCTAssertEqual(kept.status, .asserted)
        let remaining = try await memory.conflicts()
        XCTAssertTrue(remaining.isEmpty)
        let hits = try await memory.retrieve(MemoryQuery(text: "Dana"), agent: nil, includeMessages: false, forContext: true)
        guard case .entity(let top)? = hits.first?.item else { return XCTFail("no hit") }
        XCTAssertEqual(top.summary, "works at Initech")
    }
}

/// Recall check, after Binders' self-test: a small, realistic memory (facts, instructions, conversations) and
/// questions phrased the way people ask them. Each must find its source in the top three. When a change to
/// retrieval makes this worse, it shows here.
final class MemoryRecallCheck: XCTestCase {
    func testQuestionsFindTheirSources() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let memory = MemoryService(store: store, eventBus: EventBus(), embeddings: WordEmbeddings())
        let told = Provenance(sourceType: .userMessage)

        try await memory.assertEntity(kind: .person, name: "Sam Lee", attributes: ["email": "sam@example.com"], summary: "Head of design, owns the brand guidelines", scope: "shared", status: .asserted, provenance: told)
        try await memory.assertEntity(kind: .project, name: "Project Kite", summary: "Moving billing from Stripe to Adyen by the end of June", scope: "shared", status: .asserted, provenance: told)
        try await memory.assertEntity(kind: .application, name: "Grafana", summary: "Dashboards for the production clusters at grafana.internal", scope: "shared", status: .asserted, provenance: told)
        try await memory.assertEntity(kind: .deadline, name: "SOC 2 audit", summary: "Evidence due to the auditor on 14 November", scope: "shared", status: .asserted, provenance: told)
        try await memory.addPreference(text: "Always send invoices from the finance mailbox, never from a personal address.", scope: "shared", provenance: told)
        try await memory.addPreference(text: "LinkedIn posts go out on weekdays at 8am, never on weekends.", scope: "shared", provenance: told)

        let agent = AgentProfile(name: "Architect", role: "knows the system")
        try await store.upsertAgent(agent)
        func converse(_ title: String, _ lines: [(MessageRole, String)]) async throws {
            let c = Conversation(agentID: agent.id, title: title)
            try await store.upsertConversation(c)
            for (i, (role, text)) in lines.enumerated() {
                try await store.appendMessage(Message(conversationID: c.id, agentID: agent.id, role: role, parts: [.text(text)], createdAt: Date().addingTimeInterval(Double(i))))
            }
        }
        try await converse("Database outage", [
            (.user, "What happened with the database last night?"),
            (.assistant, "The primary Postgres node ran out of disk at 02:10 because WAL archiving stalled; we failed over to the replica and cleared 40 GB of old archives. Root cause was the backup job's expired storage key."),
        ])
        try await converse("Hiring", [
            (.user, "Let's hold the two backend roles until the new year, but keep interviewing for the designer position."),
            (.assistant, "Understood: backend hiring paused until January, the designer search continues and Sam Lee will run the portfolio reviews."),
        ])
        try await converse("Pricing", [
            (.user, "Final call on pricing: the Team plan stays at 49 dollars per seat, Enterprise becomes annual-only."),
        ])
        await memory.syncPassages()

        let questions: [(String, (MemoryHit.Item) -> Bool)] = [
            ("who is in charge of the brand guidelines", { if case .entity(let e) = $0 { return e.name == "Sam Lee" }; return false }),
            ("when does the billing move to Adyen need to be done", { if case .entity(let e) = $0 { return e.name == "Project Kite" }; return false }),
            ("where are the cluster dashboards", { if case .entity(let e) = $0 { return e.name == "Grafana" }; return false }),
            ("what's the deadline for the audit evidence", { if case .entity(let e) = $0 { return e.name == "SOC 2 audit" }; return false }),
            ("which mailbox should invoices come from", { if case .preference(let p) = $0 { return p.text.contains("finance mailbox") }; return false }),
            ("can we post on linkedin on saturday", { if case .preference(let p) = $0 { return p.text.contains("weekends") }; return false }),
            ("why did postgres go down", { if case .passage(let p) = $0 { return p.title == "Database outage" }; return false }),
            ("are we still hiring backend engineers", { if case .passage(let p) = $0 { return p.title == "Hiring" }; return false }),
            ("how much is the team plan per seat", { if case .passage(let p) = $0 { return p.title == "Pricing" }; return false }),
        ]
        var misses: [String] = []
        for (question, matches) in questions {
            let hits = try await memory.retrieve(MemoryQuery(text: question, limit: 10), agent: agent, includeMessages: false, forContext: true)
            if !hits.prefix(3).contains(where: { matches($0.item) }) { misses.append(question) }
        }
        XCTAssertTrue(misses.isEmpty, "Not in the top 3: \(misses)")
    }
}
