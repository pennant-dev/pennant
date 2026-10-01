import Foundation

/// What the host knows about the ChatGPT account used for inference. Never carries tokens.
public struct ChatGPTAccount: Hashable, Codable, Sendable {
    public var signedIn: Bool
    public var email: String?
    public var accountID: String?
    /// "plus", "pro", "team", "free", … when the id token says; nil otherwise.
    public var plan: String?
    /// When the current access token expires; the host refreshes before then.
    public var expiresAt: Date?
    /// "pennant" when signed in from Pennant, "codex-cli" when imported from the Codex CLI login.
    public var source: String?
    /// Set while a browser sign-in is in progress, or after a failure.
    public var detail: String?

    public init(signedIn: Bool = false, email: String? = nil, accountID: String? = nil, plan: String? = nil, expiresAt: Date? = nil, source: String? = nil, detail: String? = nil) {
        self.signedIn = signedIn
        self.email = email
        self.accountID = accountID
        self.plan = plan
        self.expiresAt = expiresAt
        self.source = source
        self.detail = detail
    }
}

/// Models the ChatGPT backend serves to Codex clients. A static list: that backend has no models endpoint.
public struct ChatGPTModel: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var contextWindowTokens: Int
    public var supportsVision: Bool
    public init(id: String, title: String, contextWindowTokens: Int, supportsVision: Bool = true) {
        self.id = id
        self.title = title
        self.contextWindowTokens = contextWindowTokens
        self.supportsVision = supportsVision
    }
}
