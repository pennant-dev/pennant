import PennantCore
import Foundation

// The Codex OAuth flow: authorization code with PKCE S256 against auth.openai.com, the code delivered to a loopback
// listener on the redirect URI registered for the Codex client (http://localhost:1455/auth/callback), the exchange
// and refresh at the token endpoint, and the import of an existing Codex CLI login. The shapes follow what the
// Codex CLI and Hermes Agent send (hermes_cli/auth_codex_browser.py, hermes_cli/auth_codex.py).

extension ChatGPTAuthManager {
    /// A sign-in in progress: what the browser was sent and what the redirect must match.
    struct PendingSignIn {
        let state: String
        let verifier: String
        let redirectURI: String
        let listener: LoopbackRedirectListener
        var timeout: Task<Void, Never>?
    }

    // MARK: Browser sign-in

    /// Starts the browser flow and returns the URL to open. The host finishes the flow itself when the browser lands
    /// on the loopback page; `account()` reports progress in `detail` and `onChange` fires at the end.
    public func beginSignIn() async throws -> URL {
        clearPending()
        let callback: @Sendable (LoopbackRedirectListener.Callback) -> Void = { [weak self] cb in
            guard let self else { return }
            Task { await self.handleRedirect(cb) }
        }
        let listener: LoopbackRedirectListener
        do {
            listener = try LoopbackRedirectListener(port: endpoints.redirectPort, path: Self.redirectPath, serverName: "ChatGPT", onCallback: callback)
        } catch {
            throw ChatGPTAuthError.signInFailed(String(describing: error))
        }
        do {
            try await listener.start()
        } catch {
            listener.stop()
            let port = endpoints.redirectPort.map(String.init) ?? "the redirect port"
            let detail = "port \(port) is busy (a Codex CLI sign-in may be running); OpenAI only redirects to that port"
            signInDetail = "Sign-in failed: \(detail)"
            throw ChatGPTAuthError.signInFailed(detail)
        }
        // The registered redirect URI says "localhost"; the listener binds 127.0.0.1.
        let redirectURI = "http://localhost:\(listener.port)\(Self.redirectPath)"
        let verifier = PKCE.randomVerifier()
        let state = PKCE.randomState()
        let url = Self.authorizeURL(endpoint: endpoints.authorize, redirectURI: redirectURI, state: state, codeChallenge: PKCE.challenge(for: verifier))
        var flow = PendingSignIn(state: state, verifier: verifier, redirectURI: redirectURI, listener: listener, timeout: nil)
        flow.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.signInTimeout))
            guard !Task.isCancelled else { return }
            await self?.signInTimedOut(state: state)
        }
        pending = flow
        signInDetail = Self.waitingDetail
        log.info("ChatGPT sign-in started; redirect \(redirectURI)", category: "chatgpt")
        return url
    }

    /// Drops a sign-in in progress, or dismisses the detail of a failed one; the stored account, if any, is untouched.
    public func cancelSignIn() async {
        guard pending != nil || signInDetail != nil else { return }
        clearPending()
        signInDetail = nil
        await notify()
    }

    /// The authorization request the Codex CLI and Hermes send: PKCE S256, the OpenID scopes with offline access,
    /// organisations in the id token, and the simplified flow that skips the workspace picker for personal accounts.
    static func authorizeURL(endpoint: URL, redirectURI: String, state: String, codeChallenge: String) -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = c.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
        ])
        c.queryItems = items
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    func handleRedirect(_ callback: LoopbackRedirectListener.Callback) async {
        guard let flow = pending else { return }
        if let error = callback.error {
            clearPending()
            let detail = callback.errorDescription.map { "\(error): \($0)" } ?? error
            await failSignIn(detail)
            return
        }
        guard let state = callback.state, state == flow.state else {
            clearPending()
            await failSignIn("the redirect did not match this sign-in (state mismatch)")
            return
        }
        guard let code = callback.code, !code.isEmpty else {
            clearPending()
            await failSignIn("the redirect carried no authorization code")
            return
        }
        // One exchange per flow: the pending record goes before the first await.
        clearPending()
        signInDetail = Self.exchangingDetail
        do {
            let tokens = try await exchangeCode(code, redirectURI: flow.redirectURI, verifier: flow.verifier)
            try store(tokens)
            signInDetail = nil
            log.info("ChatGPT account signed in (\(tokens.email ?? "no email"), plan \(tokens.plan ?? "unknown"))", category: "chatgpt")
            await notify()
        } catch {
            await failSignIn(Self.describe(error))
        }
    }

    private func failSignIn(_ detail: String) async {
        signInDetail = "Sign-in failed: \(detail)"
        log.warn("ChatGPT sign-in failed: \(detail)", category: "chatgpt")
        await notify()
    }

    func signInTimedOut(state: String) async {
        guard let flow = pending, flow.state == state else { return }
        clearPending()
        await failSignIn("timed out after \(Int(Self.signInTimeout / 60)) minutes")
    }

    func clearPending() {
        guard let flow = pending else { return }
        pending = nil
        flow.timeout?.cancel()
        flow.listener.stop()
    }

    // MARK: Token endpoint

    func exchangeCode(_ code: String, redirectURI: String, verifier: String) async throws -> ChatGPTTokens {
        let form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", Self.clientID),
            ("code_verifier", verifier),
        ]
        let json = try await tokenRequest(form, failure: ChatGPTAuthError.signInFailed)
        guard let access = json["access_token"]?.stringValue, !access.isEmpty else {
            throw ChatGPTAuthError.signInFailed("the token reply had no access_token")
        }
        return ChatGPTTokens(accessToken: access, refreshToken: json["refresh_token"]?.stringValue, idToken: json["id_token"]?.stringValue, expiresIn: json["expires_in"]?.doubleValue, source: ChatGPTTokens.pennantSource)
    }

    /// Refreshes the stored set once, however many requests ask at the same time.
    func refreshSerialised() async throws -> ChatGPTTokens {
        if let running = refreshTask { return try await running.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        return try await task.value
    }

    private func performRefresh() async throws -> ChatGPTTokens {
        guard let current = storedTokens() else { throw ChatGPTAuthError.notSignedIn }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTAuthError.refreshFailed("no refresh token; sign in again")
        }
        let form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", Self.clientID),
            ("scope", Self.refreshScope),
        ]
        do {
            let json = try await tokenRequest(form, failure: ChatGPTAuthError.refreshFailed)
            guard let access = json["access_token"]?.stringValue, !access.isEmpty else {
                throw ChatGPTAuthError.refreshFailed("the reply had no access_token")
            }
            // A reply may omit the rotated refresh token or the id token; the old ones stay valid then.
            var updated = ChatGPTTokens(
                accessToken: access,
                refreshToken: json["refresh_token"]?.stringValue ?? refreshToken,
                idToken: json["id_token"]?.stringValue ?? current.idToken,
                expiresIn: json["expires_in"]?.doubleValue,
                accountIDHint: current.accountID,
                source: current.source
            )
            if updated.email == nil { updated.email = current.email }
            if updated.plan == nil { updated.plan = current.plan }
            try store(updated)
            log.info("ChatGPT session refreshed; expires \(updated.expiresAt.map(ISO8601.format) ?? "unknown")", category: "chatgpt")
            await notify()
            return updated
        } catch {
            let detail = Self.describe(error)
            var failed = current
            failed.refreshFailure = detail
            try? store(failed)
            log.warn("ChatGPT session refresh failed: \(detail)", category: "chatgpt")
            await notify()
            throw error
        }
    }

    private func tokenRequest(_ form: [(String, String)], failure: (String) -> ChatGPTAuthError) async throws -> JSONValue {
        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(MCPOAuthClient.formEncode(form).utf8)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw failure(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw failure("no HTTP response from the token endpoint") }
        let json = (try? JSONValue.from(data)) ?? .null
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw failure("OpenAI is rate-limiting sign-in requests (HTTP 429); wait a minute and try again") }
            // OAuth shape {"error": "...", "error_description": "..."} or OpenAI's {"error": {"code", "message"}}.
            var code = "HTTP \(http.statusCode)"
            var message: String?
            if let e = json["error"]?.stringValue {
                code = e
                message = json["error_description"]?.stringValue ?? json["message"]?.stringValue
            } else if let e = json["error"], !e.isNull {
                code = e["code"]?.stringValue ?? e["type"]?.stringValue ?? code
                message = e["message"]?.stringValue
            }
            if code == "refresh_token_reused" {
                throw failure("the refresh token was already used by another client (the Codex CLI or VS Code, most likely); sign in again from Pennant")
            }
            throw failure(message.map { "\(code): \($0)" } ?? code)
        }
        guard case .object = json else { throw failure("the token endpoint did not reply with JSON") }
        return json
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? ChatGPTAuthError {
            switch e {
            case .signInFailed(let why), .refreshFailed(let why): return why
            default: return e.description
            }
        }
        if let e = error as? URLError { return e.localizedDescription }
        return String(describing: error)
    }

    // MARK: Codex CLI import

    /// Copies the Codex CLI's login (`~/.codex/auth.json`: `{"tokens": {"id_token", "access_token", "refresh_token",
    /// "account_id"}, "last_refresh": …}`) into the credential store. The file is only read. Both clients then share
    /// one refresh-token family: whichever refreshes first invalidates the other's copy, so a sign-in from Pennant is
    /// the better long-term option.
    public func importCodexLogin() async throws -> ChatGPTAccount {
        guard FileManager.default.fileExists(atPath: codexAuthFile.path) else { throw ChatGPTAuthError.codexLoginMissing }
        let data: Data
        do { data = try Data(contentsOf: codexAuthFile) } catch { throw ChatGPTAuthError.signInFailed("could not read \(codexAuthFile.path): \(error.localizedDescription)") }
        guard let json = try? JSONValue.from(data) else { throw ChatGPTAuthError.signInFailed("\(codexAuthFile.lastPathComponent) is not JSON") }
        // A Codex CLI signed in with an API key has "tokens": null.
        guard let tokens = json["tokens"], case .object = tokens, let access = tokens["access_token"]?.stringValue, !access.isEmpty else {
            throw ChatGPTAuthError.codexLoginMissing
        }
        let refresh = tokens["refresh_token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let set = ChatGPTTokens(accessToken: access, refreshToken: refresh, idToken: tokens["id_token"]?.stringValue, expiresIn: nil, accountIDHint: tokens["account_id"]?.stringValue, source: ChatGPTTokens.codexSource)
        if set.isExpired, refresh == nil {
            throw ChatGPTAuthError.signInFailed("the Codex CLI login has expired; run `codex login` again or sign in from Pennant")
        }
        clearPending()
        signInDetail = nil
        try store(set)
        log.info("ChatGPT account imported from the Codex CLI login (\(set.email ?? "no email"))", category: "chatgpt")
        await notify()
        return await account()
    }
}
