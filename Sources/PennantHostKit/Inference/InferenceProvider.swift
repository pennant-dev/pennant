import PennantCore
import Foundation

/// A message in the model's active context. Built by the runtime from durable state, not stored directly.
public struct ModelMessage: Hashable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var parts: [ModelContent]
    /// For tool role messages: the tool call being answered.
    public var toolCallID: ToolCallID?
    public var toolName: String?
    /// For assistant messages that requested tools.
    public var toolCalls: [ToolCall]

    public init(role: Role, parts: [ModelContent], toolCallID: ToolCallID? = nil, toolName: String? = nil, toolCalls: [ToolCall] = []) {
        self.role = role
        self.parts = parts
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
    }

    public static func system(_ text: String) -> ModelMessage { ModelMessage(role: .system, parts: [.text(text)]) }
    public static func user(_ text: String) -> ModelMessage { ModelMessage(role: .user, parts: [.text(text)]) }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> ModelMessage { ModelMessage(role: .assistant, parts: text.isEmpty ? [] : [.text(text)], toolCalls: toolCalls) }
    public static func tool(callID: ToolCallID, name: String, parts: [ModelContent]) -> ModelMessage { ModelMessage(role: .tool, parts: parts, toolCallID: callID, toolName: name) }

    public var text: String { parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n") }
}

public enum ModelContent: Hashable, Sendable {
    case text(String)
    /// Raw image bytes; the provider encodes them for the endpoint.
    case image(data: Data, mimeType: String)
}

public struct InferenceRequest: Sendable {
    public var messages: [ModelMessage]
    public var tools: [ToolSpec]
    public var maxOutputTokens: Int
    public var temperature: Double
    /// Force the model to answer in text without tools (used for summaries and checkpoints).
    public var disableTools: Bool
    /// Ask for a JSON object response when the endpoint supports it.
    public var jsonMode: Bool
    /// "low", "medium" or "high" for reasoning models; nil leaves the provider's default.
    public var reasoningEffort: String?

    public init(messages: [ModelMessage], tools: [ToolSpec] = [], maxOutputTokens: Int = 4096, temperature: Double = 0.2, disableTools: Bool = false, jsonMode: Bool = false, reasoningEffort: String? = nil) {
        self.reasoningEffort = reasoningEffort
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.disableTools = disableTools
        self.jsonMode = jsonMode
    }
}

public struct TokenUsage: Hashable, Sendable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Of `inputTokens`, how many the provider served from its prompt cache (usually billed cheaper).
    public var cachedInputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedInputTokens = cachedInputTokens
    }
}

public enum FinishReason: String, Sendable { case stop, toolCalls, length, contentFilter, cancelled, error }

public enum InferenceChunk: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    /// A complete tool call, emitted once its arguments are fully received.
    case toolCall(ToolCall)
    case usage(TokenUsage)
    case finished(FinishReason)
}

/// Aggregated result once a stream completes.
public struct InferenceResponse: Sendable {
    public var text: String
    public var reasoning: String
    public var toolCalls: [ToolCall]
    public var usage: TokenUsage
    public var finishReason: FinishReason

    public init(text: String = "", reasoning: String = "", toolCalls: [ToolCall] = [], usage: TokenUsage = TokenUsage(), finishReason: FinishReason = .stop) {
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
    }
}

public struct InferenceCapabilities: Hashable, Sendable {
    public var vision: Bool
    public var tools: Bool
    public var contextWindowTokens: Int
    public var maxOutputTokens: Int
    public var model: String
    public var endpoint: String

    public init(vision: Bool, tools: Bool, contextWindowTokens: Int, maxOutputTokens: Int, model: String, endpoint: String) {
        self.vision = vision
        self.tools = tools
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
        self.model = model
        self.endpoint = endpoint
    }
}

public enum InferenceError: Error, Sendable, CustomStringConvertible {
    case unreachable(String)
    case httpStatus(Int, String)
    case malformedResponse(String)
    case contextTooLarge(estimatedTokens: Int, limit: Int)
    case cancelled

    public var description: String {
        switch self {
        case .unreachable(let s): return "Inference endpoint unreachable: \(s)"
        case .httpStatus(let c, let b): return "Inference endpoint returned HTTP \(c): \(InferenceError.summarizeBody(b))"
        case .malformedResponse(let s): return "Malformed inference response: \(s)"
        case .contextTooLarge(let e, let l): return "Context of about \(e) tokens exceeds the \(l) token limit"
        case .cancelled: return "Inference cancelled"
        }
    }
}

/// The only surface the runtime uses to talk to a model. Keep endpoint specifics behind it.
public protocol InferenceProvider: Sendable {
    var capabilities: InferenceCapabilities { get }
    /// Stream a completion. Cancelling the consuming task cancels the request.
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error>
    /// Rough token estimate for budgeting. Providers may use a tokenizer or a heuristic.
    func estimateTokens(_ messages: [ModelMessage], tools: [ToolSpec]) -> Int
    /// Quick reachability check; used for status display, never blocks work.
    func healthCheck() async -> Bool
}

public extension InferenceProvider {
    /// Convenience: run a request to completion and aggregate the result.
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        var response = InferenceResponse()
        for try await chunk in stream(request) {
            switch chunk {
            case .textDelta(let t): response.text += t
            case .reasoningDelta(let r): response.reasoning += r
            case .toolCall(let c): response.toolCalls.append(c)
            case .usage(let u): response.usage = u
            case .finished(let f): response.finishReason = f
            }
        }
        return response
    }
}

/// Optional embeddings for semantic retrieval.
public protocol EmbeddingProvider: Sendable {
    /// The model's name, recorded with the vectors so a change of model re-embeds everything.
    var modelName: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingProvider {
    var modelName: String { "" }
}

extension InferenceError {
    /// Keeps error bodies readable: HTML pages (gateways, auth walls) collapse to their title, JSON and text are capped.
    static func summarizeBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") {
            if let open = lower.range(of: "<title>"), let close = lower.range(of: "</title>", range: open.upperBound ..< lower.endIndex) {
                let title = trimmed[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return "HTML page \"\(title.prefix(120))\" (a gateway or login page, not the model)" }
            }
            return "an HTML page instead of a model reply (a gateway or login page is in the way)"
        }
        let oneLine = trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(oneLine.prefix(300))
    }
}
