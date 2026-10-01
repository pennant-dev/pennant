import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// A provider that fails its first requests with the given errors, then answers with text.
final class FlakyProvider: InferenceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [InferenceError]
    private let answer: String
    private(set) var requests: [InferenceRequest] = []

    init(failures: [InferenceError], answer: String = "All done.") {
        self.failures = failures
        self.answer = answer
    }

    var capabilities: InferenceCapabilities { InferenceCapabilities(vision: false, tools: true, contextWindowTokens: 32_000, maxOutputTokens: 2048, model: "flaky", endpoint: "memory") }
    func estimateTokens(_ messages: [ModelMessage], tools: [ToolSpec]) -> Int { TokenEstimator.tokens(for: messages, tools: tools) }
    func healthCheck() async -> Bool { true }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        let failure: InferenceError? = lock.withLock {
            requests.append(request)
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        let answer = self.answer
        return AsyncThrowingStream { continuation in
            if let failure { continuation.finish(throwing: failure); return }
            continuation.yield(.textDelta(answer))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}

/// A stand-in MCP tool with a server-style name and source (or a stand-in built-in tool).
struct FakeServiceTool: Tool {
    let spec: ToolSpec
    init(server: String, serverName: String, name: String, description: String? = nil) {
        let safeServer = serverName.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
        spec = ToolSpec(name: "\(safeServer)__\(name)", description: "[\(serverName)] \(description ?? name.replacingOccurrences(of: "_", with: " "))", inputSchema: JSONSchema.object([:]), isConsequential: false, needsDesktop: false, source: "mcp:\(server)")
    }
    init(builtin name: String) {
        spec = ToolSpec(name: name, description: name, inputSchema: JSONSchema.object([:]), isConsequential: false, needsDesktop: false, source: "builtin")
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult { .text(ToolCallID("x"), name: spec.name, "ok") }
}

final class ModelRoutingTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
        TaskRuntime.rateLimitWaits = [0.01, 0.01, 0.01]
        TaskRuntime.serverErrorWaits = [0.01, 0.01]
        TaskRuntime.rateLimitPause = 0.3
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: paths.root)
        TaskRuntime.rateLimitWaits = [10, 30, 60]
        TaskRuntime.serverErrorWaits = [3, 6]
        TaskRuntime.outageCooldown = 180
        TaskRuntime.rateLimitPause = 120
    }

    private func service(_ provider: any InferenceProvider, configure: (inout HostConfig) -> Void = { _ in }) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        configure(&config)
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    private func agent(_ s: HostService) async throws -> AgentProfile {
        let agents = try await s.store.listAgents(includeRetired: false)
        return try XCTUnwrap(agents.first { $0.kind == .persistent })
    }

    private func wait(_ s: HostService, _ id: TaskID, _ state: TaskState, timeout: TimeInterval = 10) async throws -> TaskRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let t = try await s.store.task(id), t.state == state { return t }
            try await Task.sleep(for: .milliseconds(20))
        }
        let t = try await s.store.task(id)
        XCTFail("task is \(t?.state.rawValue ?? "missing"): \(t?.stateReason ?? "")")
        throw ToolError.timeout
    }

    // MARK: Stopping at an offer

    func testReplyEndingInAnOfferIsSentBackOnce() async throws {
        let provider = ScriptedProvider([
            .init(text: "I checked the inbox and found three client emails. Want me to draft replies?"),
            .init(text: "Drafted replies to all three and saved them in Drafts."),
        ])
        let s = try await service(provider)
        let a = try await agent(s)
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Handle my client emails", attachments: [])
        let task = try await wait(s, taskID, .completed)
        XCTAssertEqual(task.resultSummary?.trimmingCharacters(in: .whitespaces), "Drafted replies to all three and saved them in Drafts.")
        let second = try XCTUnwrap(provider.requests.dropFirst().first)
        XCTAssertTrue(second.messages.map(\.text).joined().contains("You ended your turn with an offer"))
        await s.stop()
    }

    func testOfferDetection() {
        XCTAssertTrue(TaskRuntime.endsWithOffer("Done. Want me to send it?"))
        XCTAssertTrue(TaskRuntime.endsWithOffer("The HUD is recovered. Say the word and I'll run the take."))
        XCTAssertTrue(TaskRuntime.endsWithOffer("Here is the plan:"))
        XCTAssertFalse(TaskRuntime.endsWithOffer("Sent the email to Dana and verified it in Sent Items."))
        XCTAssertEqual(TaskRuntime.lastSentence("First. Then second? Finally third"), "Finally third")
    }

    // MARK: Retry and fallback

    func testRateLimitRetriesTheSameModel() async throws {
        let provider = FlakyProvider(failures: [.httpStatus(429, "slow down"), .httpStatus(429, "slow down")])
        let s = try await service(provider)
        let a = try await agent(s)
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Hi", attachments: [])
        let task = try await wait(s, taskID, .completed)
        XCTAssertEqual(task.resultSummary, "All done.")
        XCTAssertEqual(provider.requests.count, 3)
        await s.stop()
    }

    func testRefusedProfileFallsBackToTheHostModelWithTheAgentsEffort() async throws {
        // The agent's profile points at an endpoint that answers 404 (a missing deployment).
        let tiny = try TinyHTTPServer { _ in .json(["error": ["message": "DeploymentNotFound"]], status: 404) }
        try await tiny.start()
        defer { tiny.stop() }
        var broken = HostConfig.Inference()
        broken.baseURL = tiny.baseURL.absoluteString + "/v1"
        broken.model = "missing-deployment"
        let profile = InferenceProfile(name: "Azure DeepSeek", inference: broken)
        let fallback = FlakyProvider(failures: [], answer: "Finished on the host model.")
        let s = try await service(fallback) { $0.inferenceProfiles = [profile] }
        var a = try await agent(s)
        a.modelProfileID = profile.id
        a.reasoningEffort = "high"
        try await s.store.upsertAgent(a)
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Hi", attachments: [])
        let task = try await wait(s, taskID, .completed)
        XCTAssertEqual(task.resultSummary, "Finished on the host model.")
        XCTAssertEqual(fallback.requests.first?.reasoningEffort, "high")
        let events = try await s.store.events(afterSeq: 0, limit: 2000)
        XCTAssertTrue(events.contains { if case .notice(_, _, let text) = $0.payload { return text.contains("switched from Azure DeepSeek") }; return false })
        await s.stop()
    }

    func testAModelThatKeepsFailingHandsTheTaskToTheFallbackAndComesBackAfterTheCooldown() async throws {
        // The default model answers 503 "no healthy upstream" every time; the fallback profile is healthy.
        let sse = """
        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Finished on the fallback."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]


        """
        let tiny = try TinyHTTPServer { _ in TinyHTTPServer.Response(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(sse.utf8)) }
        try await tiny.start()
        defer { tiny.stop() }
        var healthy = HostConfig.Inference()
        healthy.baseURL = tiny.baseURL.absoluteString + "/v1"
        healthy.model = "spark"
        let spark = InferenceProfile(name: "Spark", inference: healthy)
        let down = FlakyProvider(failures: Array(repeating: .httpStatus(503, "no healthy upstream"), count: 3), answer: "Back on the default.")
        TaskRuntime.outageCooldown = 1
        let s = try await service(down) { $0.inferenceProfiles = [spark]; $0.fallbackProfileIDs = [spark.id] }
        let a = try await agent(s)
        let (_, _, first) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Hi", attachments: [])
        let task = try await wait(s, first, .completed)
        XCTAssertEqual(task.resultSummary, "Finished on the fallback.", "the task moved on instead of pausing")
        XCTAssertEqual(down.requests.count, 3, "three tries on the failing model before moving on")
        let events = try await s.store.events(afterSeq: 0, limit: 2000)
        XCTAssertTrue(events.contains { if case .notice(_, _, let text) = $0.payload { return text.contains("isn't answering") }; return false })
        // Once the cooldown ends, work goes back to the default model.
        try await Task.sleep(for: .seconds(1.2))
        let (_, _, second) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Again", attachments: [])
        let again = try await wait(s, second, .completed)
        XCTAssertEqual(again.resultSummary, "Back on the default.")
        await s.stop()
    }

    func testARateLimitWithNowhereElseToGoPausesAndResumesByItself() async throws {
        // Four 429s: the first try and three retries; nothing to fall back to. Then the provider recovers.
        let provider = FlakyProvider(failures: Array(repeating: .httpStatus(429, "RateLimitReached"), count: 4), answer: "Done after the wait.")
        let s = try await service(provider)
        let a = try await agent(s)
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Hi", attachments: [])
        let paused = try await wait(s, taskID, .paused)
        XCTAssertTrue(paused.stateReason.contains("Rate limited"), paused.stateReason)
        let done = try await wait(s, taskID, .completed)
        XCTAssertEqual(done.resultSummary, "Done after the wait.")
        await s.stop()
    }

    func testNonRefusalErrorsStillFail() {
        XCTAssertTrue(TaskRuntime.shouldFallBack(.httpStatus(404, "")))
        XCTAssertTrue(TaskRuntime.shouldFallBack(.httpStatus(403, "")))
        XCTAssertTrue(TaskRuntime.shouldFallBack(.httpStatus(429, "")))
        XCTAssertFalse(TaskRuntime.shouldFallBack(.httpStatus(500, "")))
        XCTAssertFalse(TaskRuntime.shouldFallBack(.unreachable("down")))
    }

    // MARK: Tools on demand

    func testServiceToolsLoadWhenFound() async throws {
        let find = ToolCall(id: ToolCallID("f1"), name: "find_tools", arguments: ["query": "canva design"])
        let provider = ScriptedProvider([.init(toolCalls: [find]), .init(text: "Loaded Canva.")])
        let s = try await service(provider)
        var canva: [any Tool] = (0 ..< 20).map { FakeServiceTool(server: "srv-canva", serverName: "Canva", name: "design_tool_\($0)") }
        canva.append(FakeServiceTool(server: "srv-canva", serverName: "Canva", name: "create_design"))
        await s.broker.registerMCPTools(canva, server: MCPServerID("srv-canva"))
        await s.broker.registerMCPTools([FakeServiceTool(server: "srv-mail", serverName: "Mail", name: "send_mail")], server: MCPServerID("srv-mail"))
        let a = try await agent(s)
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Make a Canva design", attachments: [])
        _ = try await wait(s, taskID, .completed)
        let first = try XCTUnwrap(provider.requests.first)
        XCTAssertFalse(first.tools.contains { $0.source.hasPrefix("mcp:") }, "service tools start unloaded")
        XCTAssertTrue(first.tools.contains { $0.name == "find_tools" })
        let prompt = first.messages.first?.text ?? ""
        XCTAssertTrue(prompt.contains("Canva: 21 tools (load with find_tools)"))
        let second = try XCTUnwrap(provider.requests.dropFirst().first)
        XCTAssertEqual(second.tools.filter { $0.source == "mcp:srv-canva" }.count, 21)
        XCTAssertFalse(second.tools.contains { $0.source == "mcp:srv-mail" }, "only the matching service loads")
        await s.stop()
    }

    func testAlwaysLoadedServersAndSmallSetsLoadWhole() async throws {
        let provider = ScriptedProvider([.init(text: "ok")])
        let s = try await service(provider)
        await s.broker.registerMCPTools((0 ..< 20).map { FakeServiceTool(server: "srv-a", serverName: "Alpha", name: "t\($0)") }, server: MCPServerID("srv-a"))
        var a = try await agent(s)
        a.alwaysLoadedServers = [MCPServerID("srv-a")]
        try await s.store.upsertAgent(a)
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Hi", attachments: [])
        _ = try await wait(s, taskID, .completed)
        XCTAssertEqual(provider.requests.first?.tools.filter { $0.source == "mcp:srv-a" }.count, 20)
        await s.stop()
    }

    func testLoadingMicrosoft365KeepsTheRequestWithinTheModelsToolLimit() async throws {
        // An ops agent that always loads its company's MCP server asked find_tools for Teams; Microsoft 365 loaded with
        // two services that matched loosely, and the next request carried 137 tools where the model takes 128.
        let query = "Microsoft 365 Teams list chats and chat members, list teams channels and channel members, send chat message"
        let find = ToolCall(id: ToolCallID("f1"), name: "find_tools", arguments: ["query": .string(query)])
        let provider = ScriptedProvider([.init(toolCalls: [find]), .init(text: "Sent.")])
        let s = try await service(provider)
        var a = try await agent(s)
        a.alwaysLoadedServers = [MCPServerID("srv-company")]
        try await s.store.upsertAgent(a)
        let builtins = await s.broker.specs(for: a).count
        let m365: [any Tool] = MicrosoftGraphConnector().tools.map { FakeServiceTool(server: "srv-m365", serverName: "Microsoft 365", name: $0.name, description: $0.description) }
        XCTAssertEqual(m365.count, 20, "Microsoft 365's tools (people_lookup joined on Sep 26)")
        let files = 14, canva = 137 - (builtins + 1 + 15 + m365.count + files)
        XCTAssertGreaterThan(canva, 0, "\(builtins) built-in tools leave no room to rebuild the 137-tool case")
        await s.broker.registerMCPTools((0 ..< 15).map { FakeServiceTool(server: "srv-company", serverName: "Company MCP", name: "deployment_\($0)") }, server: MCPServerID("srv-company"))
        await s.broker.registerMCPTools(m365, server: MCPServerID("srv-m365"))
        await s.broker.registerMCPTools((0 ..< canva).map { FakeServiceTool(server: "srv-canva", serverName: "Canva", name: "list_designs_\($0)") }, server: MCPServerID("srv-canva"))
        await s.broker.registerMCPTools((0 ..< files).map { FakeServiceTool(server: "srv-files", serverName: "Filesystem", name: "list_directory_\($0)") }, server: MCPServerID("srv-files"))

        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Message Dana on Teams", attachments: [])
        _ = try await wait(s, taskID, .completed)
        for request in provider.requests { XCTAssertLessThanOrEqual(request.tools.count, TaskRuntime.maxToolsPerRequest) }
        let after = try XCTUnwrap(provider.requests.dropFirst().first).tools
        XCTAssertTrue(after.contains { $0.name == "microsoft_365__teams_message_person" }, "the Teams tool the task asked for stays")
        XCTAssertEqual(after.filter { $0.source == "mcp:srv-m365" }.count, m365.count)
        XCTAssertEqual(after.filter { $0.source == "mcp:srv-company" }.count, 15, "the agent's always-loaded service stays")
        XCTAssertFalse(after.contains { $0.source == "mcp:srv-files" }, "the weakest match gives way")
        let found = try XCTUnwrap(provider.requests.dropFirst().first).messages.map(\.text).joined()
        XCTAssertTrue(found.contains("Filesystem (14 tools) is not loaded"), "find_tools says what did not fit")
        await s.stop()
    }

    func testTooManyBuiltInToolsFailBeforeTheModelIsCalled() async throws {
        let provider = ScriptedProvider([.init(text: "never sent")])
        let s = try await service(provider)
        let a = try await agent(s)
        // Count what the agent is offered (a lone agent without coding sees no ask_agent, send_to_agent or code), then
        // go one past the limit.
        let probe = TaskRecord(agentID: a.id, conversationID: ConversationID(), title: "t", objective: "t", completionCriteria: "", budget: HostConfig().defaultBudget)
        let offered = try await s.runtime.turnSpecs(task: probe, agent: a).count
        await s.broker.register((0 ..< TaskRuntime.maxToolsPerRequest - offered + 1).map { FakeServiceTool(builtin: "extra_\($0)") })
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Hi", attachments: [])
        let task = try await wait(s, taskID, .failed)
        XCTAssertTrue(task.stateReason.contains("at most 128"), task.stateReason)
        XCTAssertFalse(provider.requests.contains { !$0.tools.isEmpty }, "no request went to the model")
        await s.stop()
    }

    // MARK: Request bodies

    func testEffortReachesBothProviderBodies() {
        var config = HostConfig.Inference()
        config.model = "gpt-5.6-sol"
        let request = InferenceRequest(messages: [.user("hi")], reasoningEffort: "high")
        guard case .object(let chat) = ChatGPTProvider.requestBody(for: request, config: config),
              case .object(let reasoning)? = chat["reasoning"] else { return XCTFail("no reasoning object") }
        XCTAssertEqual(reasoning["effort"], .string("high"))
        guard case .object(let compat) = OpenAICompatibleProvider.requestBody(for: request, config: config) else { return XCTFail("no body") }
        XCTAssertEqual(compat["reasoning_effort"], .string("high"))
        XCTAssertNil(compat["temperature"], "reasoning models reject temperature")
        guard case .object(let plain) = OpenAICompatibleProvider.requestBody(for: InferenceRequest(messages: [.user("hi")]), config: config) else { return XCTFail("no body") }
        XCTAssertNil(plain["reasoning_effort"])
        XCTAssertNotNil(plain["temperature"])
    }

    // MARK: Speed

    func testRepliesCarryGenerationStats() async throws {
        let provider = ScriptedProvider([.init(text: "Here is the answer.")])
        let s = try await service(provider)
        let a = try await agent(s)
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Hi", attachments: [])
        _ = try await wait(s, taskID, .completed)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 10)
        let reply = try XCTUnwrap(messages.last { $0.role == .assistant })
        let stats = try XCTUnwrap(reply.stats)
        XCTAssertEqual(stats.outputTokens, 20, "the provider's reported count wins")
        XCTAssertFalse(stats.estimated)
        XCTAssertNotNil(stats.firstTokenSeconds)
        await s.stop()
    }

    func testStatsEstimateWhenTheProviderReportsNoUsage() throws {
        let start = Date(timeIntervalSince1970: 100)
        var response = InferenceResponse()
        response.text = String(repeating: "word ", count: 200)
        let stats = try XCTUnwrap(TaskRuntime.stats(response, sentAt: start, firstTokenAt: start.addingTimeInterval(0.5), model: "m", now: start.addingTimeInterval(2.5)))
        XCTAssertTrue(stats.estimated)
        XCTAssertEqual(stats.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(stats.firstTokenSeconds ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(stats.tokensPerSecond ?? 0, Double(stats.outputTokens) / 2, accuracy: 0.001)
        XCTAssertNil(TaskRuntime.stats(response, sentAt: start, firstTokenAt: nil, model: "m"), "no tokens, no stats")
    }
}


final class ReasoningEffortFitTests: XCTestCase {
    func testPicksNearestSupportedEffortFromTheError() {
        let body = #"{"error":{"message":"Unexpected reasoning effort high. Supported types are xhigh (default), medium, and low.","type":"BadRequestError"}}"#
        XCTAssertTrue(ReasoningEffortFit.isEffortError(body))
        XCTAssertEqual(ReasoningEffortFit.supported(in: body), ["low", "medium", "xhigh"])
        XCTAssertEqual(ReasoningEffortFit.nearest(to: "high", among: ["low", "medium", "xhigh"]), "xhigh")
        XCTAssertEqual(ReasoningEffortFit.nearest(to: "minimal", among: ["low", "medium", "xhigh"]), "low")
        XCTAssertNil(ReasoningEffortFit.nearest(to: "high", among: []))
        ReasoningEffortFit.remember("high", as: "xhigh", key: "k")
        XCTAssertEqual(ReasoningEffortFit.substitute(for: "high", key: "k"), .some("xhigh"))
        XCTAssertTrue(ReasoningEffortFit.substitute(for: "low", key: "k") == nil)
    }
}

final class QuotaExhaustionTests: XCTestCase {
    func testUsedUpQuotaIsRecognisedWithItsResetTime() {
        let body = #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"plus","resets_at":1790139627,"resets_in_seconds":4000}}"#
        XCTAssertEqual(TaskRuntime.quotaExhausted(.httpStatus(429, body)), Date(timeIntervalSince1970: 1_790_139_627))
        let now = Date()
        let noEpoch = #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota","resets_in_seconds":600}}"#
        XCTAssertEqual(TaskRuntime.quotaExhausted(.httpStatus(429, noEpoch), now: now), now.addingTimeInterval(600))
        // A plain burst limit is not exhaustion: that one is worth a short wait and retry.
        XCTAssertNil(TaskRuntime.quotaExhausted(.httpStatus(429, #"{"error":{"message":"Rate limit reached for requests"}}"#)))
        XCTAssertNil(TaskRuntime.quotaExhausted(.httpStatus(400, body)))
    }
}

final class UsageLedgerTests: XCTestCase {
    func testCostUsesCachedPriceAndSubscriptionsCostNothing() {
        let p = ModelPricing(inputPerMillion: 2.0, cachedInputPerMillion: 0.5, outputPerMillion: 8.0)
        // 1M input of which 400k cached, 100k output: 600k*2 + 400k*0.5 + 100k*8 = 1.2 + 0.2 + 0.8
        XCTAssertEqual(p.cost(input: 1_000_000, cachedInput: 400_000, output: 100_000)!, 2.2, accuracy: 1e-9)
        XCTAssertNil(ModelPricing(inputPerMillion: 1).cost(input: 10, cachedInput: 0, output: 10), "unknown output price → unknown cost")
        XCTAssertEqual(ModelPricing(included: true).cost(input: 5, cachedInput: 0, output: 5), 0)
        let chatgpt = InferenceProfile(name: "Sol", inference: HostConfig.Inference(model: "gpt-5.6-sol", provider: HostConfig.Inference.chatGPTProvider))
        XCTAssertEqual(chatgpt.effectivePricing?.included, true)
        let azure = InferenceProfile(name: "Sol · Azure", inference: HostConfig.Inference(model: "gpt-5.6-sol", provider: HostConfig.Inference.azureProvider))
        XCTAssertNil(azure.effectivePricing, "paid models have no made-up prices")
    }

    func testEachCallBecomesARecordWithEstimatesWhenUsageIsMissing() {
        let task = TaskRecord(agentID: AgentID(), conversationID: ConversationID(), title: "Make a video", objective: "Make a video")
        var model = TaskRuntime.ModelChoice(provider: ScriptedProvider([]), label: "Sol · Azure", maxOutputTokens: 1000, reasoningEffort: nil)
        model.profileID = "p1"; model.providerID = HostConfig.Inference.azureProvider; model.modelID = "gpt-5.6-sol"
        model.pricing = ModelPricing(inputPerMillion: 1, cachedInputPerMillion: 0.1, outputPerMillion: 10)
        var reported = InferenceResponse(text: "ok")
        reported.usage = TokenUsage(inputTokens: 1000, outputTokens: 200, cachedInputTokens: 800)
        let r = TaskRuntime.usageRecord(reported, model: model, task: task) { 999_999 }
        XCTAssertEqual(r.inputTokens, 1000)
        XCTAssertEqual(r.cachedInputTokens, 800)
        XCTAssertFalse(r.estimated)
        let expected: Double = (200.0 + 80.0 + 2000.0) / 1_000_000
        XCTAssertEqual(r.cost ?? -1, expected, accuracy: 1e-12)
        XCTAssertEqual(r.taskID, task.id)
        XCTAssertEqual(r.profileID, "p1")
        let silent = TaskRuntime.usageRecord(InferenceResponse(text: "hello there"), model: model, task: task) { 1234 }
        XCTAssertTrue(silent.estimated)
        XCTAssertEqual(silent.inputTokens, 1234)
        XCTAssertGreaterThan(silent.outputTokens, 0)
    }
}
