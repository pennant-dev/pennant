import PennantCore
import CryptoKit
import Foundation

/// Inference through a ChatGPT account: the Responses endpoint of the ChatGPT backend that Codex clients use
/// (`chatgpt.com/backend-api/codex/responses`), authenticated with the tokens `ChatGPTAuthManager` holds. Streams
/// the Responses SSE events into `InferenceChunk`s, maps function calls, sends images as data URIs, refreshes once
/// on a 401, and replays the encrypted reasoning items of a tool-calling turn on the follow-up request the way the
/// Codex CLI and Hermes do (`include: ["reasoning.encrypted_content"]` with `store: false`).
public final class ChatGPTProvider: InferenceProvider, Sendable {
    public let config: HostConfig.Inference
    public let capabilities: InferenceCapabilities
    let auth: ChatGPTAuthManager
    let session: URLSession
    /// Sent as the `session_id` header and folded into the prompt cache key; one per provider instance.
    let sessionID: String
    let replay: ReasoningReplayCache

    /// How the host identifies itself to the backend; OpenAI asks third-party clients to say who they are.
    public static let originator = "pennant"
    static let defaultInstructions = "You are Pennant, a personal assistant on this Mac."
    static let reasoningEffort = "medium"

    public init(config: HostConfig.Inference, auth: ChatGPTAuthManager, session: URLSession = .shared) {
        self.config = config
        self.auth = auth
        self.session = session
        self.sessionID = UUID().uuidString.lowercased()
        self.replay = ReasoningReplayCache()
        let known = ChatGPTAuthManager.model(withID: config.model)
        self.capabilities = InferenceCapabilities(
            vision: config.supportsVision && (known?.supportsVision ?? true),
            tools: true,
            contextWindowTokens: known?.contextWindowTokens ?? config.contextWindowTokens,
            maxOutputTokens: config.maxOutputTokens,
            model: config.model,
            endpoint: "chatgpt"
        )
    }

    // MARK: - InferenceProvider

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<InferenceChunk, Error>.makeStream()
        let task = Task {
            do {
                try await run(request: request, continuation: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch let error as URLError where error.code == .cancelled {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch {
                log.warn("Request failed: \(error)", category: "chatgpt")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func estimateTokens(_ messages: [ModelMessage], tools: [ToolSpec]) -> Int {
        TokenEstimator.tokens(for: messages, tools: tools)
    }

    /// True when a request could be made: a live access token, or a refresh token that has not been refused.
    public func healthCheck() async -> Bool {
        await auth.isUsable()
    }

    // MARK: - Request building

    /// Builds the Responses body. `replayReasoning` adds `include: ["reasoning.encrypted_content"]` and re-sends the
    /// reasoning items cached for the assistant's tool calls; off after the backend refuses them. Exposed for tests.
    public static func requestBody(for request: InferenceRequest, config: HostConfig.Inference, replay: ReasoningReplayCache? = nil, replayReasoning: Bool = true, cacheScope: String = "") -> JSONValue {
        var instructions = request.messages.filter { $0.role == .system }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if instructions.isEmpty { instructions = defaultInstructions }
        if request.jsonMode { instructions += "\n\nReply with a single JSON object and nothing else." }

        let useTools = !request.disableTools && !request.tools.isEmpty
        let tools: [JSONValue] = useTools ? request.tools.map { tool in
            .object([
                "type": "function",
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
                "strict": .bool(false),
            ])
        } : []

        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "instructions": .string(instructions),
            "input": .array(encodeInput(request.messages, config: config, replay: replayReasoning ? replay : nil)),
            "store": .bool(false),
            "stream": .bool(true),
            "reasoning": .object(["effort": .string(request.reasoningEffort ?? config.reasoningEffort ?? reasoningEffort), "summary": "auto"]),
            "include": .array(replayReasoning ? ["reasoning.encrypted_content"] : []),
            "prompt_cache_key": .string(promptCacheKey(scope: cacheScope, instructions: instructions, tools: tools)),
        ]
        if useTools {
            body["tools"] = .array(tools)
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = .bool(true)
        }
        return .object(body)
    }

    /// Chat history as Responses input items. System messages become `instructions`; user turns carry typed parts
    /// (the ChatGPT backend rejects plain-string content); assistant turns become an `output_text` message plus one
    /// `function_call` per call, preceded by the turn's cached reasoning items; tool results become
    /// `function_call_output`, with any images delivered in a follow-up user turn.
    static func encodeInput(_ messages: [ModelMessage], config: HostConfig.Inference, replay: ReasoningReplayCache?) -> [JSONValue] {
        var items: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                let parts = encodeParts(message.parts, config: config)
                guard !parts.isEmpty else { continue }
                items.append(.object(["type": "message", "role": "user", "content": .array(parts)]))
            case .assistant:
                let callIDs = message.toolCalls.map(\.id.rawValue)
                if let replay, !callIDs.isEmpty, let reasoning = replay.items(for: callIDs) {
                    items.append(contentsOf: reasoning)
                }
                let text = message.text
                if !text.isEmpty {
                    items.append(.object(["type": "message", "role": "assistant", "content": .array([.object(["type": "output_text", "text": .string(text)])])]))
                }
                for call in message.toolCalls {
                    items.append(.object([
                        "type": "function_call",
                        "call_id": .string(call.id.rawValue),
                        "name": .string(call.name),
                        "arguments": .string(call.arguments.compactText),
                    ]))
                }
            case .tool:
                let callID = message.toolCallID?.rawValue ?? ""
                guard !callID.isEmpty else { continue }
                let images = message.parts.filter { if case .image = $0 { return true } else { return false } }
                var text = message.text
                if text.isEmpty { text = images.isEmpty ? "(no output)" : "(image result)" }
                if !images.isEmpty, !config.supportsVision {
                    text += "\n" + images.map { part -> String in
                        if case .image(let data, _) = part { return "[image omitted: \(data.count) bytes]" }
                        return ""
                    }.joined(separator: "\n")
                }
                items.append(.object(["type": "function_call_output", "call_id": .string(callID), "output": .string(text)]))
                if !images.isEmpty, config.supportsVision {
                    // `input_image` is only accepted on user messages; hand the result images over in a user turn.
                    var parts: [ModelContent] = [.text("Result image for tool call \(callID)")]
                    parts.append(contentsOf: images)
                    items.append(.object(["type": "message", "role": "user", "content": .array(encodeParts(parts, config: config))]))
                }
            }
        }
        return items
    }

    static func encodeParts(_ parts: [ModelContent], config: HostConfig.Inference) -> [JSONValue] {
        parts.map { part in
            switch part {
            case .text(let t):
                return .object(["type": "input_text", "text": .string(t)])
            case .image(let data, let mimeType):
                if config.supportsVision {
                    return .object(["type": "input_image", "image_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")])
                }
                return .object(["type": "input_text", "text": .string("[image omitted: \(data.count) bytes]")])
            }
        }
    }

    /// `pck_<sha256[:24]>` of the scope, instructions, and name-sorted tools: a routing hint for the backend's prompt
    /// cache, the same derivation Hermes uses.
    static func promptCacheKey(scope: String, instructions: String, tools: [JSONValue]) -> String {
        let sorted = tools.sorted { ($0["name"]?.stringValue ?? "") < ($1["name"]?.stringValue ?? "") }.map(\.compactText).joined(separator: ",")
        let content = "\(scope)\u{0}\(instructions)\u{0}\(sorted)"
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pck_" + digest.prefix(24)
    }

    // MARK: - Streaming

    private func run(request: InferenceRequest, continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation) async throws {
        var credential: (token: String, accountID: String)
        do { credential = try await auth.accessToken() } catch let error as ChatGPTAuthError { throw InferenceError.unreachable(error.description) }
        let residency = await auth.residency()
        var refreshed = false
        var replayReasoning = true

        while true {
            var urlRequest = URLRequest(url: auth.endpoints.responses)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = config.requestTimeout > 0 ? config.requestTimeout : 300
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
            if !credential.accountID.isEmpty { urlRequest.setValue(credential.accountID, forHTTPHeaderField: "chatgpt-account-id") }
            urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            urlRequest.setValue(Self.originator, forHTTPHeaderField: "originator")
            urlRequest.setValue(sessionID, forHTTPHeaderField: "session_id")
            urlRequest.setValue("pennant-host/\(PennantVersion.string)", forHTTPHeaderField: "User-Agent")
            if let residency { urlRequest.setValue(residency, forHTTPHeaderField: "x-openai-internal-codex-residency") }
            urlRequest.httpBody = try JSONCodec.encode(Self.requestBody(for: request, config: config, replay: replay, replayReasoning: replayReasoning, cacheScope: sessionID))

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: urlRequest)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                throw InferenceError.unreachable(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else { throw InferenceError.malformedResponse("Not an HTTP response") }
            if !(200 ..< 300).contains(http.statusCode) {
                let text = try await ResponsesStream.errorText(bytes)
                if http.statusCode == 401, !refreshed {
                    refreshed = true
                    log.info("ChatGPT backend answered 401; refreshing the session and retrying once", category: "chatgpt")
                    do { credential = try await auth.refreshAccessToken(rejected: credential.token) } catch let error as ChatGPTAuthError { throw InferenceError.httpStatus(401, error.description) }
                    continue
                }
                if http.statusCode == 400, replayReasoning, text.lowercased().contains("encrypted_content") {
                    // The backend refuses the replayed reasoning (a model switch, or blobs it no longer accepts).
                    replayReasoning = false
                    replay.clear()
                    log.warn("ChatGPT backend refused replayed reasoning; retrying without it", category: "chatgpt")
                    continue
                }
                if OpenAICompatibleProvider.looksLikeContextOverflow(text) {
                    let estimate = TokenEstimator.tokens(for: request.messages, tools: request.tools)
                    throw InferenceError.contextTooLarge(estimatedTokens: estimate, limit: OpenAICompatibleProvider.contextLimit(from: text) ?? capabilities.contextWindowTokens)
                }
                throw InferenceError.httpStatus(http.statusCode, text)
            }

            let assembler = try await ResponsesStream.read(bytes, into: continuation)
            if replayReasoning, !assembler.reasoningItems.isEmpty, !assembler.emittedCallIDs.isEmpty {
                replay.store(callIDs: assembler.emittedCallIDs, items: assembler.reasoningItems)
            }
            return
        }
    }
}

// MARK: - Reading a Responses stream

/// The SSE stream of a Responses API request, as chunks: shared by every provider that speaks the Responses API.
enum ResponsesStream {
    /// Reads the stream to its end (or its terminal event), yielding chunks as they arrive. Returns the assembler, whose
    /// reasoning items a tool-calling turn replays on its follow-up.
    static func read(_ bytes: URLSession.AsyncBytes, into continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation) async throws -> ResponsesEventAssembler {
        var assembler = ResponsesEventAssembler()
        var parser = SSEParser()
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(4096)

        func process(_ payloads: [String]) throws -> Bool {
            for payload in payloads {
                if payload == SSEParser.doneMarker { return true }
                for chunk in try assembler.handle(payload: payload) { continuation.yield(chunk) }
                if assembler.terminated { return true }
            }
            return false
        }

        var done = false
        for try await byte in bytes {
            lineBuffer.append(byte)
            if byte == 0x0A {
                let payloads = parser.feed(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                if try process(payloads) { done = true; break }
            }
            try Task.checkCancellation()
        }
        if !done, !lineBuffer.isEmpty {
            var payloads = parser.feed(lineBuffer)
            payloads.append(contentsOf: parser.flush())
            _ = try process(payloads)
        }
        for chunk in try assembler.end() { continuation.yield(chunk) }
        return assembler
    }

    /// The body of a refused request (at most 64 KB), for the error.
    static func errorText(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > 65_536 { break }
        }
        return String(decoding: body, as: UTF8.self)
    }
}

// MARK: - Reasoning replay

/// The encrypted reasoning items of tool-calling turns, keyed by the call ids they produced, so the follow-up
/// request can put them back in front of the `function_call` items. Bounded; cleared when the backend refuses them.
public final class ReasoningReplayCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byCallID: [String: [JSONValue]] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 256) { self.capacity = capacity }

    public func store(callIDs: [String], items: [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        for id in callIDs {
            if byCallID[id] == nil { order.append(id) }
            byCallID[id] = items
        }
        while order.count > capacity {
            byCallID[order.removeFirst()] = nil
        }
    }

    /// The items of the turn that produced any of these calls.
    public func items(for callIDs: [String]) -> [JSONValue]? {
        lock.lock(); defer { lock.unlock() }
        for id in callIDs { if let items = byCallID[id] { return items } }
        return nil
    }

    public func clear() {
        lock.lock(); byCallID.removeAll(); order.removeAll(); lock.unlock()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return order.count }
}

// MARK: - Event assembly

/// Turns Responses SSE events into `InferenceChunk`s: text and reasoning deltas as they arrive, a function call
/// once its item is done (or settled at the terminal event when a backend omits the done event), usage and the
/// finish reason from `response.completed`/`response.incomplete`. Commentary and analysis phases of a message
/// go to the reasoning channel. Reasoning items with `encrypted_content` are collected for replay.
struct ResponsesEventAssembler: Sendable {
    private struct PendingCall {
        var callID: String?
        var name: String
        var arguments: String
        var emitted = false
    }

    private var calls: [String: PendingCall] = [:]
    private var order: [String] = []
    private var messagePhases: [Int: String] = [:]
    private var streamedText: [Int: Int] = [:]
    private var lastSummaryIndex: Int?
    private var textSeen = false
    private(set) var reasoningItems: [JSONValue] = []
    private(set) var emittedCallIDs: [String] = []
    private(set) var terminated = false

    init() {}

    mutating func handle(payload: String) throws -> [InferenceChunk] {
        let json: JSONValue
        do {
            json = try JSONValue.parse(payload)
        } catch {
            throw InferenceError.malformedResponse("Unparseable SSE payload: \(payload.prefix(200))")
        }
        let type = json["type"]?.stringValue ?? ""
        switch type {
        case "error":
            throw Self.error(from: json, status: json["status"]?.intValue)
        case "response.output_item.added":
            itemAdded(json)
            return []
        case "response.output_item.done":
            return itemDone(json)
        case "response.output_text.delta", "response.refusal.delta":
            return textDelta(json)
        case "response.function_call_arguments.delta":
            if let id = json["item_id"]?.stringValue, var call = calls[id], let delta = json["delta"]?.stringValue {
                call.arguments += delta
                calls[id] = call
            }
            return []
        case "response.function_call_arguments.done":
            if let id = json["item_id"]?.stringValue, var call = calls[id], let arguments = json["arguments"]?.stringValue {
                call.arguments = arguments
                calls[id] = call
            }
            return []
        case "response.completed", "response.incomplete", "response.failed":
            return try terminal(json, type: type)
        default:
            if type.contains("reasoning"), type.hasSuffix(".delta"), let delta = json["delta"]?.stringValue, !delta.isEmpty {
                var text = delta
                if let index = json["summary_index"]?.intValue {
                    if let last = lastSummaryIndex, last != index { text = "\n\n" + text }
                    lastSummaryIndex = index
                }
                return [.reasoningDelta(text)]
            }
            return []
        }
    }

    /// Settles calls that were announced but never confirmed and closes the stream when no terminal event came.
    mutating func end() throws -> [InferenceChunk] {
        guard !terminated else { return [] }
        var out = settlePending()
        if !textSeen, emittedCallIDs.isEmpty {
            throw InferenceError.malformedResponse("the stream ended before any output")
        }
        out.append(.finished(emittedCallIDs.isEmpty ? .stop : .toolCalls))
        terminated = true
        return out
    }

    private mutating func itemAdded(_ json: JSONValue) {
        guard let item = json["item"] else { return }
        let itemType = item["type"]?.stringValue ?? ""
        let index = json["output_index"]?.intValue ?? item["output_index"]?.intValue
        if itemType == "function_call" {
            let id = item["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "index-\(index ?? order.count)"
            if calls[id] == nil { order.append(id) }
            calls[id] = PendingCall(callID: item["call_id"]?.stringValue, name: item["name"]?.stringValue ?? "", arguments: item["arguments"]?.stringValue ?? "")
        } else if itemType == "message", let index {
            messagePhases[index] = item["phase"]?.stringValue?.lowercased() ?? ""
        }
    }

    private mutating func textDelta(_ json: JSONValue) -> [InferenceChunk] {
        guard let delta = json["delta"]?.stringValue, !delta.isEmpty else { return [] }
        let index = json["output_index"]?.intValue ?? -1
        streamedText[index, default: 0] += delta.count
        if Self.isReasoningPhase(messagePhases[index]) { return [.reasoningDelta(delta)] }
        textSeen = true
        return [.textDelta(delta)]
    }

    private mutating func itemDone(_ json: JSONValue) -> [InferenceChunk] {
        guard let item = json["item"] else { return [] }
        let itemType = item["type"]?.stringValue ?? ""
        let index = json["output_index"]?.intValue ?? item["output_index"]?.intValue
        switch itemType {
        case "function_call":
            let id = item["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "index-\(index ?? order.count)"
            var call = calls[id] ?? PendingCall(callID: nil, name: "", arguments: "")
            if calls[id] == nil { order.append(id) }
            if let callID = item["call_id"]?.stringValue, !callID.isEmpty { call.callID = callID }
            if let name = item["name"]?.stringValue, !name.isEmpty { call.name = name }
            if let arguments = item["arguments"]?.stringValue { call.arguments = arguments }
            calls[id] = call
            return emit(id)
        case "reasoning":
            if let encrypted = item["encrypted_content"]?.stringValue, !encrypted.isEmpty {
                let summary: [JSONValue] = (item["summary"]?.arrayValue ?? []).compactMap { part in
                    guard let text = part["text"]?.stringValue else { return nil }
                    return .object(["type": "summary_text", "text": .string(text)])
                }
                reasoningItems.append(.object(["type": "reasoning", "summary": .array(summary), "encrypted_content": .string(encrypted)]))
            }
            return []
        case "message":
            // Backends that skip deltas deliver the text here; anything already streamed is not repeated.
            guard let index, (streamedText[index] ?? 0) == 0 else { return [] }
            let text = (item["content"]?.arrayValue ?? []).compactMap { part -> String? in
                switch part["type"]?.stringValue {
                case "output_text": return part["text"]?.stringValue
                case "refusal": return part["refusal"]?.stringValue
                default: return nil
                }
            }.joined()
            guard !text.isEmpty else { return [] }
            streamedText[index] = text.count
            if Self.isReasoningPhase(item["phase"]?.stringValue?.lowercased() ?? messagePhases[index]) { return [.reasoningDelta(text)] }
            textSeen = true
            return [.textDelta(text)]
        default:
            return []
        }
    }

    private mutating func terminal(_ json: JSONValue, type: String) throws -> [InferenceChunk] {
        let response = json["response"] ?? .null
        if type == "response.failed" {
            throw Self.error(from: response["error"] ?? json["error"] ?? .null, status: nil)
        }
        var out: [InferenceChunk] = []
        if let usage = response["usage"], let input = usage["input_tokens"]?.intValue {
            out.append(.usage(TokenUsage(inputTokens: input, outputTokens: usage["output_tokens"]?.intValue ?? 0, cachedInputTokens: usage["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0)))
        }
        out.append(contentsOf: settlePending())
        let reason: FinishReason
        let incompleteReason = response["incomplete_details"]?["reason"]?.stringValue ?? ""
        if type == "response.incomplete", incompleteReason == "max_output_tokens" {
            reason = .length
        } else if type == "response.incomplete", incompleteReason == "content_filter" {
            reason = .contentFilter
        } else {
            reason = emittedCallIDs.isEmpty ? .stop : .toolCalls
        }
        out.append(.finished(reason))
        terminated = true
        return out
    }

    private mutating func settlePending() -> [InferenceChunk] {
        var out: [InferenceChunk] = []
        for id in order { out.append(contentsOf: emit(id)) }
        return out
    }

    private mutating func emit(_ id: String) -> [InferenceChunk] {
        guard var call = calls[id], !call.emitted, !call.name.isEmpty else { return [] }
        call.emitted = true
        calls[id] = call
        let callID = call.callID.flatMap { $0.isEmpty ? nil : $0 } ?? "call_" + UUID().uuidString.lowercased().prefix(12)
        emittedCallIDs.append(callID)
        return [.toolCall(ToolCall(id: ToolCallID(callID), name: call.name, arguments: ChunkAssembler.parseArguments(call.arguments)))]
    }

    private static func isReasoningPhase(_ phase: String?) -> Bool {
        phase == "commentary" || phase == "analysis"
    }

    /// An `error` event (`{type: "error", code, message}` or nested under `error`) or a failed response's `error`.
    static func error(from json: JSONValue, status: Int?) -> InferenceError {
        let nested = json["error"]
        let message = json["message"]?.stringValue ?? nested?["message"]?.stringValue ?? json.stringValue ?? "the backend reported an error"
        let code = json["code"]?.stringValue ?? nested?["code"]?.stringValue ?? ""
        if OpenAICompatibleProvider.looksLikeContextOverflow(message) {
            return .contextTooLarge(estimatedTokens: 0, limit: OpenAICompatibleProvider.contextLimit(from: message) ?? 0)
        }
        let httpStatus: Int
        if let status { httpStatus = status }
        else if code.contains("rate_limit") || code.contains("usage_limit") { httpStatus = 429 }
        else if code.contains("invalid") { httpStatus = 400 }
        else { httpStatus = 500 }
        return .httpStatus(httpStatus, code.isEmpty ? message : "\(code): \(message)")
    }
}
