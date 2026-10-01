import PennantCore
import Foundation

// Which model a task runs on (the agent's profile, the host default, a fallback), which tools it sees on each turn
// (core tools always, connected services on demand), and the check that keeps an agent from stopping at an offer.

extension TaskRuntime {
    /// One model a task can run on.
    struct ModelChoice: Sendable {
        var provider: any InferenceProvider
        /// What the choice is called in notices: the profile name or the host's model id.
        var label: String
        var maxOutputTokens: Int
        /// The profile's or the host's reasoning effort; the agent's own setting overrides it.
        var reasoningEffort: String?
        /// For the usage ledger: which profile, which provider and model id, and its prices.
        var profileID: String? = nil
        var providerID: String = HostConfig.Inference.openAIProvider
        var modelID: String = ""
        var pricing: ModelPricing? = nil
    }

    /// The models a task may use, in order: the agent's profile (when set), the host's default, then the host's
    /// fallback profile. A task moves down the list when a model refuses it, runs out of quota, or keeps failing.
    func modelChoices(for agent: AgentProfile) async -> [ModelChoice] {
        let config = deps.config
        var out: [ModelChoice] = []
        func profile(_ id: String?) async -> ModelChoice? {
            guard let id, let make = deps.makeProvider, let p = config.inferenceProfiles.first(where: { $0.id == id }) else { return nil }
            return ModelChoice(provider: await make(p.inference), label: p.name, maxOutputTokens: p.inference.maxOutputTokens, reasoningEffort: p.inference.reasoningEffort,
                               profileID: p.id, providerID: p.inference.provider, modelID: p.inference.model, pricing: p.effectivePricing)
        }
        // The agent's own model (or the default), then the fallbacks in the order the user set, then the default
        // model last when the agent had its own; no model twice.
        let hostDefault = ModelChoice(provider: deps.provider, label: config.defaultProfile?.name ?? config.inference.model, maxOutputTokens: config.inference.maxOutputTokens, reasoningEffort: config.inference.reasoningEffort,
                                      profileID: config.defaultProfileID, providerID: config.inference.provider, modelID: config.inference.model, pricing: config.defaultProfile?.effectivePricing)
        let own = await profile(agent.modelProfileID)
        out.append(own ?? hostDefault)
        for id in config.fallbackProfileIDs where id != agent.modelProfileID && id != config.defaultProfileID {
            if let fallback = await profile(id) { out.append(fallback) }
        }
        if own != nil, agent.modelProfileID != config.defaultProfileID { out.append(hostDefault) }
        // Leave out models whose quota is used up until they reset, and models resting after an outage (unless
        // nothing else is left).
        let now = Date()
        exhaustedUntil = exhaustedUntil.filter { $0.value > now }
        downUntil = downUntil.filter { $0.value > now }
        let available = out.filter { exhaustedUntil[$0.label] == nil && downUntil[$0.label] == nil }
        return available.isEmpty ? out : available
    }

    static let effortLevels = ["minimal", "low", "medium", "high", "xhigh"]

    /// The highest effort any skill the task follows asks for (`effort:` in its SKILL.md), or nil.
    func skillEffort(task: TaskRecord) async -> String? {
        var best: String?
        for id in await deps.skillTracker.usedSkills(in: task.id) {
            guard let e = try? await deps.store.skill(id)?.outputs?.effort else { continue }
            best = Self.raise(best, to: e) ?? e
        }
        return best
    }

    /// `effort` raised to at least `floor`. A model with no effort setting keeps none: not every endpoint takes one.
    static func raise(_ effort: String?, to floor: String?) -> String? {
        guard let effort, let floor, let a = effortLevels.firstIndex(of: effort), let b = effortLevels.firstIndex(of: floor) else { return effort }
        return effortLevels[max(a, b)]
    }

    /// The choice the task is on now (it stays on a fallback for the rest of the task once it moved).
    func currentModel(task: TaskRecord, agent: AgentProfile) async -> ModelChoice {
        let choices = await modelChoices(for: agent)
        return choices[min(modelIndex[task.id] ?? 0, choices.count - 1)]
    }

    /// Whether a refusal should move the task to the next model instead of failing it: the model or deployment
    /// is missing, the key or account is refused, the request shape is rejected, or rate limits did not clear.
    static func shouldFallBack(_ error: InferenceError) -> Bool {
        if case .httpStatus(let code, _) = error { return (400 ..< 500).contains(code) && code != 413 }
        return false
    }

    /// A failure on the model's side (5xx, unreachable) rather than a refusal of the request.
    static func isServerError(_ error: InferenceError) -> Bool {
        if case .unreachable = error { return true }
        if case .httpStatus(let code, _) = error { return code >= 500 }
        return false
    }

    /// Seconds to wait before each retry of the same model after a server error, and how long a model that kept
    /// failing is skipped (tests shorten both).
    nonisolated(unsafe) static var serverErrorWaits: [Double] = [3, 6]
    nonisolated(unsafe) static var outageCooldown: TimeInterval = 180

    /// How long a task waits, paused, when every model it may use is rate limited (tests shorten it).
    nonisolated(unsafe) static var rateLimitPause: TimeInterval = 120

    /// Seconds to wait before each retry after a 429 (tests shorten them).
    nonisolated(unsafe) static var rateLimitWaits: [Double] = [10, 30, 60]

    /// When a 429 says the quota itself is used up (not a short burst limit): until when, from the provider's
    /// `resets_at` (epoch seconds) or `resets_in_seconds` when present, else an hour from now.
    static func quotaExhausted(_ error: InferenceError, now: Date = Date()) -> Date? {
        guard case .httpStatus(429, let body) = error else { return nil }
        let lower = body.lowercased()
        guard ["usage_limit_reached", "insufficient_quota", "quota_exceeded", "exceeded your current quota", "usage limit has been reached"].contains(where: lower.contains) else { return nil }
        if let m = body.firstMatch(of: /"resets_at"\s*:\s*(\d{9,})/), let epoch = Double(m.1) { return Date(timeIntervalSince1970: epoch) }
        if let m = body.firstMatch(of: /"resets_in_seconds"\s*:\s*(\d+)/), let secs = Double(m.1) { return now.addingTimeInterval(secs) }
        return now.addingTimeInterval(3600)
    }

    static func isRateLimit(_ error: InferenceError) -> Bool {
        if case .httpStatus(429, _) = error { return true }
        return false
    }

    // MARK: Tools on demand

    /// Tool definitions for this turn. Built-in tools are always there; a connected service's tools appear once
    /// the task loads them with `find_tools`, calls one of them, or the agent always loads that service. Small
    /// tool sets load whole. An agent with an explicit allowlist sees exactly its list.
    ///
    /// A request never carries more than `maxToolsPerRequest`. Services go in whole: the agent's always-loaded
    /// ones first, then the ones the task loaded, newest first; a service that no longer fits waits until the
    /// task loads it again. When the built-in tools alone are too many, the turn fails here, before the model.
    func turnSpecs(task: TaskRecord, agent: AgentProfile) async throws -> [ToolSpec] {
        var all = await deps.broker.specs(for: agent)
        // Writing code needs a coding project; helpers don't start coding runs.
        if deps.config.coding?.projects.isEmpty ?? true || agent.kind != .persistent {
            all.removeAll { $0.name == "code" }
        }
        let limit = Self.maxToolsPerRequest
        let mcp = all.filter { $0.source.hasPrefix("mcp:") }
        if !agent.toolAllowlist.isEmpty || mcp.count <= Self.loadAllMCPToolsUpTo, all.count <= limit { return all }
        let core = all.count - mcp.count + 1  // built-in and granted tools, and find_tools
        guard core <= limit else {
            throw ToolError.failed("\(agent.name) has \(core - 1) built-in tools; a model request can carry at most \(limit). Give it a shorter tool allowlist.")
        }
        let wanted = (agent.alwaysLoadedServers ?? []).map(\.rawValue).sorted() + activeServers[task.id, default: []]
        var room = limit - core
        var fits: Set<String> = []
        for server in wanted where !fits.contains(server) {
            let count = mcp.filter { $0.source == "mcp:\(server)" }.count
            if count <= room { fits.insert(server); room -= count }
        }
        let visible = all.filter { spec in
            guard spec.source.hasPrefix("mcp:") else { return true }
            return fits.contains(String(spec.source.dropFirst(4)))
        }
        return visible + [Self.findToolsSpec]
    }

    /// Up to this many connected-service tools, everything loads; above it, services load on demand.
    static let loadAllMCPToolsUpTo = 16

    /// The most tools one model request may carry: OpenAI and Azure OpenAI refuse longer lists ("array too
    /// long"), and the other endpoints Pennant talks to accept at least this many.
    static let maxToolsPerRequest = 128

    /// Puts a service at the front of the task's loaded services.
    func markLoaded(_ server: String, task: TaskID) {
        activeServers[task, default: []].removeAll { $0 == server }
        activeServers[task, default: []].insert(server, at: 0)
    }

    static let findToolsSpec = ToolSpec(
        name: "find_tools",
        description: "Load the tools of a connected service (Microsoft 365, Canva, LinkedIn, GitHub…) so you can call them on your next step. Search by what you need (\"send an Outlook email\", \"create a Canva design\") or by service name. Returns the matching tools with a one-line description each.",
        inputSchema: JSONSchema.object([
            "query": JSONSchema.string("What you need to do, or a service name. Empty lists every connected service."),
        ], required: []),
        isConsequential: false,
        needsDesktop: false,
        source: "builtin"
    )

    /// Connected services and their tool counts, for the prompt: what exists even when it is not loaded.
    func connectedServices(agent: AgentProfile, visible: [ToolSpec]) async -> [ContextBuilder.Service] {
        let all = await deps.broker.specs(for: agent).filter { $0.source.hasPrefix("mcp:") }
        let loaded = Set(visible.map(\.source))
        var byServer: [String: (name: String, count: Int)] = [:]
        for spec in all {
            let name = Self.serviceName(of: spec)
            byServer[spec.source, default: (name, 0)].count += 1
        }
        return byServer.map { ContextBuilder.Service(name: $0.value.name, toolCount: $0.value.count, loaded: loaded.contains($0.key)) }
            .sorted { $0.name < $1.name }
    }

    /// "[Microsoft 365] Search…" → "Microsoft 365".
    static func serviceName(of spec: ToolSpec) -> String {
        if spec.description.hasPrefix("["), let close = spec.description.firstIndex(of: "]") {
            return String(spec.description[spec.description.index(after: spec.description.startIndex) ..< close])
        }
        return spec.name.components(separatedBy: "__").first ?? spec.name
    }

    /// Runs `find_tools`: matches services and tools, loads the matching services for this task, and lists them.
    func findTools(query raw: String, task: TaskRecord, agent: AgentProfile) async -> String {
        let all = await deps.broker.specs(for: agent).filter { $0.source.hasPrefix("mcp:") }
        guard !all.isEmpty else { return "No services are connected. Connect them in Pennant's Connections screen." }
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let groups = Dictionary(grouping: all, by: \.source)
        if query.isEmpty {
            let lines = groups.map { source, specs in "- \(Self.serviceName(of: specs[0])): \(specs.count) tools" }.sorted()
            return "Connected services (call find_tools with one of them, or with what you need, to load its tools):\n" + lines.joined(separator: "\n")
        }
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        func score(_ spec: ToolSpec) -> Int {
            let hay = "\(Self.serviceName(of: spec)) \(spec.name) \(spec.description)".lowercased()
            var s = 0
            if hay.contains(query) { s += 5 }
            for w in words where hay.contains(w) { s += 1 }
            if Self.serviceName(of: spec).lowercased().contains(query) { s += 10 }
            return s
        }
        // Rank services by their best tool, load the top few whole (a service's tools work together).
        let scored: [(String, [ToolSpec], Int)] = groups.map { source, specs in (source, specs, specs.map(score).max() ?? 0) }
        let ranked = scored.filter { $0.2 > 0 }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }  // ties by server, so the same query loads the same services
            .prefix(3)
        guard !ranked.isEmpty else {
            let names = groups.values.map { Self.serviceName(of: $0[0]) }.sorted().joined(separator: ", ")
            return "No connected service matches \"\(raw)\". Connected: \(names). Try a service name."
        }
        // The best match goes in last, so it is the newest and the last to give way when a request is full.
        for (source, _, _) in ranked.reversed() { markLoaded(String(source.dropFirst(4)), task: task.id) }
        let fits = Set(((try? await turnSpecs(task: task, agent: agent)) ?? []).map(\.source))
        var out: [String] = []
        for (source, specs, _) in ranked {
            guard fits.contains(source) else {
                out.append("\(Self.serviceName(of: specs[0])) (\(specs.count) tools) is not loaded: with the tools already loaded it would take a request past the model's limit of \(Self.maxToolsPerRequest) tools.")
                continue
            }
            let best = specs.sorted { score($0) > score($1) }
            let lines = best.prefix(25).map { spec -> String in
                let text = spec.description.replacingOccurrences(of: "[\(Self.serviceName(of: spec))] ", with: "")
                return "  - \(spec.name): \(text.prefix(140))"
            }
            out.append("Loaded \(Self.serviceName(of: specs[0])) (\(specs.count) tools):\n" + lines.joined(separator: "\n") + (specs.count > 25 ? "\n  … and \(specs.count - 25) more" : ""))
        }
        return out.joined(separator: "\n\n") + "\n\nThese tools are available from your next step."
    }

    /// Calling a service's tool directly (from memory or a skill) loads that service too.
    func noteToolUse(_ spec: ToolSpec, task: TaskID) {
        guard spec.source.hasPrefix("mcp:") else { return }
        markLoaded(String(spec.source.dropFirst(4)), task: task)
    }

    // MARK: Speed

    /// Tokens per second for a reply: the provider's output count when it reports one (an estimate from the text,
    /// reasoning and tool arguments otherwise) over the time from the first token to the end.
    /// The ledger entry for one finished model call. Counts the provider did not report are estimated.
    static func usageRecord(_ response: InferenceResponse, model: ModelChoice, task: TaskRecord, estimatedInput: () -> Int) -> UsageRecord {
        var input = response.usage.inputTokens, output = response.usage.outputTokens
        var estimated = false
        if input <= 0 { input = estimatedInput(); estimated = true }
        if output <= 0 {
            let args = response.toolCalls.map { String(describing: $0.arguments) }.joined()
            output = TokenEstimator.tokens(forText: response.text + response.reasoning + args)
            estimated = true
        }
        let cached = min(response.usage.cachedInputTokens, input)
        return UsageRecord(agentID: task.agentID, taskID: task.id, conversationID: task.conversationID, profileID: model.profileID, modelLabel: model.label,
                           provider: model.providerID, model: model.modelID, inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                           cost: model.pricing?.cost(input: input, cachedInput: cached, output: output), estimated: estimated)
    }

    static func stats(_ response: InferenceResponse, sentAt: Date, firstTokenAt: Date?, model: String, now: Date = Date()) -> GenerationStats? {
        guard let first = firstTokenAt else { return nil }
        var tokens = response.usage.outputTokens
        var estimated = false
        if tokens <= 0 {
            let args = response.toolCalls.map { String(describing: $0.arguments) }.joined()
            tokens = TokenEstimator.tokens(forText: response.text + response.reasoning + args)
            estimated = true
        }
        return GenerationStats(outputTokens: tokens, seconds: now.timeIntervalSince(first), firstTokenSeconds: first.timeIntervalSince(sentAt), model: model, estimated: estimated)
    }

    // MARK: Stopping at an offer

    /// A final reply that offers or promises the next step ("Want me to…", "I'll now…", "Say the word…") instead
    /// of doing it. Sent back once or twice per task with a note: do it if it is part of the request, ask with
    /// ask_user if it truly needs the user, otherwise finish.
    func offerNudge(task: TaskRecord, reply: String) -> String? {
        guard offerNudges[task.id, default: 0] < 2, Self.endsWithOffer(reply) else { return nil }
        offerNudges[task.id, default: 0] += 1
        return """
        You ended your turn with an offer or a plan instead of the result ("\(Self.lastSentence(reply).prefix(160))"). \
        A reply without tool calls ends the task. If what you offered is part of what the user asked for, do it now with \
        tools; do not ask permission for routine steps. If you are blocked on something only the user can decide or do, \
        call ask_user with one clear question so the task waits for the answer. If it is an optional extra beyond the \
        request, reply with just (done): your answer above stands and is what the user sees. Don't write it again.
        """
    }

    /// The reply that means "my previous answer stands" after an offer nudge.
    static func isDoneMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "().!*`\"'"))
        return t == "done"
    }

    static func endsWithOffer(_ reply: String) -> Bool {
        let tail = String(reply.suffix(400)).lowercased()
        let patterns = [
            "want me to", "would you like me to", "should i ", "shall i ", "do you want me to", "let me know if you",
            "say the word", "just say", "i'll now", "i will now", "i'll start", "i'll proceed", "next, i'll", "next i will",
            "let me know when", "tell me when", "once you", "ready when you are", "if you'd like, i can", "i can also",
        ]
        if patterns.contains(where: { tail.contains($0) }) { return true }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(":")
    }

    static func lastSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { ".!?\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.last ?? trimmed
    }
}
