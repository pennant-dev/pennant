import PennantCore
import Foundation

/// Learning after a task, as Binders extracts after each note: the durable facts a finished task established are
/// written to memory without the agent having to remember to. Only the person's words and the agent's final
/// answer are read, so what is kept is what was said or found, not the agent's working notes. What the person
/// said is asserted; what the agent found out is inferred, so it never silently overrides the person.
enum MemoryLearner {
    struct Learned: Decodable {
        var facts: [Fact] = []
        var relations: [Relation] = []
    }

    struct Fact: Decodable {
        var kind: String
        var name: String
        var summary: String?
        var attributes: [String: String]?
        /// Stated by the person rather than found by the agent.
        var fromUser: Bool?

        enum CodingKeys: String, CodingKey { case kind, name, summary, attributes, fromUser = "from_user" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decode(String.self, forKey: .kind)) ?? "fact"
            name = try c.decode(String.self, forKey: .name)
            summary = try? c.decodeIfPresent(String.self, forKey: .summary)
            // Values the model writes as numbers or booleans still count.
            if let raw = try? c.decodeIfPresent([String: JSONValue].self, forKey: .attributes) {
                attributes = raw.compactMapValues { $0.stringValue ?? ($0.compactText.isEmpty ? nil : $0.compactText) }
            }
            fromUser = try? c.decodeIfPresent(Bool.self, forKey: .fromUser)
        }
    }

    struct Relation: Decodable {
        var from: String
        var to: String
        var label: String
    }

    static let maxFacts = 8

    static func systemPrompt(today: Date) -> String {
        let kinds = MemoryEntityKind.allCases.map(\.rawValue).joined(separator: "|")
        return """
        You keep a team's long-term memory. From one exchange (the person's words and the assistant's final answer), write down the \
        durable facts worth knowing next time: who someone is and what they own, projects and their status, events and their dates \
        and places, decisions, deadlines, accounts, where things live, commitments. Today is \(MemoryService.shortDate(today)).
        - Only facts stated in the exchange. Nothing about how the assistant worked, what it searched, or what it couldn't find.
        - Skip the momentary: greetings, the question itself, anything true only today.
        - One fact per real-world thing, under its canonical, properly capitalized name (reuse a known name below when it is the \
        same thing). The summary is one sentence that stands on its own; put specifics (dates as YYYY-MM-DD, places, amounts, \
        emails, URLs, IDs) in attributes.
        - from_user is true only when the person stated it themselves.
        - Relations connect two fact names with a short label, e.g. {"from":"Northwind","to":"Harbor 2.0 launch","label":"partners on"}.
        - At most \(maxFacts) facts and \(maxFacts) relations. If nothing is worth keeping, return empty lists.
        Reply with JSON only:
        {"facts":[{"kind":"\(kinds)","name":"","summary":"","attributes":{},"from_user":false}],"relations":[{"from":"","to":"","label":""}]}
        """
    }

    static func messages(question: String, answer: String, known: [String], today: Date = Date()) -> [ModelMessage] {
        var user = "The person said:\n\(question.prefix(4000))\n\nThe assistant's final answer:\n\(answer.prefix(6000))"
        if !known.isEmpty { user += "\n\nAlready known (reuse these names when they're the same thing): \(known.prefix(20).joined(separator: "; "))" }
        return [.system(systemPrompt(today: today)), .user(user)]
    }

    /// Tolerates code fences and prose around the JSON.
    static func parse(_ output: String) -> Learned {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let learned = try? JSONDecoder().decode(Learned.self, from: Data(output[start ... end].utf8)) else { return Learned() }
        return clean(learned)
    }

    /// Drops empty and over-long names, generic words, and anything beyond the caps.
    static func clean(_ l: Learned) -> Learned {
        let generic: Set<String> = ["meeting", "team", "project", "company", "user", "the user", "assistant", "email", "calendar", "update", "today", "question"]
        var out = Learned()
        var names = Set<String>()
        for var f in l.facts {
            f.name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = MemoryService.normalize(f.name)
            guard f.name.count >= 2, f.name.count <= 80, !generic.contains(key), names.insert(key).inserted else { continue }
            out.facts.append(f)
            if out.facts.count == maxFacts { break }
        }
        out.relations = Array(l.relations.filter { !$0.label.isEmpty && names.contains(MemoryService.normalize($0.from)) && names.contains(MemoryService.normalize($0.to)) }.prefix(maxFacts))
        return out
    }

    /// Whether a finished exchange is worth learning from: something new came in (from outside Pennant, or the
    /// person told it something), the answer has substance, and it isn't a scheduled job's routine report.
    static func worthLearning(question: String, answer: String, toolsUsed: [String]) -> Bool {
        guard answer.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else { return false }
        if question.hasPrefix("Scheduled job \"") { return false }
        let ownTools: Set<String> = ["memory_search", "memory_remember", "remember_instruction", "find_tools", "find_skill", "use_skill", "list_schedules", "list_contacts"]
        let outside = toolsUsed.contains { !ownTools.contains($0) }
        let told = !question.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") && MemoryChunker.wordCount(question) >= 8
        return outside || told
    }
}

extension MemoryService {
    /// Writes what a finished exchange established. Returns the names remembered.
    @discardableResult
    public func learn(question: String, answer: String, taskID: TaskID, agentID: AgentID, taskTitle: String,
                      complete: @Sendable ([ModelMessage]) async throws -> String) async -> [String] {
        do {
            let known = try await retrieve(MemoryQuery(text: String((question + " " + answer).prefix(500)), limit: 15), agent: nil, includeMessages: false)
                .compactMap { hit -> String? in if case .entity(let e) = hit.item { return e.name } else { return nil } }
            let learned = MemoryLearner.parse(try await complete(MemoryLearner.messages(question: question, answer: answer, known: known)))
            var remembered: [String] = []
            for f in learned.facts {
                let fromUser = f.fromUser ?? false
                let provenance = Provenance(sourceType: fromUser ? .userMessage : .toolObservation, sourceID: taskID.rawValue, agentID: agentID,
                                            note: "Learned after “\(taskTitle.prefix(80))”")
                let attributes = JSONValue.object((f.attributes ?? [:]).mapValues { .string($0) })
                do {
                    let e = try await assertEntity(kind: MemoryEntityKind(rawValue: f.kind) ?? .fact, name: f.name, attributes: attributes, summary: f.summary ?? "",
                                                   scope: "shared", status: fromUser ? .asserted : .inferred, provenance: provenance)
                    remembered.append(e.name)
                } catch {
                    // Removed by the user, or otherwise refused: not remembered.
                }
            }
            for r in learned.relations {
                let from = learned.facts.first { MemoryService.normalize($0.name) == MemoryService.normalize(r.from) }
                let to = learned.facts.first { MemoryService.normalize($0.name) == MemoryService.normalize(r.to) }
                guard let from, let to else { continue }
                _ = try? await relate(fromName: from.name, fromKind: MemoryEntityKind(rawValue: from.kind) ?? .fact, relation: r.label,
                                      toName: to.name, toKind: MemoryEntityKind(rawValue: to.kind) ?? .fact, scope: "shared", status: .inferred,
                                      provenance: Provenance(sourceType: .inference, sourceID: taskID.rawValue, agentID: agentID, note: "Learned after “\(taskTitle.prefix(80))”"))
            }
            return remembered
        } catch {
            log.warn("Learning after a task failed: \(error)", category: "memory")
            return []
        }
    }
}
