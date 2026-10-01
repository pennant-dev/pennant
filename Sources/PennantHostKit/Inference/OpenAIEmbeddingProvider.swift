import PennantCore
import Foundation

/// Embeddings over an OpenAI-compatible `/embeddings` endpoint (Ollama's `embeddinggemma`, vLLM, etc.).
public final class OpenAIEmbeddingProvider: EmbeddingProvider {
    public static let batchSize = 32

    public let config: HostConfig.Embeddings
    public var modelName: String { config.model }
    private let session: URLSession

    public init(config: HostConfig.Embeddings, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var start = 0
        while start < texts.count {
            let end = min(start + Self.batchSize, texts.count)
            vectors.append(contentsOf: try await embedBatch(Array(texts[start ..< end])))
            start = end
        }
        return vectors
    }

    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard let url = OpenAICompatibleProvider.endpointURL(base: config.baseURL, path: "embeddings") else {
            throw InferenceError.unreachable("Invalid embeddings base URL \(config.baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCodec.encode(JSONValue.object([
            "model": .string(config.model),
            "input": .array(texts.map { .string($0) }),
        ]))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw InferenceError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw InferenceError.malformedResponse("Not an HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            log.warn("Embedding request failed with HTTP \(http.statusCode)", category: "inference")
            throw InferenceError.httpStatus(http.statusCode, body)
        }
        let json = try JSONValue.from(data)
        guard let items = json["data"]?.arrayValue else { throw InferenceError.malformedResponse("Embedding response has no data array") }
        // Order by index when present; endpoints are allowed to return items out of order.
        let ordered = items.sorted { ($0["index"]?.intValue ?? 0) < ($1["index"]?.intValue ?? 0) }
        let vectors: [[Float]] = try ordered.map { item in
            guard let raw = item["embedding"]?.arrayValue else { throw InferenceError.malformedResponse("Embedding item has no vector") }
            return raw.map { Float($0.doubleValue ?? 0) }
        }
        guard vectors.count == texts.count else {
            throw InferenceError.malformedResponse("Expected \(texts.count) embeddings, received \(vectors.count)")
        }
        return vectors
    }

}
