import PennantCore
import Foundation

/// The models a ChatGPT account can use: the account's own list from the ChatGPT backend (`…/codex/models`, the
/// list Codex clients show), kept for a few minutes, or the built-in list when the account can't be asked.
extension ChatGPTAuthManager {
    /// What the ChatGPT backend listed for a Plus account on 2026-10-01, for when the account's own list can't be
    /// fetched. The first entry is the default. Context windows are what the backend enforces for a
    /// ChatGPT subscription, which is lower than the public API's for the same ids.
    public static let models: [ChatGPTModel] = [
        ChatGPTModel(id: "gpt-6.1-sol", title: "GPT-6.1 Sol", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-6-astra", title: "GPT-6 Astra", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-6-sol", title: "GPT-6 Sol", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-6-luna", title: "GPT-6 Luna", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.6-terra", title: "GPT-5.6 Terra", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.6-luna", title: "GPT-5.6 Luna", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.5", title: "GPT-5.5", contextWindowTokens: 272_000),
    ]

    public static func model(withID id: String) -> ChatGPTModel? {
        models.first { $0.id == id }
    }

    /// How long the account's list is reused before it is asked again.
    static let modelListLifetime: TimeInterval = 600

    /// The backend lists only the models a client of this Codex version can drive; Pennant speaks the same
    /// Responses API, so it asks at the level of the Codex release it was checked against.
    static let codexClientVersion = "0.159.0"

    /// The models this account can use, and a line saying where the list came from.
    public func availableModels() async -> (models: [ChatGPTModel], note: String) {
        guard isUsable() else { return (Self.models, "Sign in to see your account's models. This is Pennant's built-in list.") }
        if let cache = modelCache, Date().timeIntervalSince(cache.at) < Self.modelListLifetime {
            return (cache.models, Self.accountNote)
        }
        do {
            let models = try await fetchModels()
            modelCache = (Date(), models)
            return (models, Self.accountNote)
        } catch {
            return (Self.models, "Couldn't get your account's list (\(error)), so this is Pennant's built-in list.")
        }
    }

    static let accountNote = "From your ChatGPT account."

    /// Asks the backend for the account's models, refreshing the sign-in once if it is turned away.
    func fetchModels() async throws -> [ChatGPTModel] {
        var credential = try await accessToken()
        var refreshed = false
        while true {
            var components = URLComponents(url: endpoints.models, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "client_version", value: Self.codexClientVersion)]
            var request = URLRequest(url: components?.url ?? endpoints.models)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
            if !credential.accountID.isEmpty { request.setValue(credential.accountID, forHTTPHeaderField: "chatgpt-account-id") }
            request.setValue(ChatGPTProvider.originator, forHTTPHeaderField: "originator")
            if let residency = residency() { request.setValue(residency, forHTTPHeaderField: "x-openai-internal-codex-residency") }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !refreshed {
                credential = try await refreshAccessToken(rejected: credential.token)
                refreshed = true
                continue
            }
            guard (200 ..< 300).contains(status) else { throw ModelListError.status(status, Self.reason(data)) }
            let models = Self.parseModels(data)
            guard !models.isEmpty else { throw ModelListError.empty }
            return models
        }
    }

    /// The backend's list (`{"models": [...]}`, each with a `slug`), in the order it ranks them, without the ones
    /// it hides from model pickers.
    static func parseModels(_ data: Data) -> [ChatGPTModel] {
        guard let json = try? JSONValue.from(data) else { return [] }
        let items = json["models"]?.arrayValue ?? json["data"]?.arrayValue ?? json.arrayValue ?? []
        let ranked = items.enumerated().sorted { ($0.element["priority"]?.intValue ?? $0.offset, $0.offset) < ($1.element["priority"]?.intValue ?? $1.offset, $1.offset) }
        var seen = Set<String>()
        return ranked.compactMap { _, item -> ChatGPTModel? in
            guard let id = item["slug"]?.stringValue ?? item["id"]?.stringValue, !id.isEmpty, seen.insert(id).inserted else { return nil }
            if let visibility = item["visibility"]?.stringValue, visibility != "list" { return nil }
            let builtIn = model(withID: id)
            let modalities = item["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
            return ChatGPTModel(id: id,
                                title: item["display_name"]?.stringValue ?? builtIn?.title ?? id,
                                contextWindowTokens: item["context_window"]?.intValue ?? builtIn?.contextWindowTokens ?? 272_000,
                                supportsVision: modalities.map { $0.contains("image") } ?? builtIn?.supportsVision ?? true)
        }
    }

    /// The backend's own words for a refusal (`detail`, or `error.message`), kept short.
    static func reason(_ data: Data) -> String? {
        guard let json = try? JSONValue.from(data) else { return nil }
        let text = json["detail"]?.stringValue ?? json["error"]?["message"]?.stringValue ?? json["message"]?.stringValue
        return text.map { String($0.prefix(160)) }
    }

    enum ModelListError: Error, CustomStringConvertible {
        case status(Int, String?), empty
        var description: String {
            switch self {
            case .status(let code, let reason): return "HTTP \(code)" + (reason.map { ": \($0)" } ?? "")
            case .empty: return "it listed no models"
            }
        }
    }
}
