import PennantCore
import Foundation
#if canImport(FoundationModels) && os(macOS)
import FoundationModels
#endif

/// Inference on Apple's on-device foundation model through the FoundationModels framework
/// (macOS 26 and later, Apple Intelligence switched on). No network, no API key, no images.
///
/// One `LanguageModelSession` is created per `stream` call: the leading system messages become the
/// session instructions, earlier turns are replayed into the session transcript (user and assistant
/// text, tool calls and their outputs as native entries), and the trailing user text is the prompt.
///
/// Tools are exposed to the framework as dynamic `Tool`s whose schema is built from each
/// `ToolSpec`'s JSON schema. The framework wants to run tools itself; Pennant's runtime runs them after
/// the model turn, so the dynamic tool only records the call and throws, which ends the session. The
/// provider then yields the recorded calls and `.finished(.toolCalls)`. One tool batch per turn.
///
/// The package deploys to macOS 15, so every framework use sits behind `#if canImport` and
/// `#available(macOS 26, *)`; below that the provider reports itself as unreachable.
public final class AppleOnDeviceProvider: InferenceProvider, Sendable {
    public static let modelName = "apple-on-device"
    public static let endpointName = "on-device"
    /// Replaces every image part: the on-device model has no vision, and both the runtime and the
    /// model should know a screenshot was there.
    public static let imageOmittedNote = "[screenshot omitted: the on-device model cannot see images]"
    /// Prompt used when the context ends with tool results and no new user text.
    public static let continueAfterToolsPrompt = "Continue the task using the tool results above."
    /// Prompt used when the context ends with an assistant message and nothing to answer.
    public static let continuePrompt = "Continue."

    public let capabilities: InferenceCapabilities

    public init() {
        capabilities = InferenceCapabilities(
            vision: false,
            tools: true,
            contextWindowTokens: Self.contextWindowTokens,
            maxOutputTokens: Self.defaultMaxOutputTokens,
            model: Self.modelName,
            endpoint: Self.endpointName
        )
    }

    /// Apple documents a 4096-token window for the macOS 26 model; the macOS 27 model reports 8192
    /// in its context-size error ("exceeds the maximum allowed context size of 8192").
    public static var contextWindowTokens: Int {
        #if canImport(FoundationModels) && os(macOS)
        if #available(macOS 27, *) { return 8192 }
        #endif
        return 4096
    }

    /// Output cap per turn; the window is shared between prompt and reply, so keep replies short.
    public static let defaultMaxOutputTokens = 1024

    // MARK: - Availability

    /// Human-readable availability of the on-device model: "available", "not supported on this Mac",
    /// "Apple Intelligence is off", "model downloading", or "requires macOS 26".
    public static var availability: String {
        #if canImport(FoundationModels) && os(macOS)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "not supported on this Mac"
                case .appleIntelligenceNotEnabled: return "Apple Intelligence is off"
                case .modelNotReady: return "model downloading"
                @unknown default: return "unavailable"
                }
            }
        }
        #endif
        return "requires macOS 26"
    }

    /// True when the framework is compiled in, the OS is new enough, and the model can answer now.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels) && os(macOS)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    // MARK: - InferenceProvider

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<InferenceChunk, Error>.makeStream()
        #if canImport(FoundationModels) && os(macOS)
        if #available(macOS 26, *) {
            let capabilities = self.capabilities
            let task = Task {
                do {
                    try await Self.run(request: request, capabilities: capabilities, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(.cancelled))
                    continuation.finish()
                } catch {
                    let mapped = Self.mapError(error, request: request, capabilities: capabilities)
                    log.warn("On-device request failed: \(mapped)", category: "inference")
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
        #endif
        continuation.finish(throwing: InferenceError.unreachable("Apple on-device inference requires macOS 26 (this build: \(Self.availability))"))
        return stream
    }

    public func estimateTokens(_ messages: [ModelMessage], tools: [ToolSpec]) -> Int {
        TokenEstimator.tokens(for: messages, tools: tools)
    }

    public func healthCheck() async -> Bool {
        Self.isAvailable
    }

    // MARK: - Message preparation (pure, available on every OS)

    /// What one model turn looks like once Pennant's message list is split for the framework.
    public struct PreparedTurn: Equatable, Sendable {
        /// Leading system messages, joined. Becomes the session instructions.
        public var instructions: String
        /// Everything between the instructions and the prompt; replayed into the transcript.
        public var history: [ModelMessage]
        /// The text the session is asked to respond to.
        public var prompt: String
    }

    /// Splits a request into instructions, replayable history, and the prompt. Images are replaced
    /// by `imageOmittedNote` everywhere. Trailing user and system messages form the prompt; when
    /// there are none the prompt asks the model to continue.
    public static func prepare(_ request: InferenceRequest) -> PreparedTurn {
        let messages = request.messages.map(stripImages)

        var index = 0
        var instructionParts: [String] = []
        while index < messages.count, messages[index].role == .system {
            let text = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { instructionParts.append(text) }
            index += 1
        }
        if request.jsonMode {
            instructionParts.append("Reply with a single JSON object and nothing else.")
        }

        var tail = messages.count
        while tail > index, messages[tail - 1].role == .user || messages[tail - 1].role == .system {
            tail -= 1
        }
        let history = Array(messages[index ..< tail])
        let promptParts = messages[tail...].map(\.text).filter { !$0.isEmpty }

        let prompt: String
        if !promptParts.isEmpty {
            prompt = promptParts.joined(separator: "\n\n")
        } else if history.last?.role == .tool {
            prompt = continueAfterToolsPrompt
        } else {
            prompt = continuePrompt
        }
        return PreparedTurn(instructions: instructionParts.joined(separator: "\n\n"), history: history, prompt: prompt)
    }

    /// Drops image parts and appends one `imageOmittedNote` when any were present.
    public static func stripImages(_ message: ModelMessage) -> ModelMessage {
        var out = message
        var parts: [ModelContent] = []
        var dropped = false
        for part in message.parts {
            if case .image = part { dropped = true } else { parts.append(part) }
        }
        if dropped { parts.append(.text(imageOmittedNote)) }
        out.parts = parts
        return out
    }

    /// Streaming snapshots are cumulative; this returns only the new suffix.
    static func textDelta(previous: String, current: String) -> String {
        if current.hasPrefix(previous) { return String(current.dropFirst(previous.count)) }
        let common = zip(previous, current).prefix { $0 == $1 }.count
        return String(current.dropFirst(common))
    }

    /// Text form of a tool result for prompts that cannot carry a native tool entry.
    static func foldedToolResult(name: String, text: String) -> String {
        "[tool \(name) returned: \(text.isEmpty ? "(no output)" : text)]"
    }
}

#if canImport(FoundationModels) && os(macOS)

// MARK: - Session

@available(macOS 26, *)
extension AppleOnDeviceProvider {
    static func run(request: InferenceRequest, capabilities: InferenceCapabilities, continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation) async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw InferenceError.unreachable("Apple on-device model is \(availability)")
        }

        let turn = prepare(request)
        let collector = ToolCallCollector()
        var tools: [DeferredTool] = []
        if !request.disableTools {
            for spec in request.tools {
                do {
                    tools.append(try DeferredTool(spec: spec, collector: collector))
                } catch {
                    log.warn("Tool \(spec.name) skipped for the on-device model: schema not representable (\(error))", category: "inference")
                }
            }
        }

        let transcript = transcript(instructions: turn.instructions, history: turn.history, tools: tools)
        let session = LanguageModelSession(model: model, tools: tools, transcript: transcript)
        let cap = request.maxOutputTokens > 0 ? min(request.maxOutputTokens, capabilities.maxOutputTokens) : capabilities.maxOutputTokens
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: cap)

        var emitted = ""
        do {
            for try await snapshot in session.streamResponse(to: turn.prompt, options: options) {
                try Task.checkCancellation()
                let content = snapshot.content
                let delta = textDelta(previous: emitted, current: content)
                if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                emitted = content
            }
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is ToolCallDeferred {
            // Expected: a dynamic tool recorded its call and stopped the session.
        }
        try Task.checkCancellation()

        let calls = await collector.calls
        for call in calls { continuation.yield(.toolCall(call)) }
        continuation.yield(.usage(usage(session: session, request: request, outputText: emitted, calls: calls)))
        continuation.yield(.finished(calls.isEmpty ? .stop : .toolCalls))
    }

    static func usage(session: LanguageModelSession, request: InferenceRequest, outputText: String, calls: [ToolCall]) -> TokenUsage {
        if #available(macOS 27, *) {
            let reported = session.usage
            if reported.input.totalTokenCount > 0 || reported.output.totalTokenCount > 0 {
                return TokenUsage(inputTokens: reported.input.totalTokenCount, outputTokens: reported.output.totalTokenCount)
            }
        }
        let output = TokenEstimator.tokens(forText: outputText) + calls.reduce(0) { $0 + TokenEstimator.tokens(forText: $1.name + $1.arguments.compactText) + 6 }
        return TokenUsage(inputTokens: TokenEstimator.tokens(for: request.messages, tools: request.tools), outputTokens: output)
    }

    // MARK: Transcript

    /// Replays Pennant's history as framework transcript entries. Consecutive user and system messages
    /// merge into one prompt entry; an assistant message that requested tools becomes a `toolCalls`
    /// entry (preceded by a response entry when it also said something); tool messages become
    /// `toolOutput` entries when they answer a pending call, else folded text in a prompt entry.
    static func transcript(instructions: String, history: [ModelMessage], tools: [DeferredTool]) -> Transcript {
        var entries: [Transcript.Entry] = []
        let definitions = tools.map { Transcript.ToolDefinition(tool: $0) }
        if !instructions.isEmpty || !definitions.isEmpty {
            let segments: [Transcript.Segment] = instructions.isEmpty ? [] : [.text(Transcript.TextSegment(content: instructions))]
            entries.append(.instructions(Transcript.Instructions(segments: segments, toolDefinitions: definitions)))
        }

        var pendingPrompt: [String] = []
        var pendingCallIDs = Set<String>()
        func flushPrompt() {
            guard !pendingPrompt.isEmpty else { return }
            entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: pendingPrompt.joined(separator: "\n\n")))])))
            pendingPrompt.removeAll()
        }

        for message in history {
            switch message.role {
            case .system, .user:
                let text = message.text
                if !text.isEmpty { pendingPrompt.append(text) }
            case .assistant:
                flushPrompt()
                let text = message.text
                if !text.isEmpty {
                    entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: text))])))
                }
                if !message.toolCalls.isEmpty {
                    let calls = message.toolCalls.map { call in
                        Transcript.ToolCall(id: call.id.rawValue, toolName: call.name, arguments: generatedContent(from: call.arguments))
                    }
                    pendingCallIDs.formUnion(message.toolCalls.map(\.id.rawValue))
                    entries.append(.toolCalls(Transcript.ToolCalls(calls)))
                }
            case .tool:
                let name = message.toolName ?? "tool"
                let text = message.text.isEmpty ? "(no output)" : message.text
                if let id = message.toolCallID?.rawValue, pendingCallIDs.contains(id) {
                    flushPrompt()
                    pendingCallIDs.remove(id)
                    entries.append(.toolOutput(Transcript.ToolOutput(id: id, toolName: name, segments: [.text(Transcript.TextSegment(content: text))])))
                } else {
                    pendingPrompt.append(foldedToolResult(name: name, text: text))
                }
            }
        }
        flushPrompt()
        return Transcript(entries: entries)
    }

    // MARK: Schema bridge

    /// `GenerationSchema` for a tool's JSON-schema arguments. Throws when the framework rejects the
    /// shape (duplicate names, empty choices).
    public static func generationSchema(for spec: ToolSpec) throws -> GenerationSchema {
        let root = dynamicSchema(name: typeName(spec.name) + "_arguments", from: spec.inputSchema)
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// JSON Schema → `DynamicGenerationSchema`. Objects (properties, required), strings, integers,
    /// numbers, booleans, arrays (items, minItems, maxItems), enums and const are represented;
    /// anything else degrades to a string so the tool remains callable.
    public static func dynamicSchema(name: String, from schema: JSONValue) -> DynamicGenerationSchema {
        let description = schema["description"]?.stringValue

        if let choices = schema["enum"]?.arrayValue, !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices.map(scalarText))
        }
        if let constant = schema["const"] {
            return DynamicGenerationSchema(name: name, description: description, anyOf: [scalarText(constant)])
        }

        var type = schema["type"]?.stringValue
        if type == nil, let types = schema["type"]?.arrayValue {
            type = types.compactMap(\.stringValue).first { $0 != "null" }
        }
        if type == nil, schema["properties"] != nil { type = "object" }
        if type == nil, schema["items"] != nil { type = "array" }

        switch type {
        case "object":
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let properties = schema["properties"]?.objectValue ?? [:]
            let props = properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
                let sub = properties[key] ?? .object([:])
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: sub["description"]?.stringValue,
                    schema: dynamicSchema(name: name + "_" + typeName(key), from: sub),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: props)
        case "array":
            let item = dynamicSchema(name: name + "_item", from: schema["items"] ?? .object(["type": "string"]))
            return DynamicGenerationSchema(arrayOf: item, minimumElements: schema["minItems"]?.intValue, maximumElements: schema["maxItems"]?.intValue)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// `GeneratedContent` → `JSONValue`, preserving structure key order where it matters.
    public static func jsonValue(from content: GeneratedContent) -> JSONValue {
        switch content.kind {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let items): return .array(items.map(jsonValue))
        case .structure(let properties, _):
            return .object(properties.mapValues(jsonValue))
        @unknown default:
            return (try? JSONValue.parse(content.jsonString)) ?? .string(content.jsonString)
        }
    }

    /// `JSONValue` → `GeneratedContent`, used to replay earlier tool calls into the transcript.
    public static func generatedContent(from value: JSONValue) -> GeneratedContent {
        switch value {
        case .null: return GeneratedContent(kind: .null)
        case .bool(let b): return GeneratedContent(kind: .bool(b))
        case .number(let n): return GeneratedContent(kind: .number(n))
        case .string(let s): return GeneratedContent(kind: .string(s))
        case .array(let items): return GeneratedContent(kind: .array(items.map(generatedContent)))
        case .object(let object):
            let keys = object.keys.sorted()
            return GeneratedContent(kind: .structure(properties: object.mapValues(generatedContent), orderedKeys: keys))
        }
    }

    static func typeName(_ raw: String) -> String {
        let cleaned = raw.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(cleaned).isEmpty ? "value" : String(cleaned)
    }

    static func scalarText(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return value.compactText
        }
    }

    // MARK: Errors

    static func mapError(_ error: Error, request: InferenceRequest, capabilities: InferenceCapabilities) -> Error {
        if error is InferenceError || error is CancellationError { return error }
        let estimate = TokenEstimator.tokens(for: request.messages, tools: request.tools)

        if #available(macOS 27, *) {
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded(let info):
                    return InferenceError.contextTooLarge(estimatedTokens: info.tokenCount, limit: info.contextSize)
                case .rateLimited(let info):
                    return InferenceError.unreachable("The on-device model is rate limited: \(info.debugDescription)")
                case .guardrailViolation(let info):
                    return InferenceError.malformedResponse("The on-device model's safety guardrails blocked this turn: \(info.debugDescription)")
                case .refusal(let info):
                    return InferenceError.malformedResponse("The on-device model refused this turn: \(info.debugDescription)")
                case .unsupportedCapability(let info):
                    return InferenceError.malformedResponse("The on-device model lacks a capability this turn needs: \(info.debugDescription)")
                case .unsupportedTranscriptContent(let info):
                    return InferenceError.malformedResponse("The on-device model rejected part of the conversation history: \(info.debugDescription)")
                case .unsupportedGenerationGuide(let info):
                    return InferenceError.malformedResponse("A tool schema uses a constraint the on-device model does not support: \(info.debugDescription)")
                case .unsupportedLanguageOrLocale(let info):
                    return InferenceError.malformedResponse("The on-device model does not support this language: \(info.debugDescription)")
                case .timeout(let info):
                    return InferenceError.unreachable("The on-device model timed out: \(info.debugDescription)")
                @unknown default:
                    return InferenceError.malformedResponse("On-device model error: \(modelError.localizedDescription)")
                }
            }
            if let modelError = error as? SystemLanguageModel.Error {
                switch modelError {
                case .assetsUnavailable(let info):
                    return InferenceError.unreachable("Apple Intelligence model assets are unavailable: \(info.debugDescription)")
                @unknown default:
                    return InferenceError.unreachable("On-device model error: \(modelError.localizedDescription)")
                }
            }
            if let sessionError = error as? LanguageModelSession.Error {
                switch sessionError {
                case .concurrentRequests:
                    return InferenceError.unreachable("The on-device model session is already responding")
                case .transcriptMutationWhileResponding:
                    return InferenceError.malformedResponse("The on-device session transcript changed while responding")
                @unknown default:
                    return InferenceError.malformedResponse("On-device session error: \(sessionError.localizedDescription)")
                }
            }
        }

        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return InferenceError.contextTooLarge(estimatedTokens: estimate, limit: capabilities.contextWindowTokens)
            case .assetsUnavailable(let context):
                return InferenceError.unreachable("Apple Intelligence model assets are unavailable: \(context.debugDescription)")
            case .guardrailViolation(let context):
                return InferenceError.malformedResponse("The on-device model's safety guardrails blocked this turn: \(context.debugDescription)")
            case .refusal(_, let context):
                return InferenceError.malformedResponse("The on-device model refused this turn: \(context.debugDescription)")
            case .unsupportedGuide(let context):
                return InferenceError.malformedResponse("A tool schema uses a constraint the on-device model does not support: \(context.debugDescription)")
            case .unsupportedLanguageOrLocale(let context):
                return InferenceError.malformedResponse("The on-device model does not support this language: \(context.debugDescription)")
            case .decodingFailure(let context):
                return InferenceError.malformedResponse("The on-device model produced output that could not be decoded: \(context.debugDescription)")
            case .rateLimited(let context):
                return InferenceError.unreachable("The on-device model is rate limited: \(context.debugDescription)")
            case .concurrentRequests(let context):
                return InferenceError.unreachable("The on-device model session is already responding: \(context.debugDescription)")
            @unknown default:
                return InferenceError.malformedResponse("On-device model error: \(generationError.localizedDescription)")
            }
        }
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return InferenceError.malformedResponse("The on-device model's call to \(toolError.tool.name) failed: \(toolError.underlyingError)")
        }
        return InferenceError.unreachable("Apple on-device model failed: \(error.localizedDescription)")
    }
}

// MARK: - Dynamic tools

/// Thrown by `DeferredTool.call` so the session stops after the model's first tool batch.
struct ToolCallDeferred: Error, CustomStringConvertible {
    let name: String
    var description: String { "Tool call to \(name) queued for Pennant's runtime" }
}

/// Collects the calls the model makes during one turn.
@available(macOS 26, *)
actor ToolCallCollector {
    private(set) var calls: [ToolCall] = []
    func record(_ call: ToolCall) { calls.append(call) }
}

/// A framework `Tool` made from a `ToolSpec`. It never runs the tool: the runtime does that after the
/// turn, with permission checks and outcome records. It records the call and throws, which ends the
/// session; the provider yields the recorded calls afterwards.
@available(macOS 26, *)
struct DeferredTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let collector: ToolCallCollector

    init(spec: ToolSpec, collector: ToolCallCollector) throws {
        name = spec.name
        description = spec.description
        parameters = try AppleOnDeviceProvider.generationSchema(for: spec)
        self.collector = collector
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let call = ToolCall(id: ToolCallID(), name: name, arguments: AppleOnDeviceProvider.jsonValue(from: arguments))
        await collector.record(call)
        throw ToolCallDeferred(name: name)
    }
}

#endif
