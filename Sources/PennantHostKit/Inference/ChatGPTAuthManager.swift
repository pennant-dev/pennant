import PennantCore
import Foundation

/// Signs a ChatGPT account in through OpenAI's Codex OAuth flow (the one the Codex CLI uses) and keeps its tokens
/// fresh for `ChatGPTProvider`. Tokens live in the credential store under `chatgpt.tokens` as JSON; the account
/// the host reports to clients never carries them. The browser flow, the code exchange, refresh, and the Codex CLI
/// import are in ChatGPTAuthManager+Flow.swift.
public actor ChatGPTAuthManager {
    /// Where the flow talks to. Tests point these at a local server; production uses OpenAI's endpoints.
    public struct Endpoints: Sendable {
        public var authorize: URL
        public var token: URL
        public var responses: URL
        /// The loopback port the redirect URI names, or nil for an ephemeral one (tests).
        public var redirectPort: UInt16?

        public init(authorize: URL, token: URL, responses: URL, redirectPort: UInt16?) {
            self.authorize = authorize
            self.token = token
            self.responses = responses
            self.redirectPort = redirectPort
        }

        /// The endpoints Codex clients use: `auth.openai.com` for OAuth and the ChatGPT backend for completions.
        public static let production = Endpoints(
            authorize: URL(string: "https://auth.openai.com/oauth/authorize")!,
            token: URL(string: "https://auth.openai.com/oauth/token")!,
            responses: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            redirectPort: 1455
        )
    }

    /// The public OAuth client id of the Codex CLI; its registered redirect URI is `http://localhost:1455/auth/callback`.
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let scope = "openid profile email offline_access"
    /// The scope the Codex CLI asks for on refresh.
    static let refreshScope = "openid profile email"
    public static let redirectPath = "/auth/callback"
    static let tokenKey = "chatgpt.tokens"
    /// How long a browser flow may stay open.
    static let signInTimeout: TimeInterval = 300
    /// Tokens closer than this to expiry are refreshed before use.
    static let refreshLeeway: TimeInterval = 300
    static let waitingDetail = "Waiting for you in the browser"
    static let exchangingDetail = "Exchanging the code for tokens"

    let credentials: any MCPCredentialStore
    let codexAuthFile: URL
    public nonisolated let endpoints: Endpoints
    let session: URLSession
    var pending: PendingSignIn?
    /// Set while a browser sign-in is in progress, or after one failed; cleared by success, import, and sign-out.
    var signInDetail: String?
    var refreshTask: Task<ChatGPTTokens, Error>?
    var onChange: (@Sendable () async -> Void)?

    public init(credentials: any MCPCredentialStore, codexAuthFile: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json"), endpoints: Endpoints = .production, session: URLSession? = nil) {
        self.credentials = credentials
        self.codexAuthFile = codexAuthFile
        self.endpoints = endpoints
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.httpAdditionalHeaders = ["User-Agent": "pennant-host/\(PennantVersion.string)"]
            self.session = URLSession(configuration: config)
        }
    }

    /// Called after the account changes (sign-in completed or failed, import, sign-out, refresh outcome) so the host
    /// can publish its status.
    public func setOnChange(_ handler: (@Sendable () async -> Void)?) { onChange = handler }

    func notify() async { await onChange?() }

    // MARK: Account

    /// What clients may know: identity, plan, expiry, and a one-line detail when something needs the user.
    public func account() async -> ChatGPTAccount {
        guard let tokens = storedTokens() else { return ChatGPTAccount(signedIn: false, detail: signInDetail) }
        var account = tokens.account
        if let signInDetail {
            account.detail = signInDetail
        } else if let failure = tokens.refreshFailure {
            account.detail = "Session could not be refreshed (\(failure)). Sign in again."
        } else if tokens.isExpired, tokens.refreshToken == nil {
            account.detail = "Session expired. Sign in again."
        }
        return account
    }

    /// True when a request could be made without the user's help: a live access token, or a refresh token that has
    /// not been refused. No network.
    public func isUsable() -> Bool {
        guard let tokens = storedTokens() else { return false }
        if !tokens.isExpired { return true }
        return tokens.refreshToken != nil && tokens.refreshFailure == nil
    }

    /// Forgets the stored tokens and any sign-in in progress.
    public func signOut() async throws -> ChatGPTAccount {
        clearPending()
        signInDetail = nil
        refreshTask?.cancel()
        refreshTask = nil
        credentials.delete(Self.tokenKey)
        log.info("ChatGPT account signed out", category: "chatgpt")
        await notify()
        return ChatGPTAccount()
    }

    /// A valid access token and the account id, refreshing first when the token is about to expire. The account id
    /// is empty when the token carries none; the provider then omits the header.
    public func accessToken() async throws -> (token: String, accountID: String) {
        guard var tokens = storedTokens() else { throw ChatGPTAuthError.notSignedIn }
        if tokens.expires(within: Self.refreshLeeway) {
            if tokens.refreshToken != nil {
                do {
                    tokens = try await refreshSerialised()
                } catch {
                    // A token with minutes left is still good; only a dead one fails the request.
                    if tokens.isExpired { throw error }
                }
            } else if tokens.isExpired {
                throw ChatGPTAuthError.refreshFailed("the session has expired and cannot be refreshed; sign in again")
            }
        }
        return (tokens.accessToken, tokens.accountID ?? "")
    }

    /// For a 401: the token to retry with. When the store already holds a different, live token (another request
    /// refreshed meanwhile) that one is returned; otherwise the set is refreshed once.
    public func refreshAccessToken(rejected: String) async throws -> (token: String, accountID: String) {
        if let current = storedTokens(), current.accessToken != rejected, !current.isExpired {
            return (current.accessToken, current.accountID ?? "")
        }
        let tokens = try await refreshSerialised()
        return (tokens.accessToken, tokens.accountID ?? "")
    }

    /// The data-residency region the token names, for the header residency-enforced workspaces need.
    public func residency() -> String? {
        guard let tokens = storedTokens() else { return nil }
        return ChatGPTJWT.identity(idToken: tokens.idToken, accessToken: tokens.accessToken).residency
    }

    // MARK: Storage

    func storedTokens() -> ChatGPTTokens? {
        credentials.get(Self.tokenKey).flatMap(ChatGPTTokens.decode)
    }

    func store(_ tokens: ChatGPTTokens) throws {
        try credentials.set(Self.tokenKey, value: try tokens.encoded())
    }

    // MARK: Models

    /// Models the ChatGPT backend serves to Codex clients today (from the Hermes Agent and Codex catalogues; the
    /// backend's own list needs a signed-in account). The first entry is the default. Context windows are what the
    /// Codex backend enforces for a ChatGPT subscription, which is lower than the public API's for the same ids.
    public static let models: [ChatGPTModel] = [
        ChatGPTModel(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.6-terra", title: "GPT-5.6 Terra", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.6-luna", title: "GPT-5.6 Luna", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.5", title: "GPT-5.5", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.4", title: "GPT-5.4", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.4-mini", title: "GPT-5.4 mini", contextWindowTokens: 272_000),
        ChatGPTModel(id: "gpt-5.3-codex-spark", title: "GPT-5.3 Codex Spark (research preview, ChatGPT Pro)", contextWindowTokens: 128_000),
    ]

    public static func model(withID id: String) -> ChatGPTModel? {
        models.first { $0.id == id }
    }
}

public enum ChatGPTAuthError: Error, Sendable, CustomStringConvertible {
    case notImplemented
    case notSignedIn
    case codexLoginMissing
    case signInFailed(String)
    case refreshFailed(String)

    public var description: String {
        switch self {
        case .notImplemented: return "ChatGPT sign-in is not available in this build"
        case .notSignedIn: return "No ChatGPT account is signed in"
        case .codexLoginMissing: return "No Codex CLI login was found at ~/.codex/auth.json"
        case .signInFailed(let why): return "ChatGPT sign-in failed: \(why)"
        case .refreshFailed(let why): return "Could not refresh the ChatGPT session: \(why)"
        }
    }
}

// MARK: - Stored tokens

/// What the host keeps for the account, as JSON under `chatgpt.tokens`.
struct ChatGPTTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var accountID: String?
    var email: String?
    var plan: String?
    /// "pennant" for a sign-in from Pennant, "codex-cli" for an imported Codex CLI login.
    var source: String
    /// Why the last refresh was refused, until one succeeds or the user signs in again.
    var refreshFailure: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresAt = "expires_at"
        case accountID = "account_id"
        case email
        case plan
        case source
        case refreshFailure = "refresh_failure"
    }

    static let pennantSource = "pennant"
    static let codexSource = "codex-cli"

    init(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date?, accountID: String?, email: String?, plan: String?, source: String, refreshFailure: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
        self.plan = plan
        self.source = source
        self.refreshFailure = refreshFailure
    }

    /// Builds a set from a token endpoint reply (or the Codex CLI file): identity from the id token first, then
    /// the access token; expiry from the access token's `exp`, else `expires_in`.
    init(accessToken: String, refreshToken: String?, idToken: String?, expiresIn: TimeInterval?, accountIDHint: String? = nil, source: String, now: Date = Date()) {
        let identity = ChatGPTJWT.identity(idToken: idToken, accessToken: accessToken)
        var expiresAt = identity.expiresAt
        if expiresAt == nil, let expiresIn { expiresAt = now.addingTimeInterval(expiresIn) }
        self.init(accessToken: accessToken, refreshToken: refreshToken, idToken: idToken, expiresAt: expiresAt, accountID: identity.accountID ?? accountIDHint, email: identity.email, plan: identity.plan, source: source)
    }

    static func decode(_ raw: String) -> ChatGPTTokens? {
        try? JSONCodec.decode(ChatGPTTokens.self, from: Data(raw.utf8))
    }

    func encoded() throws -> String { String(decoding: try JSONCodec.encode(self), as: UTF8.self) }

    func expires(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= seconds
    }

    var isExpired: Bool { expires(within: 0) }

    var account: ChatGPTAccount {
        ChatGPTAccount(signedIn: true, email: email, accountID: accountID, plan: plan, expiresAt: expiresAt, source: source, detail: nil)
    }
}

// MARK: - JWT claims

/// Reads claims out of the JWTs OpenAI issues. No signature check: the host only needs the identity and expiry the
/// token states, and it got the token from the token endpoint itself.
enum ChatGPTJWT {
    struct Identity: Sendable, Equatable {
        var email: String?
        var accountID: String?
        var plan: String?
        var expiresAt: Date?
        var residency: String?
    }

    static let authClaim = "https://api.openai.com/auth"

    /// The payload of a JWT, or nil when the token is not one.
    static func claims(_ token: String?) -> JSONValue? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = base64URLDecode(String(parts[1])), let json = try? JSONValue.from(data), case .object = json else { return nil }
        return json
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    /// Email from the id token (falling back to the access token), account id and plan from the
    /// `https://api.openai.com/auth` claim of either, expiry from the access token's `exp`.
    static func identity(idToken: String?, accessToken: String?) -> Identity {
        let id = claims(idToken)
        let access = claims(accessToken)
        var out = Identity()
        for source in [id, access] {
            guard let source else { continue }
            if out.email == nil {
                out.email = source["email"]?.stringValue ?? source["preferred_username"]?.stringValue
            }
            if let auth = source[authClaim] {
                if out.accountID == nil { out.accountID = auth["chatgpt_account_id"]?.stringValue }
                if out.plan == nil { out.plan = auth["chatgpt_plan_type"]?.stringValue }
                if out.residency == nil {
                    out.residency = (auth["chatgpt_data_residency"]?.stringValue ?? auth["chatgpt_compute_residency"]?.stringValue)?.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if let exp = access?["exp"]?.doubleValue { out.expiresAt = Date(timeIntervalSince1970: exp) }
        if out.residency?.isEmpty == true { out.residency = nil }
        return out
    }
}
