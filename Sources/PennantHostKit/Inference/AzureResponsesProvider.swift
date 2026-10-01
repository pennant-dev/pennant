import PennantCore
import Foundation

/// Inference through the Responses API of an Azure AI Foundry resource (`<resource>/openai/v1/responses`), signed in
/// with the same Entra token (or key) as the resource's Chat Completions endpoint. GPT-6 on Azure only calls tools
/// while reasoning through this API. The request body, event stream and reasoning replay are the ones the ChatGPT
/// provider uses; what differs is the credential, the address and the headers.
public final class AzureResponsesProvider: InferenceProvider, Sendable {
    public let config: HostConfig.Inference
    public let capabilities: InferenceCapabilities
    let authority: any EndpointAuthority
    let session: URLSession
    /// Folded into the prompt cache key; one per provider instance.
    let sessionID: String
    let replay: ReasoningReplayCache

    public init(config: HostConfig.Inference, authority: any EndpointAuthority, session: URLSession = .shared) {
        self.config = config
        self.authority = authority
        self.session = session
        self.sessionID = UUID().uuidString.lowercased()
        self.replay = ReasoningReplayCache()
        self.capabilities = InferenceCapabilities(vision: config.supportsVision, tools: true, contextWindowTokens: config.contextWindowTokens,
                                                  maxOutputTokens: config.maxOutputTokens, model: config.model, endpoint: config.baseURL)
    }

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

    /// The resource answers `GET /models` with the credential.
    public func healthCheck() async -> Bool {
        guard let credential = try? await authority.credential(), let url = OpenAICompatibleProvider.endpointURL(base: credential.baseURL, path: "models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        Self.apply(credential, to: &req)
        guard let (_, response) = try? await session.data(for: req), let http = response as? HTTPURLResponse else { return false }
        return (200 ..< 300).contains(http.statusCode)
    }

    static func apply(_ credential: EndpointCredential, to request: inout URLRequest) {
        for (name, value) in credential.headers { request.setValue(value, forHTTPHeaderField: name) }
        if !credential.bearer.isEmpty { request.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization") }
    }

    private func run(request: InferenceRequest, continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation) async throws {
        var credential = try await authority.credential()
        var attempt = 0
        var replayReasoning = true
        while true {
            guard let url = OpenAICompatibleProvider.endpointURL(base: credential.baseURL, path: "responses") else { throw InferenceError.unreachable("Bad endpoint \(credential.baseURL)") }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = config.requestTimeout > 0 ? config.requestTimeout : 300
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("pennant-host/\(PennantVersion.string)", forHTTPHeaderField: "User-Agent")
            Self.apply(credential, to: &urlRequest)
            urlRequest.httpBody = try JSONCodec.encode(ChatGPTProvider.requestBody(for: request, config: config, replay: replay, replayReasoning: replayReasoning, cacheScope: sessionID))

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
                if authority.shouldRetry(status: http.statusCode, body: text, attempt: attempt) {
                    attempt += 1
                    credential = try await authority.refreshCredential(rejected: credential)
                    continue
                }
                if http.statusCode == 400, replayReasoning, text.lowercased().contains("encrypted_content") {
                    replayReasoning = false
                    replay.clear()
                    log.warn("Azure refused replayed reasoning; retrying without it", category: "inference")
                    continue
                }
                if OpenAICompatibleProvider.looksLikeContextOverflow(text) {
                    throw InferenceError.contextTooLarge(estimatedTokens: TokenEstimator.tokens(for: request.messages, tools: request.tools),
                                                         limit: OpenAICompatibleProvider.contextLimit(from: text) ?? capabilities.contextWindowTokens)
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
