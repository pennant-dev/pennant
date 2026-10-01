import PennantCore
import Foundation

/// Keeping memory current without asking the owner. When an agent finds something that disagrees with a fact on
/// record, the model weighs the two against what was actually said (the passages, with their dates) and keeps one,
/// takes the newer one, or combines them. Each decision is logged in plain words with a way to put it back; nothing
/// waits in a review queue.
extension MemoryService {
    static let upkeepLogKey = "memory_upkeep_log"
    static let upkeepLogLimit = 300
    /// Decisions per pass, so one pass stays quick; the rest wait for the next.
    static let upkeepBatch = 12

    struct Decision: Decodable {
        var decision: String
        var summary: String?
        var attributes: [String: JSONValue]?
        var reason: String?
    }

    static func upkeepPrompt(today: Date) -> String {
        """
        You keep a team's long-term memory current. Two versions of the same fact disagree: the one on record (usually \
        stated by the person, or confirmed before) and a newer claim an agent found. Decide what memory should hold now, \
        judging by what was actually said in the passages and their dates. Today is \(shortDate(today)).
        - take_new: the claim reflects a real change (a new date, version, status, owner, place) or corrects the record, and \
        the passages support it.
        - keep: the claim looks like a misreading, a guess, something about a different thing, or the passages contradict it.
        - combine: both hold; the claim adds or refines details without contradicting the record. Give the combined \
        one-sentence summary and attributes (dates as YYYY-MM-DD).
        The reason is one short sentence a busy person can read, naming what changed.
        Reply with JSON only: {"decision":"keep|take_new|combine","summary":"","attributes":{},"reason":""}
        """
    }

    static func describe(_ e: MemoryEntity) -> String {
        let attrs = e.attributes.objectValue.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.stringValue ?? $0.value.compactText)" }.joined(separator: "; ") } ?? ""
        return "\(e.name) (\(e.kind.rawValue), \(e.status == .asserted ? "stated" : "found by an agent") \(shortDate(e.observedAt))): \(e.summary)\(attrs.isEmpty ? "" : " [\(attrs)]")\(e.provenance.note.isEmpty ? "" : " — \(e.provenance.note)")"
    }

    static func parseDecision(_ output: String) -> Decision? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(Decision.self, from: Data(output[start ... end].utf8))
    }

    /// Settles every open contradiction it can (up to a batch) and returns what it decided.
    public func tend(complete: @Sendable ([ModelMessage]) async throws -> String) async -> [MemoryUpkeepEntry] {
        guard let open = try? await conflicts(), !open.isEmpty else { return [] }
        var done: [MemoryUpkeepEntry] = []
        for conflict in open.prefix(Self.upkeepBatch) {
            let passages = ((try? await evidence(for: conflict.current.id, limit: 6)) ?? [])
                .map { "- \(Self.shortDate($0.at)), \($0.speaker) in “\($0.title)”: \($0.text.prefix(500))" }
            var user = "On record: \(Self.describe(conflict.current))\nNewer claim: \(Self.describe(conflict.claim))"
            user += passages.isEmpty ? "\n\nNo passages mention it." : "\n\nWhat was said:\n" + passages.joined(separator: "\n")
            guard let raw = try? await complete([.system(Self.upkeepPrompt(today: Date())), .user(user)]),
                  let decision = Self.parseDecision(raw), let entry = try? await apply(decision, to: conflict) else { continue }
            done.append(entry)
        }
        if !done.isEmpty { await appendUpkeep(done) }
        return done
    }

    private func apply(_ d: Decision, to c: MemoryConflict) async throws -> MemoryUpkeepEntry? {
        let reason = (d.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = "Settled by Pennant: \(reason.isEmpty ? d.decision : reason)"
        var current = c.current, claim = c.claim
        switch d.decision.lowercased() {
        case "keep", "keep_current":
            claim.status = .superseded
            claim.supersededBy = current.id
            claim.updatedAt = Date()
            try await store.upsertEntity(claim)
            _ = try await publish(.memoryEntityUpserted(claim))
            return MemoryUpkeepEntry(action: .kept, name: current.name, reason: reason, keptID: current.id, droppedID: claim.id)
        case "take_new", "update":
            claim.status = .inferred
            claim.provenance.note = note
            claim.updatedAt = Date()
            current.status = .superseded
            current.supersededBy = claim.id
            current.updatedAt = Date()
            try await store.upsertEntity(current)
            try await store.upsertEntity(claim)
            _ = try await publish(.memoryEntityUpserted(current))
            _ = try await publish(.memoryEntityUpserted(claim))
            return MemoryUpkeepEntry(action: .updated, name: current.name, reason: reason, keptID: claim.id, droppedID: current.id)
        case "combine", "merge":
            var combined = MemoryEntity(kind: current.kind, name: current.name,
                                        attributes: d.attributes.map { .object($0) } ?? current.attributes,
                                        summary: (d.summary?.isEmpty == false ? d.summary! : current.summary),
                                        scope: current.scope, status: current.status,
                                        provenance: Provenance(sourceType: .inference, sourceID: claim.id.rawValue, note: note))
            combined.version = max(current.version, claim.version) + 1
            current.status = .superseded; current.supersededBy = combined.id; current.updatedAt = Date()
            claim.status = .superseded; claim.supersededBy = combined.id; claim.updatedAt = Date()
            try await store.upsertEntity(combined)
            try await store.upsertEntity(current)
            try await store.upsertEntity(claim)
            for e in [current, claim, combined] { _ = try await publish(.memoryEntityUpserted(e)) }
            return MemoryUpkeepEntry(action: .combined, name: current.name, reason: reason, keptID: combined.id, droppedID: current.id)
        default:
            return nil
        }
    }

    // MARK: Log

    public func upkeepLog() async -> [MemoryUpkeepEntry] {
        guard let raw = try? await store.setting(Self.upkeepLogKey), let data = raw.data(using: .utf8),
              let entries = try? JSONCodec.decode([MemoryUpkeepEntry].self, from: data) else { return [] }
        return entries
    }

    private func appendUpkeep(_ new: [MemoryUpkeepEntry]) async {
        let all = Array((new.reversed() + (await upkeepLog())).prefix(Self.upkeepLogLimit))
        if let data = try? JSONCodec.encode(all), let text = String(data: data, encoding: .utf8) {
            try? await store.setSetting(Self.upkeepLogKey, value: text)
        }
    }

    /// Puts back what a decision set aside: the owner's word settles it for good.
    public func undoUpkeep(_ id: String) async throws -> [MemoryUpkeepEntry] {
        var all = await upkeepLog()
        guard let i = all.firstIndex(where: { $0.id == id }), !all[i].undone else { return all }
        _ = try await resolve(keep: all[i].droppedID, drop: all[i].keptID)
        all[i].undone = true
        if let data = try? JSONCodec.encode(all), let text = String(data: data, encoding: .utf8) {
            try? await store.setSetting(Self.upkeepLogKey, value: text)
        }
        return all
    }
}
