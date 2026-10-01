import PennantCore
import Foundation

/// Lets the host replace the inference provider at runtime (settings change) without restarting tasks.
public final class SwitchableProvider: InferenceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: any InferenceProvider

    public init(_ provider: any InferenceProvider) { inner = provider }

    public var current: any InferenceProvider {
        lock.lock(); defer { lock.unlock() }
        return inner
    }

    public func replace(_ provider: any InferenceProvider) {
        lock.lock(); inner = provider; lock.unlock()
    }

    public var capabilities: InferenceCapabilities { current.capabilities }
    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> { current.stream(request) }
    public func estimateTokens(_ messages: [ModelMessage], tools: [ToolSpec]) -> Int { current.estimateTokens(messages, tools: tools) }
    public func healthCheck() async -> Bool { await current.healthCheck() }
}

/// Lists the models an OpenAI-compatible endpoint serves.
public enum ModelDiscovery {
    public static func listModels(baseURL: String, apiKey: String?, timeout: TimeInterval = 8) async throws -> [ModelInfo] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/models"), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw InferenceError.unreachable("'\(baseURL)' is not an http(s) URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw InferenceError.unreachable(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw InferenceError.malformedResponse("no HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else { throw InferenceError.httpStatus(http.statusCode, String(decoding: data.prefix(400), as: UTF8.self)) }
        let json = try JSONValue.from(data)
        let items = json["data"]?.arrayValue ?? json["models"]?.arrayValue ?? json.arrayValue ?? []
        var models: [ModelInfo] = []
        for item in items {
            guard let id = item["id"]?.stringValue ?? item["name"]?.stringValue ?? item["model"]?.stringValue else { continue }
            let created = item["created"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
            models.append(ModelInfo(id: id, ownedBy: item["owned_by"]?.stringValue, created: created))
        }
        return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }
}
