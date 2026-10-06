import PennantCore
import Foundation
import MCP

// Sign-in for HTTP MCP servers: API keys and pasted tokens go straight to the credential store; OAuth runs
// discovery, registration, PKCE, a loopback redirect, the code exchange, and refreshes tokens before they expire
// or when the server answers 401. Every step updates `MCPServerStatus.authState/authDetail` and publishes it.

extension MCPManager {
    /// A sign-in in progress: what the browser was sent and what the redirect must match.
    struct PendingAuth {
        let state: String
        let verifier: String
        let redirectURI: URL
        let listener: LoopbackRedirectListener
        let discovery: MCPOAuthDiscovery
        let client: RegisteredClient
        var timeout: Task<Void, Never>?
    }

    typealias AccessToken = (token: String, expiresAt: Date?)

    /// How long a browser flow may stay open.
    static let authTimeout: TimeInterval = 300
    /// Tokens closer than this to expiry are refreshed before use.
    static let refreshLeeway: TimeInterval = 60

    /// Thrown inside `connect` when the server needs credentials it does not have; the auth state says why.
    struct NeedsSignIn: Error {}

    // MARK: Public entry points

    /// Starts the OAuth flow and returns the URL to open in a browser. The host finishes the flow itself when the
    /// browser lands on the loopback redirect; `completeAuth` is for redirects captured elsewhere.
    public func beginAuth(_ id: MCPServerID) async throws -> URL {
        guard var config = statuses[id]?.config else { throw MCPAuthError.notFound }
        guard config.signsIn else { throw MCPAuthError.notHTTP }
        guard case .oauth(let scopes, let configuredClientID, let configuredSecret) = config.auth else { throw MCPAuthError.noAuthConfigured }
        let serverURL: URL? = { if case .http(let url) = config.transport { return url }; return nil }()
        await cancelPending(id)
        let key = try await ensureCredentialKey(&config)
        await setAuth(id, .authorizing, "Contacting the authorization server")

        var listener: LoopbackRedirectListener?
        do {
            let discovery: MCPOAuthDiscovery
            if let configured = config.oauthServer {
                discovery = try MCPOAuthDiscovery.configured(configured, resource: serverURL.map(MCPOAuthClient.canonicalResource))
            } else if let serverURL {
                discovery = try await oauth.discover(serverURL: serverURL)
            } else {
                throw MCPAuthError.discoveryFailed("\(config.name) has no OAuth endpoints configured")
            }
            let requested = scopes.isEmpty ? (discovery.scopesSupported ?? []) : scopes
            let scope: String? = requested.isEmpty ? nil : requested.joined(separator: " ")

            // The redirect port: the one a registered client was given, when it is still free.
            let stored = credentials.get(key + ".client").flatMap(RegisteredClient.decode)
            let callback: @Sendable (LoopbackRedirectListener.Callback) -> Void = { [weak self] cb in
                guard let self else { return }
                Task { await self.handleRedirect(id, cb) }
            }
            // A client registered by hand needs a redirect URI the user could type into the provider's console,
            // so those always use the fixed port; dynamically registered clients reuse whatever they were given.
            let hasConfiguredClient = !(configuredClientID ?? "").isEmpty
            let l: LoopbackRedirectListener
            if hasConfiguredClient {
                let fixed = try LoopbackRedirectListener(port: Self.fixedRedirectPort, hostName: config.oauthServer?.redirectHost ?? "127.0.0.1", serverName: config.name, onCallback: callback)
                do { try await fixed.start() } catch {
                    fixed.stop()
                    throw MCPAuthError.listenerFailed("port \(Self.fixedRedirectPort) is busy; the provider expects the redirect URL \(config.oauthServer?.redirectURIToRegister ?? Self.fixedRedirectURI)")
                }
                l = fixed
            } else {
                l = try await Self.startListener(preferredPort: stored?.redirectPort, serverName: config.name, onCallback: callback)
            }
            listener = l
            let redirectURI = l.redirectURI

            // Which way the token endpoint wants the secret: only when it lists the post method without Basic.
            let methods = discovery.tokenEndpointAuthMethodsSupported ?? []
            let secretInBody = config.oauthServer?.secretInBody ?? (methods.contains("client_secret_post") && !methods.contains("client_secret_basic"))
            var client: RegisteredClient
            if let configuredClientID, !configuredClientID.isEmpty {
                client = RegisteredClient(clientID: configuredClientID, clientSecret: Self.clientSecret(configuredSecret, for: config), redirectURI: redirectURI.absoluteString, dynamic: false, secretInBody: secretInBody)
            } else if let stored, stored.dynamic, stored.redirectURI == redirectURI.absoluteString {
                client = stored
            } else {
                guard let registration = discovery.registrationEndpoint else {
                    throw MCPAuthError.registrationFailed("\(discovery.authorizationServer.host ?? "the authorization server") does not offer dynamic client registration; set a client id on the server")
                }
                client = try await oauth.register(at: registration, redirectURI: redirectURI, scope: scope)
                log.info("MCP server \(config.name): registered OAuth client \(client.clientID) at \(registration.absoluteString)", category: "mcp")
            }
            if client != stored { try? credentials.set(key + ".client", value: try client.encoded()) }

            let verifier = PKCE.randomVerifier()
            let state = PKCE.randomState()
            let authorizeURL = try oauth.authorizeURL(discovery: discovery, client: client, redirectURI: redirectURI, scope: scope, codeChallenge: PKCE.challenge(for: verifier), state: state)

            var pending = PendingAuth(state: state, verifier: verifier, redirectURI: redirectURI, listener: l, discovery: discovery, client: client, timeout: nil)
            pending.timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.authTimeout))
                guard !Task.isCancelled else { return }
                await self?.authTimedOut(id, state: state)
            }
            pendingAuths[id] = pending
            await setAuth(id, .authorizing, "Waiting for you in the browser")
            log.info("MCP server \(config.name): sign-in started via \(discovery.authorizationServerSource) (\(discovery.authorizationServer.absoluteString)), redirect \(redirectURI.absoluteString)", category: "mcp")
            return authorizeURL
        } catch {
            listener?.stop()
            let detail = Self.describe(error)
            log.warn("MCP server \(config.name): sign-in could not start: \(detail)", category: "mcp")
            await setAuth(id, .failed, detail)
            throw error
        }
    }

    public func cancelAuth(_ id: MCPServerID) async {
        guard pendingAuths[id] != nil, let config = statuses[id]?.config else { return }
        clearPending(id)
        let (state, detail) = derivedAuth(for: config)
        await setAuth(id, state, detail)
    }

    /// Stores an API key, or a pasted token for an OAuth server, and reconnects.
    public func setCredential(_ id: MCPServerID, secret: String) async throws {
        guard var config = statuses[id]?.config else { throw MCPAuthError.notFound }
        guard config.signsIn else { throw MCPAuthError.notHTTP }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPAuthError.emptyCredential }
        let detail: String
        switch config.auth {
        case .none: throw MCPAuthError.noAuthConfigured
        case .apiKey: detail = "Signed in with API key"
        case .oauth: detail = "Signed in with a pasted token"
        }
        await cancelPending(id)
        let key = try await ensureCredentialKey(&config)
        try credentials.set(key, value: trimmed)
        await setAuth(id, .signedIn, detail)
        await reconnect(id)
    }

    /// Forgets the stored credentials (and the registered OAuth client) and disconnects.
    public func signOut(_ id: MCPServerID) async throws {
        guard let config = statuses[id]?.config else { throw MCPAuthError.notFound }
        await cancelPending(id)
        cancelRetry(id)
        refreshTasks[id]?.cancel()
        refreshTasks[id] = nil
        forgetCredentials(config)
        await disconnect(id)
        await setAuth(id, config.auth == .none ? .notRequired : .signedOut, nil)
        log.info("MCP server \(config.name): signed out", category: "mcp")
    }

    // MARK: Redirect handling

    /// Called by the loopback listener. Failures are reflected in the status, so nothing is thrown here.
    func handleRedirect(_ id: MCPServerID, _ callback: LoopbackRedirectListener.Callback) async {
        do { try await finishAuth(id, callback) } catch {}
    }

    func finishAuth(_ id: MCPServerID, _ callback: LoopbackRedirectListener.Callback) async throws {
        guard let pending = pendingAuths[id] else { throw MCPAuthError.notPending }
        guard let config = statuses[id]?.config, let key = config.credentialKey else {
            clearPending(id)
            throw MCPAuthError.notFound
        }
        if let error = callback.error {
            clearPending(id)
            if error == "invalid_client" || error == "unauthorized_client" { credentials.delete(key + ".client") }
            let detail = callback.errorDescription.map { "\(error): \($0)" } ?? error
            await setAuth(id, .failed, detail)
            throw MCPAuthError.authorizationDenied(detail)
        }
        guard let state = callback.state, state == pending.state else {
            clearPending(id)
            await setAuth(id, .failed, MCPAuthError.stateMismatch.description)
            throw MCPAuthError.stateMismatch
        }
        guard let code = callback.code, !code.isEmpty else {
            clearPending(id)
            await setAuth(id, .failed, "The sign-in reply had no authorization code")
            throw MCPAuthError.tokenExchangeFailed("no authorization code in the redirect")
        }
        // One exchange per flow: the pending record goes before the first await.
        clearPending(id)
        await setAuth(id, .authorizing, "Exchanging the code for tokens")
        do {
            let set = try await oauth.exchangeCode(tokenEndpoint: pending.discovery.tokenEndpoint, code: code, redirectURI: pending.redirectURI, client: pending.client, codeVerifier: pending.discovery.usesPKCE ? pending.verifier : nil, resource: pending.discovery.sendsResource ? pending.discovery.resource : nil, headers: pending.discovery.tokenHeaders)
            try credentials.set(key, value: try set.encoded())
            try await store.upsertMCPServer(config)
            await setAuth(id, .signedIn, set.detail())
            log.info("MCP server \(config.name): signed in (\(set.detail()))\(set.claimsSummary.map { "; token claims: \($0)" } ?? "")", category: "mcp")
            await reconnect(id)
        } catch {
            if let e = error as? OAuthServerError, e.code == "invalid_client" || e.code == "unauthorized_client" { credentials.delete(key + ".client") }
            let detail = Self.describe(error)
            log.warn("MCP server \(config.name): token exchange failed: \(detail)", category: "mcp")
            await setAuth(id, .failed, detail)
            throw MCPAuthError.tokenExchangeFailed(detail)
        }
    }

    func authTimedOut(_ id: MCPServerID, state: String) async {
        guard let pending = pendingAuths[id], pending.state == state else { return }
        clearPending(id)
        await setAuth(id, .failed, "Sign-in timed out after \(Int(Self.authTimeout / 60)) minutes")
    }

    func clearPending(_ id: MCPServerID) {
        guard let pending = pendingAuths.removeValue(forKey: id) else { return }
        pending.timeout?.cancel()
        pending.listener.stop()
    }

    private func cancelPending(_ id: MCPServerID) async {
        clearPending(id)
    }

    // MARK: Credentials

    func ensureCredentialKey(_ config: inout MCPServerConfig) async throws -> String {
        if let key = config.credentialKey, !key.isEmpty { return key }
        let key = "mcp-\(config.id.rawValue)"
        config.credentialKey = key
        try await store.upsertMCPServer(config)
        statuses[config.id]?.config = config
        return key
    }

    func forgetCredentials(_ config: MCPServerConfig) {
        guard let key = config.credentialKey else { return }
        credentials.delete(key)
        credentials.delete(key + ".client")
    }

    /// The secret to send for a server: the API key, or the access token of a stored OAuth token set (a pasted
    /// token is returned as is).
    func credentialLookup(_ config: MCPServerConfig) -> String? {
        guard let key = config.credentialKey, let raw = credentials.get(key) else { return nil }
        if case .oauth = config.auth { return OAuthTokenSet.accessToken(from: raw) }
        return raw
    }

    /// What the stored credentials say about a server, for `start` and `add`.
    func derivedAuth(for config: MCPServerConfig) -> (MCPAuthState, String?) {
        switch config.auth {
        case .none:
            return (.notRequired, nil)
        case .apiKey:
            guard let key = config.credentialKey, credentials.get(key) != nil else { return (.signedOut, nil) }
            return (.signedIn, "Signed in with API key")
        case .oauth:
            guard let key = config.credentialKey, let raw = credentials.get(key) else { return (.signedOut, nil) }
            guard let set = OAuthTokenSet.decode(raw) else { return (.signedIn, "Signed in with a pasted token") }
            if set.isExpired, set.refreshToken == nil { return (.expired, "Sign in again") }
            return (.signedIn, set.detail())
        }
    }

    func setAuth(_ id: MCPServerID, _ state: MCPAuthState, _ detail: String?) async {
        guard var status = statuses[id] else { return }
        status.authState = state
        status.authDetail = detail
        statuses[id] = status
        await publishStatus(id)
    }

    // MARK: Tokens for connections

    /// The bearer token to connect with, refreshed first when it is about to expire. Sets the auth state and
    /// returns nil when there is nothing usable.
    func accessTokenForConnect(_ config: MCPServerConfig) async -> AccessToken? {
        guard let key = config.credentialKey, let raw = credentials.get(key) else {
            await setAuth(config.id, .signedOut, nil)
            return nil
        }
        guard let set = OAuthTokenSet.decode(raw) else { return (raw, nil) }
        if set.expires(within: Self.refreshLeeway) {
            if set.refreshToken != nil {
                if let refreshed = await refreshAccessToken(config.id, rejected: nil) { return refreshed }
                // The refresh has set the state: refused (sign in again) or not reachable for now (still signed in).
                if set.isExpired { return nil }
            } else if set.isExpired {
                await setAuth(config.id, .expired, "Sign in again")
                return nil
            }
        }
        return (set.accessToken, set.expiresAt)
    }

    /// The current bearer token for a built-in connector's API call, refreshed first when it nears expiry. Nil when
    /// signed out; throws when the sign-in is good but couldn't be renewed just now.
    func connectorToken(_ id: MCPServerID) async throws -> String? {
        guard let config = statuses[id]?.config else { return nil }
        if let token = await accessTokenForConnect(config)?.token { return token }
        if statuses[id]?.authState == .signedIn {
            throw ConnectorAPI.Failure(status: 0, message: "Couldn't reach \(config.name) to renew the sign-in just now. The sign-in is still good; try again in a minute.")
        }
        return nil
    }

    /// Refreshes the server's token set once, however many requests ask at the same time. `rejected` is the
    /// token a 401 was for: when the store already holds a different, live one, that is returned instead.
    func refreshAccessToken(_ id: MCPServerID, rejected: String?) async -> AccessToken? {
        if let rejected, let key = statuses[id]?.config.credentialKey, let raw = credentials.get(key),
           let current = OAuthTokenSet.decode(raw), current.accessToken != rejected, !current.isExpired {
            return (current.accessToken, current.expiresAt)
        }
        if let running = refreshTasks[id] { return await running.value }
        let task = Task { await self.performRefresh(id) }
        refreshTasks[id] = task
        let result = await task.value
        if refreshTasks[id] == task { refreshTasks[id] = nil }
        return result
    }

    private func performRefresh(_ id: MCPServerID) async -> AccessToken? {
        guard let config = statuses[id]?.config, let key = config.credentialKey, let raw = credentials.get(key) else { return nil }
        guard case .oauth(_, let configuredClientID, let configuredSecret) = config.auth, config.signsIn else { return nil }
        let serverURL: URL? = { if case .http(let url) = config.transport { return url }; return nil }()
        guard let set = OAuthTokenSet.decode(raw), let refreshToken = set.refreshToken else {
            await setAuth(id, .expired, "Sign in again")
            return nil
        }
        do {
            let configured = config.oauthServer
            let sendsResource = configured.map { $0.sendsResource && serverURL != nil } ?? (serverURL != nil)
            let resource = sendsResource ? serverURL.map(MCPOAuthClient.canonicalResource) : nil
            let tokenEndpoint: URL
            if let s = set.tokenEndpoint, let u = URL(string: s) { tokenEndpoint = u }
            else if let configured, let u = URL(string: configured.tokenURL) { tokenEndpoint = u }
            else if let serverURL { tokenEndpoint = try await oauth.discover(serverURL: serverURL).tokenEndpoint }
            else { throw MCPAuthError.discoveryFailed("no token endpoint for \(config.name)") }
            let client: RegisteredClient
            if let configuredClientID, !configuredClientID.isEmpty {
                client = RegisteredClient(clientID: configuredClientID, clientSecret: Self.clientSecret(configuredSecret, for: config), redirectURI: "", dynamic: false, secretInBody: configured?.secretInBody)
            } else if let stored = credentials.get(key + ".client").flatMap(RegisteredClient.decode) {
                client = stored
            } else {
                throw MCPAuthError.registrationFailed("no OAuth client on file for this server")
            }
            let refreshed = try await oauth.refresh(tokenEndpoint: tokenEndpoint, refreshToken: refreshToken, client: client, resource: resource, scope: nil, headers: configured?.tokenHeaders ?? [:])
            try credentials.set(key, value: try refreshed.encoded())
            await setAuth(id, .signedIn, refreshed.detail())
            log.info("MCP server \(config.name): token refreshed (\(refreshed.detail()))\(refreshed.claimsSummary.map { "; token claims: \($0)" } ?? "")", category: "mcp")
            return (refreshed.accessToken, refreshed.expiresAt)
        } catch {
            if let e = error as? OAuthServerError, e.code == "invalid_client" || e.code == "unauthorized_client" { credentials.delete(key + ".client") }
            guard Self.refusedSignIn(error) else {
                // Offline, a timeout, the provider having a bad minute: the refresh token is still good, so the
                // connection stays signed in and the next use (or the connection's retry) tries again.
                log.warn("MCP server \(config.name): token refresh failed, trying again later: \(Self.describe(error))", category: "mcp")
                await setAuth(id, .signedIn, "Couldn't renew the sign-in just now; trying again")
                return nil
            }
            log.warn("MCP server \(config.name): token refresh failed: \(Self.describe(error))", category: "mcp")
            await setAuth(id, .expired, "Sign in again")
            return nil
        }
    }

    /// Whether a failed refresh means the provider refused the sign-in (revoked, expired, a client it no longer
    /// knows) rather than that it couldn't be reached or failed for a moment. Only a refusal asks to sign in again.
    static func refusedSignIn(_ error: Error) -> Bool {
        if case MCPAuthError.registrationFailed = error { return true }
        guard let e = error as? OAuthServerError else { return false }
        if e.code == "temporarily_unavailable" || e.code == "server_error" { return false }
        guard let status = e.status ?? (e.code.hasPrefix("HTTP ") ? Int(e.code.dropFirst(5)) : nil) else { return true }
        return (400 ..< 500).contains(status) && status != 408 && status != 429
    }

    func makeAuthorizer(for config: MCPServerConfig, token: String, expiresAt: Date?) -> MCPTokenAuthorizer {
        let id = config.id
        return MCPTokenAuthorizer(token: token, expiresAt: expiresAt) { [weak self] rejected in
            await self?.refreshAccessToken(id, rejected: rejected)
        }
    }

    // MARK: Helpers

    /// The redirect port for clients registered by hand, so the URI can be entered in a provider's console.
    /// The secret to send for a hand-registered client: none when blank, except for providers whose public
    /// clients still authenticate with Basic and an empty password (Reddit).
    static func clientSecret(_ configured: String?, for config: MCPServerConfig) -> String? {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return config.oauthServer?.basicAuthWithEmptySecret == true ? "" : nil
    }

    public static let fixedRedirectPort: UInt16 = 47831
    public static var fixedRedirectURI: String { "http://127.0.0.1:\(fixedRedirectPort)/callback" }

    private static func startListener(preferredPort: UInt16?, serverName: String, onCallback: @escaping @Sendable (LoopbackRedirectListener.Callback) -> Void) async throws -> LoopbackRedirectListener {
        if let preferredPort, let fixed = try? LoopbackRedirectListener(port: preferredPort, serverName: serverName, onCallback: onCallback) {
            do {
                try await fixed.start()
                return fixed
            } catch {
                fixed.stop()
            }
        }
        let ephemeral = try LoopbackRedirectListener(port: nil, serverName: serverName, onCallback: onCallback)
        try await ephemeral.start()
        return ephemeral
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? MCPAuthError { return e.description }
        if let e = error as? OAuthServerError { return e.description }
        if let e = error as? URLError { return e.localizedDescription }
        return String(describing: error)
    }
}

/// Supplies the bearer token to `HTTPClientTransport` and turns a 401 into one refresh and a retry. One instance
/// per connection; the transport serialises its calls.
final class MCPTokenAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
    typealias Refresh = @Sendable (_ rejected: String?) async -> MCPManager.AccessToken?

    let maxAuthorizationAttempts = 2
    private let lock = NSLock()
    private var token: String
    private var expiresAt: Date?
    private var lastRefreshAt: Date?
    private let refresh: Refresh

    init(token: String, expiresAt: Date?, refresh: @escaping Refresh) {
        self.token = token
        self.expiresAt = expiresAt
        self.refresh = refresh
    }

    var currentToken: String { lock.lock(); defer { lock.unlock() }; return token }

    func validateEndpointSecurity(for endpoint: URL) throws {}

    func authorizationHeader(for endpoint: URL) -> String? { "Bearer \(currentToken)" }

    /// Refreshes silently when the token is about to expire, before the transport sends.
    func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
        let expiring: Bool = {
            lock.lock(); defer { lock.unlock() }
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow <= MCPManager.refreshLeeway
        }()
        guard expiring, let fresh = await refresh(nil) else { return }
        adopt(fresh)
    }

    func handleChallenge(statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?, session: URLSession) async throws -> Bool {
        guard statusCode == 401 else { return false }
        let (rejected, last): (String, Date?) = { lock.lock(); defer { lock.unlock() }; return (token, lastRefreshAt) }()
        // A server that rejects freshly refreshed tokens gets no refresh storm.
        if let last, Date().timeIntervalSince(last) < 5 { return false }
        guard let fresh = await refresh(rejected), fresh.token != rejected else { return false }
        adopt(fresh)
        return true
    }

    private func adopt(_ fresh: MCPManager.AccessToken) {
        lock.lock()
        token = fresh.token
        expiresAt = fresh.expiresAt
        lastRefreshAt = Date()
        lock.unlock()
    }
}
