import PennantCore
import Foundation

/// A credential an `EndpointAuthority` hands the provider: the bearer value, the base URL it is valid for, and the
/// headers every request to that endpoint carries.
public struct EndpointCredential: Sendable, Equatable {
    public var bearer: String
    public var baseURL: String
    public var headers: [String: String]

    public init(bearer: String, baseURL: String, headers: [String: String] = [:]) {
        self.bearer = bearer
        self.baseURL = baseURL
        self.headers = headers
    }
}

/// Supplies `OpenAICompatibleProvider` (and `AzureResponsesProvider`) with a credential fetched per request instead
/// of the config's static `apiKey`/`baseURL`: an Azure key header, or a short-lived token from a command such as the
/// Azure CLI's. A plain endpoint uses no authority at all, so its behaviour is untouched.
public protocol EndpointAuthority: Sendable {
    /// The credential for the next request, refreshed first when it is about to expire.
    func credential() async throws -> EndpointCredential
    /// For a retryable status: the credential to retry with, refreshed at most once per request.
    func refreshCredential(rejected: EndpointCredential) async throws -> EndpointCredential
    /// Whether a non-2xx reply means "refresh the credential once and retry".
    func shouldRetry(status: Int, body: String, attempt: Int) -> Bool
}

public extension EndpointAuthority {
    func shouldRetry(status: Int, body: String, attempt: Int) -> Bool { status == 401 && attempt == 0 }
}

/// Inference over any OpenAI-compatible `/chat/completions` endpoint: vLLM or SGLang serving
/// a model served by vLLM or SGLang on your own GPU box, Ollama or LM Studio locally. Streams SSE, maps tool calls,
/// sends images as data URIs, and honours cancellation of the consuming task. With an `EndpointAuthority`
/// the bearer token, base URL, and extra headers come from it per request (Azure AI Foundry, a token command), with
/// one credential refresh and retry when the endpoint refuses the token.
public final class OpenAICompatibleProvider: InferenceProvider, Sendable {
    public let config: HostConfig.Inference
    public let capabilities: InferenceCapabilities
    public let authority: (any EndpointAuthority)?
    private let session: URLSession

    public init(config: HostConfig.Inference, session: URLSession = .shared, authority: (any EndpointAuthority)? = nil, capabilities: InferenceCapabilities? = nil) {
        self.config = config
        self.session = session
        self.authority = authority
        self.capabilities = capabilities ?? InferenceCapabilities(
            vision: config.supportsVision,
            tools: config.supportsTools,
            contextWindowTokens: config.contextWindowTokens,
            maxOutputTokens: config.maxOutputTokens,
            model: config.model,
            endpoint: config.baseURL
        )
    }

    // MARK: - InferenceProvider

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<InferenceChunk, Error>.makeStream()
        let config = self.config
        let session = self.session
        let authority = self.authority
        let task = Task {
            do {
                try await Self.run(request: request, config: config, authority: authority, session: session, continuation: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch let error as URLError where error.code == .cancelled {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch {
                log.warn("Request failed: \(error)", category: "inference")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func estimateTokens(_ messages: [ModelMessage], tools: [ToolSpec]) -> Int {
        TokenEstimator.tokens(for: messages, tools: tools)
    }

    public func healthCheck() async -> Bool {
        var base = config.baseURL
        var headers: [String: String] = [:]
        if let key = config.apiKey, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        if let authority {
            guard let credential = try? await authority.credential() else { return false }
            base = credential.baseURL
            headers = credential.headers
            headers["Authorization"] = "Bearer \(credential.bearer)"
        }
        guard let url = Self.endpointURL(base: base, path: "models") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200 ..< 300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Request building

    static func endpointURL(base: String, path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + "/" + path)
    }

    /// Builds the JSON body for `/chat/completions`. Exposed for tests.
    public static func requestBody(for request: InferenceRequest, config: HostConfig.Inference) -> JSONValue {
        let useNativeTools = config.supportsTools && !request.disableTools && !request.tools.isEmpty
        let usePromptedTools = !config.supportsTools && !request.disableTools && !request.tools.isEmpty

        var messages = encodeMessages(request.messages, config: config)
        if usePromptedTools {
            let prompt = promptedToolInstructions(request.tools)
            messages.insert(.object(["role": "system", "content": .string(prompt)]), at: messages.isEmpty ? 0 : min(1, messages.count))
        }

        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "messages": .array(messages),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
        ]
        // Reasoning models take an effort and reject `temperature`; everything else takes a temperature.
        if let effort = request.reasoningEffort ?? config.reasoningEffort {
            body["reasoning_effort"] = .string(effort)
        } else {
            body["temperature"] = .number(request.temperature)
        }
        let maxTokens = request.maxOutputTokens > 0 ? request.maxOutputTokens : config.maxOutputTokens
        // Reasoning models (and Azure OpenAI) take max_completion_tokens and refuse max_tokens.
        if maxTokens > 0 {
            let modern = config.provider == HostConfig.Inference.azureProvider || request.reasoningEffort != nil || config.reasoningEffort != nil
                || ReasoningEffortFit.wantsCompletionTokens(key: ReasoningEffortFit.key(base: config.baseURL, model: config.model))
            body[modern ? "max_completion_tokens" : "max_tokens"] = .number(Double(maxTokens))
        }
        if useNativeTools {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": "function",
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ]),
                ])
            })
            body["tool_choice"] = "auto"
        }
        if request.jsonMode { body["response_format"] = .object(["type": "json_object"]) }
        return .object(body)
    }

    static func encodeMessages(_ messages: [ModelMessage], config: HostConfig.Inference) -> [JSONValue] {
        var out: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .system:
                out.append(.object(["role": "system", "content": .string(message.text)]))
            case .user:
                out.append(.object(["role": "user", "content": encodeContent(message.parts, config: config)]))
            case .assistant:
                var obj: [String: JSONValue] = ["role": "assistant", "content": .string(message.text)]
                if !message.toolCalls.isEmpty {
                    obj["tool_calls"] = .array(message.toolCalls.map { call in
                        .object([
                            "id": .string(call.id.rawValue),
                            "type": "function",
                            "function": .object([
                                "name": .string(call.name),
                                "arguments": .string(call.arguments.compactText),
                            ]),
                        ])
                    })
                }
                out.append(.object(obj))
            case .tool:
                let callID = message.toolCallID?.rawValue ?? ""
                let images = message.parts.compactMap { part -> ModelContent? in
                    if case .image = part { return part } else { return nil }
                }
                var text = message.text
                if text.isEmpty { text = images.isEmpty ? "(no output)" : "(image result)" }
                if !images.isEmpty, !config.supportsVision {
                    text += "\n" + images.map { part -> String in
                        if case .image(let data, _) = part { return "[image omitted: \(data.count) bytes]" }
                        return ""
                    }.joined(separator: "\n")
                }
                var obj: [String: JSONValue] = ["role": "tool", "content": .string(text)]
                if !callID.isEmpty { obj["tool_call_id"] = .string(callID) }
                if let name = message.toolName { obj["name"] = .string(name) }
                out.append(.object(obj))
                if !images.isEmpty, config.supportsVision {
                    // Endpoints reject images inside tool messages; deliver them in a follow-up user turn.
                    var parts: [ModelContent] = [.text("Result image for tool call \(callID)")]
                    parts.append(contentsOf: images)
                    out.append(.object(["role": "user", "content": encodeContent(parts, config: config)]))
                }
            }
        }
        return out
    }

    static func encodeContent(_ parts: [ModelContent], config: HostConfig.Inference) -> JSONValue {
        let hasImage = parts.contains { if case .image = $0 { return true } else { return false } }
        if !hasImage {
            return .string(parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n"))
        }
        return .array(parts.map { part in
            switch part {
            case .text(let t):
                return .object(["type": "text", "text": .string(t)])
            case .image(let data, let mimeType):
                if config.supportsVision {
                    let uri = "data:\(mimeType);base64,\(data.base64EncodedString())"
                    return .object(["type": "image_url", "image_url": .object(["url": .string(uri)])])
                }
                return .object(["type": "text", "text": .string("[image omitted: \(data.count) bytes]")])
            }
        })
    }

    static func promptedToolInstructions(_ tools: [ToolSpec]) -> String {
        var lines: [String] = ["You can call tools. Available tools, each with its JSON Schema for arguments:"]
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description)\n  schema: \(tool.inputSchema.compactText)")
        }
        lines.append("")
        lines.append("To call a tool, reply with exactly one block in this form and nothing after it:")
        lines.append("<tool_call>{\"name\": \"<tool name>\", \"arguments\": { ... }}</tool_call>")
        lines.append("You may write brief text before the block. When no tool is needed, answer normally.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Streaming

    /// An authority's failure as the runtime reports it.
    static func describeAuthorityError(_ error: Error) -> String {
        if let e = error as? URLError { return e.localizedDescription }
        return String(describing: error)
    }

    private static func run(request original: InferenceRequest, config: HostConfig.Inference, authority: (any EndpointAuthority)?, session: URLSession, continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation) async throws {
        var request = original
        var config = config
        let effortKey = ReasoningEffortFit.key(base: config.baseURL, model: config.model)
        let askedEffort = request.reasoningEffort ?? config.reasoningEffort
        if let asked = askedEffort, let fitted = ReasoningEffortFit.substitute(for: asked, key: effortKey) {
            request.reasoningEffort = fitted
            config.reasoningEffort = nil
        }
        var effortRetried = false
        var paramRetried = false
        var credential: EndpointCredential?
        if let authority {
            do { credential = try await authority.credential() } catch let error as InferenceError { throw error } catch { throw InferenceError.unreachable(describeAuthorityError(error)) }
        }
        var attempt = 0

        while true {
            let base = credential?.baseURL ?? config.baseURL
            guard let url = endpointURL(base: base, path: "chat/completions") else {
                throw InferenceError.unreachable("Invalid base URL \(base)")
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = config.requestTimeout > 0 ? config.requestTimeout : 300
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("pennant-host/\(PennantVersion.string)", forHTTPHeaderField: "User-Agent")
            if let credential {
                if !credential.bearer.isEmpty { urlRequest.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization") }
                for (name, value) in credential.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            } else if let key = config.apiKey, !key.isEmpty {
                urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            urlRequest.httpBody = try JSONCodec.encode(requestBody(for: request, config: config))

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
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 65_536 { break }
                }
                let text = String(decoding: data, as: UTF8.self)
                if let authority, let rejected = credential, authority.shouldRetry(status: http.statusCode, body: text, attempt: attempt) {
                    attempt += 1
                    log.info("Endpoint answered HTTP \(http.statusCode); refreshing the credential and retrying once", category: "inference")
                    do {
                        credential = try await authority.refreshCredential(rejected: rejected)
                    } catch let error as InferenceError {
                        throw error
                    } catch {
                        throw InferenceError.httpStatus(http.statusCode, describeAuthorityError(error))
                    }
                    continue
                }
                // An endpoint that wants max_completion_tokens instead of max_tokens: remember it and retry once.
                if http.statusCode == 400, !paramRetried, text.contains("max_completion_tokens") {
                    paramRetried = true
                    ReasoningEffortFit.rememberCompletionTokens(key: effortKey)
                    log.info("\(config.model) wants max_completion_tokens; retrying", category: "inference")
                    continue
                }
                // An effort this model does not accept: use the nearest one it names (or none), once.
                if http.statusCode == 400, !effortRetried, let asked = askedEffort, ReasoningEffortFit.isEffortError(text) {
                    effortRetried = true
                    let fitted = ReasoningEffortFit.nearest(to: asked, among: ReasoningEffortFit.supported(in: text))
                    ReasoningEffortFit.remember(asked, as: fitted, key: effortKey)
                    log.info("\(config.model) does not accept reasoning effort \(asked); using \(fitted ?? "none")", category: "inference")
                    request.reasoningEffort = fitted
                    config.reasoningEffort = nil
                    continue
                }
                if looksLikeContextOverflow(text) {
                    let estimate = TokenEstimator.tokens(for: request.messages, tools: request.tools)
                    throw InferenceError.contextTooLarge(estimatedTokens: estimate, limit: contextLimit(from: text) ?? config.contextWindowTokens)
                }
                throw InferenceError.httpStatus(http.statusCode, text)
            }

            let bufferText = !config.supportsTools && !request.disableTools && !request.tools.isEmpty
            var assembler = ChunkAssembler(bufferText: bufferText, toolNames: Set(request.tools.map(\.name)),
                                           toolSchemas: Dictionary(request.tools.map { ($0.name, $0.inputSchema) }, uniquingKeysWith: { first, _ in first }))
            var parser = SSEParser()
            var lineBuffer = Data()
            lineBuffer.reserveCapacity(4096)

            func process(_ payloads: [String]) throws -> Bool {
                for payload in payloads {
                    if payload == SSEParser.doneMarker { return true }
                    for chunk in try assembler.handle(payload: payload) { continuation.yield(chunk) }
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
            for chunk in assembler.end() { continuation.yield(chunk) }
            return
        }
    }

    static func looksLikeContextOverflow(_ body: String) -> Bool {
        let lower = body.lowercased()
        let markers = ["context length", "maximum context", "context window", "too many tokens", "context_length_exceeded", "reduce the length", "exceeds the model's max", "prompt is too long", "input length"]
        return markers.contains { lower.contains($0) }
    }

    /// Best-effort extraction of the model's context limit from an error body such as
    /// "This model's maximum context length is 131072 tokens".
    static func contextLimit(from body: String) -> Int? {
        let pattern = #"(?:maximum context length is|context length of|context window of|max(?:imum)? (?:model )?len(?:gth)?(?: is| of)?)\s*(\d{3,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return Int(body[range])
    }
}

// MARK: - Chunk assembly

/// Turns streamed `chat.completion.chunk` payloads into `InferenceChunk`s. Accumulates tool call
/// fragments by index and finalises them when a finish reason arrives or the stream ends.
struct ChunkAssembler: Sendable {
    private struct PendingToolCall {
        var id: String?
        var name: String
        var arguments: String
    }

    private var pending: [Int: PendingToolCall] = [:]
    private var order: [Int] = []
    private var toolCallsEmitted = false
    private var finishReason: FinishReason?
    private var sawToolCalls = false
    private let bufferText: Bool
    private var bufferedText = ""
    private let toolNames: Set<String>
    private let toolSchemas: [String: JSONValue]
    /// With native tool calling, some servers still pass a model's own tool-call text through as text (GLM's
    /// `<tool_call>name<arg_key>…`, or JSON in the same tags). From the first `<tool_call>` on, the text is held back
    /// and read as calls at the end, so it never shows as a message; `tagStart` is a tail that may be the tag's start.
    private var heldText = ""
    private var holding = false
    private var tagStart = ""
    private static let openTag = "<tool_call>"

    init(bufferText: Bool, toolNames: Set<String>, toolSchemas: [String: JSONValue] = [:]) {
        self.bufferText = bufferText
        self.toolNames = toolNames
        self.toolSchemas = toolSchemas
    }

    mutating func handle(payload: String) throws -> [InferenceChunk] {
        let json: JSONValue
        do {
            json = try JSONValue.parse(payload)
        } catch {
            throw InferenceError.malformedResponse("Unparseable SSE payload: \(payload.prefix(200))")
        }
        if let error = json["error"], !error.isNull {
            let message = error["message"]?.stringValue ?? error.stringValue ?? error.compactText
            if OpenAICompatibleProvider.looksLikeContextOverflow(message) {
                throw InferenceError.contextTooLarge(estimatedTokens: 0, limit: OpenAICompatibleProvider.contextLimit(from: message) ?? 0)
            }
            let code = error["code"]?.intValue ?? json["status"]?.intValue ?? 500
            throw InferenceError.httpStatus(code, message)
        }

        var out: [InferenceChunk] = []
        if let usage = json["usage"], let prompt = usage["prompt_tokens"]?.intValue ?? usage["input_tokens"]?.intValue {
            let completion = usage["completion_tokens"]?.intValue ?? usage["output_tokens"]?.intValue ?? 0
            let cached = usage["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? usage["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
            out.append(.usage(TokenUsage(inputTokens: prompt, outputTokens: completion, cachedInputTokens: cached)))
        }

        guard let choice = json["choices"]?.arrayValue?.first else { return out }
        let delta = choice["delta"] ?? choice["message"] ?? .null

        if let reasoning = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue, !reasoning.isEmpty {
            out.append(.reasoningDelta(reasoning))
        }
        if let content = delta["content"]?.stringValue, !content.isEmpty {
            if bufferText { bufferedText += content } else { out.append(contentsOf: passText(content)) }
        }
        if let calls = delta["tool_calls"]?.arrayValue {
            sawToolCalls = true
            for (position, call) in calls.enumerated() {
                let index = call["index"]?.intValue ?? position
                var entry = pending[index] ?? PendingToolCall(id: nil, name: "", arguments: "")
                if pending[index] == nil { order.append(index) }
                if let id = call["id"]?.stringValue, !id.isEmpty { entry.id = id }
                if let fn = call["function"] {
                    if let name = fn["name"]?.stringValue, !name.isEmpty { entry.name += name }
                    if let args = fn["arguments"] {
                        switch args {
                        case .string(let s): entry.arguments += s
                        case .object, .array: entry.arguments += args.compactText
                        default: break
                        }
                    }
                }
                pending[index] = entry
            }
        }
        if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
            finishReason = Self.mapFinishReason(reason)
            out.append(contentsOf: flushToolCalls())
        }
        return out
    }

    /// Streams text on, except a tool call written out as text: from `<tool_call>` on, it's held for `end`.
    private mutating func passText(_ content: String) -> [InferenceChunk] {
        if holding { heldText += content; return [] }
        let text = tagStart + content
        tagStart = ""
        if let tag = text.range(of: Self.openTag) {
            holding = true
            heldText = String(text[tag.lowerBound...])
            let before = String(text[..<tag.lowerBound])
            return before.isEmpty ? [] : [.textDelta(before)]
        }
        let keep = Self.partialTagLength(at: text)
        tagStart = String(text.suffix(keep))
        let shown = String(text.dropLast(keep))
        return shown.isEmpty ? [] : [.textDelta(shown)]
    }

    /// How much of the end of `text` could be the start of `<tool_call>` ("<tool_c"), to hold until the next chunk.
    static func partialTagLength(at text: String) -> Int {
        for length in stride(from: min(openTag.count - 1, text.count), through: 1, by: -1) where text.hasSuffix(String(openTag.prefix(length))) {
            return length
        }
        return 0
    }

    mutating func end() -> [InferenceChunk] {
        var out: [InferenceChunk] = []
        if !tagStart.isEmpty { out.append(.textDelta(tagStart)); tagStart = "" }
        if holding {
            // Any tool, not only this turn's: the chat loads a service's tools on demand, and a model calls one it used
            // before. The runtime runs a real tool by name and answers an unknown one, as for a call sent properly.
            let (cleaned, calls) = Self.extractPromptedToolCalls(from: heldText, allowedNames: [], schemas: toolSchemas, fencedJSON: false)
            heldText = ""
            holding = false
            if !cleaned.isEmpty { out.append(.textDelta(cleaned)) }
            // Calls the server also sent as real calls aren't run twice.
            if !calls.isEmpty, !sawToolCalls {
                sawToolCalls = true
                out.append(contentsOf: calls.map { .toolCall($0) })
            }
        }
        if bufferText {
            let (cleaned, calls) = Self.extractPromptedToolCalls(from: bufferedText, allowedNames: toolNames, schemas: toolSchemas)
            bufferedText = ""
            if !cleaned.isEmpty { out.append(.textDelta(cleaned)) }
            if !calls.isEmpty {
                sawToolCalls = true
                out.append(contentsOf: calls.map { .toolCall($0) })
                toolCallsEmitted = true
            }
        }
        out.append(contentsOf: flushToolCalls())
        let reason: FinishReason
        if sawToolCalls, finishReason == nil || finishReason == .stop {
            reason = .toolCalls
        } else {
            reason = finishReason ?? .stop
        }
        out.append(.finished(reason))
        return out
    }

    private mutating func flushToolCalls() -> [InferenceChunk] {
        guard !toolCallsEmitted, !pending.isEmpty else { return [] }
        toolCallsEmitted = true
        var out: [InferenceChunk] = []
        for index in order {
            guard let entry = pending[index] else { continue }
            let id = entry.id.flatMap { $0.isEmpty ? nil : $0 } ?? "call_" + UUID().uuidString.lowercased().prefix(12)
            out.append(.toolCall(ToolCall(id: ToolCallID(id), name: entry.name, arguments: Self.parseArguments(entry.arguments))))
        }
        pending.removeAll()
        order.removeAll()
        return out
    }

    static func parseArguments(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        if let value = try? JSONValue.parse(trimmed) {
            if case .object = value { return value }
            if case .string(let inner) = value, let nested = try? JSONValue.parse(inner), case .object = nested { return nested }
            return .object(["_raw": value])
        }
        return .object(["_raw": .string(raw)])
    }

    static func mapFinishReason(_ reason: String) -> FinishReason {
        switch reason.lowercased() {
        case "stop", "end_turn", "eos": return .stop
        case "tool_calls", "function_call", "tool_use": return .toolCalls
        case "length", "max_tokens": return .length
        case "content_filter": return .contentFilter
        default: return .stop
        }
    }

    /// Tool calls written out as text: `<tool_call>{...}</tool_call>` or fenced ```json blocks shaped like
    /// {"name": ..., "arguments": {...}}, and GLM's `<tool_call>name<arg_key>k</arg_key><arg_value>v</arg_value></tool_call>`
    /// (its values typed by the tool's schema). For endpoints without native tool calling, and for servers that pass a
    /// model's own call text through. A last call whose closing tag never came is read too.
    static func extractPromptedToolCalls(from text: String, allowedNames: Set<String>, schemas: [String: JSONValue] = [:], fencedJSON: Bool = true) -> (String, [ToolCall]) {
        var calls: [ToolCall] = []
        var cleaned = text
        var patterns = [#"<tool_call>\s*([\s\S]*?)\s*(?:</tool_call>|$)"#]
        if fencedJSON { patterns.append(#"```(?:json)?\s*([\s\S]*?)```"#) }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            var removals: [Range<String.Index>] = []
            for match in regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
                guard let inner = Range(match.range(at: 1), in: cleaned), let whole = Range(match.range, in: cleaned) else { continue }
                let candidate = String(cleaned[inner]).trimmingCharacters(in: .whitespacesAndNewlines)
                var parsed = parseToolCallJSON(candidate, allowedNames: allowedNames)
                if parsed.isEmpty, let call = parseKeyValueToolCall(candidate, allowedNames: allowedNames, schemas: schemas) { parsed = [call] }
                if !parsed.isEmpty {
                    calls.append(contentsOf: parsed)
                    removals.append(whole)
                }
            }
            for range in removals.reversed() { cleaned.removeSubrange(range) }
        }
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    /// GLM's form: the tool's name, then `<arg_key>k</arg_key><arg_value>v</arg_value>` pairs. A value is text where the
    /// schema says string, and read as JSON (a number, a flag, a list) otherwise when it is.
    static func parseKeyValueToolCall(_ text: String, allowedNames: Set<String>, schemas: [String: JSONValue]) -> ToolCall? {
        let name = String(text[..<(text.range(of: "<arg_key>")?.lowerBound ?? text.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("<"), !name.contains("{"), allowedNames.isEmpty || allowedNames.contains(name) else { return nil }
        guard let pair = try? NSRegularExpression(pattern: #"<arg_key>\s*([\s\S]*?)\s*</arg_key>\s*<arg_value>([\s\S]*?)</arg_value>"#) else { return nil }
        var arguments: [String: JSONValue] = [:]
        for match in pair.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let k = Range(match.range(at: 1), in: text), let v = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[k])
            let raw = String(text[v]).trimmingCharacters(in: .whitespacesAndNewlines)
            let type = schemas[name]?["properties"]?[key]?["type"]?.stringValue
            if type == "string" { arguments[key] = .string(raw) }
            else if let value = try? JSONValue.parse(raw), value.stringValue == nil || type == nil { arguments[key] = value }
            else { arguments[key] = .string(raw) }
        }
        return ToolCall(id: ToolCallID("call_" + UUID().uuidString.lowercased().prefix(12)), name: name, arguments: .object(arguments))
    }

    private static func parseToolCallJSON(_ text: String, allowedNames: Set<String>) -> [ToolCall] {
        guard let value = try? JSONValue.parse(text) else { return [] }
        let objects: [JSONValue]
        switch value {
        case .array(let items): objects = items
        case .object: objects = [value]
        default: return []
        }
        return objects.compactMap { object in
            guard let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
            if !allowedNames.isEmpty, !allowedNames.contains(name) { return nil }
            let args = object["arguments"] ?? object["parameters"] ?? object["input"] ?? .object([:])
            let arguments: JSONValue
            switch args {
            case .object: arguments = args
            case .string(let s): arguments = parseArguments(s)
            default: arguments = .object(["_raw": args])
            }
            let id = object["id"]?.stringValue ?? "call_" + UUID().uuidString.lowercased().prefix(12)
            return ToolCall(id: ToolCallID(id), name: name, arguments: arguments)
        }
    }
}
