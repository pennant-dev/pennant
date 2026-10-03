import PennantCore
@testable import PennantHostKit
import CryptoKit
import Foundation
import Network
import XCTest

// MARK: - Tiny HTTP server for tests

/// A minimal HTTP/1.1 server on 127.0.0.1: one request per connection, `Connection: close`. Enough for metadata
/// documents, token endpoints, and a fake MCP endpoint.
final class TinyHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
        var query: [String: String] = [:]

        func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        var bodyString: String { String(decoding: body, as: UTF8.self) }
        var form: [String: String] { MCPOAuthClient.formDecode(bodyString) }
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Response {
            var h = headers
            h["Content-Type"] = "application/json"
            return Response(status: status, headers: h, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        static func status(_ code: Int, headers: [String: String] = [:], body: String = "") -> Response {
            Response(status: code, headers: headers, body: Data(body.utf8))
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let handler: Handler
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tiny-http")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Resumes a continuation at most once, from whichever queue reports first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
        func finish(_ error: Error?) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            guard let c else { return }
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.port = self.listener.port?.rawValue ?? 0; once.finish(nil)
                case .failed(let e): once.finish(e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock(); let open = Array(connections.values); connections.removeAll(); lock.unlock()
        for c in open { c.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(connection)] = connection; lock.unlock()
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
                let bodyStart = headerEnd.upperBound
                if buffer.count - bodyStart >= length {
                    let body = buffer[bodyStart..<(bodyStart + length)]
                    let parts = lines.first?.split(separator: " ") ?? []
                    let target = parts.count > 1 ? String(parts[1]) : "/"
                    let comps = URLComponents(string: "http://127.0.0.1" + target)
                    let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
                    let request = Request(method: parts.first.map(String.init) ?? "GET", path: comps?.path ?? target, headers: headers, body: Data(body), query: query)
                    let response = self.handler(request)
                    var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
                    for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
                    head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
                        connection.cancel()
                        self.lock.lock(); self.connections[ObjectIdentifier(connection)] = nil; self.lock.unlock()
                    })
                    return
                }
            }
            if error != nil || isComplete { connection.cancel(); return }
            self.read(connection, buffer: buffer)
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Status"
        }
    }
}

// MARK: - Fake authorization server + MCP endpoint

/// An authorization server and a protected MCP endpoint in one process. The MCP endpoint lives at `/mcp`; the
/// authorization server at `/auth` (a path, so path-aware metadata discovery is exercised).
final class FakeAuthServer: @unchecked Sendable {
    enum ProtectedResourceMode { case wellKnown, challengeOnly, none }

    private let lock = NSLock()
    private var http: TinyHTTPServer!

    // Behaviour switches (set before the request that should see them).
    var protectedResourceMode: ProtectedResourceMode = .wellKnown
    var serveAuthorizationServerMetadata = true
    var codeChallengeMethods = ["S256"]
    var offerRegistration = true
    var scopesSupported = ["read", "write"]
    var expectedCodeChallenge: String?
    var rejectRefresh = false
    var expiresIn: Double = 3600
    /// When set, the MCP endpoint wants this header instead of a bearer token.
    var apiKeyHeader: (name: String, value: String)?
    var requireAuth = true

    // State.
    private var validAccessTokens: Set<String> = []
    private var validRefreshTokens: Set<String> = []
    private var issuedCodes: [String: String] = [:]   // code → redirect URI
    private var counter = 0
    private(set) var requests: [TinyHTTPServer.Request] = []
    private(set) var registrations: [[String: Any]] = []
    private(set) var tokenRequests: [[String: String]] = []
    private(set) var mcpAuthorizationHeaders: [String?] = []
    private(set) var mcpHeaders: [[String: String]] = []

    var baseURL: URL { http.baseURL }
    var mcpURL: URL { baseURL.appendingPathComponent("mcp") }
    var authorizationServerURL: URL { baseURL.appendingPathComponent("auth") }

    func start() async throws {
        http = try TinyHTTPServer { [unowned self] request in self.handle(request) }
        try await http.start()
    }

    func stop() { http.stop() }

    func accept(accessToken: String, refreshToken: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        validAccessTokens.insert(accessToken)
        if let refreshToken { validRefreshTokens.insert(refreshToken) }
    }

    func revoke(accessToken: String) {
        lock.lock(); defer { lock.unlock() }
        validAccessTokens.remove(accessToken)
    }

    /// What the authorization server would do after the user approves in the browser.
    func issueCode(redirectURI: String) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let code = "code-\(counter)"
        issuedCodes[code] = redirectURI
        return code
    }

    var isAccessTokenValid: (String) -> Bool { { [self] t in lock.lock(); defer { lock.unlock() }; return validAccessTokens.contains(t) } }

    private func handle(_ request: TinyHTTPServer.Request) -> TinyHTTPServer.Response {
        lock.lock(); requests.append(request); lock.unlock()
        let base = baseURL.absoluteString
        switch (request.method, request.path) {
        case ("GET", "/.well-known/oauth-protected-resource/mcp"), ("GET", "/.well-known/oauth-protected-resource"):
            guard protectedResourceMode == .wellKnown else { return .status(404) }
            return .json(protectedResourceMetadata)
        case ("GET", "/prm-elsewhere"):
            return .json(protectedResourceMetadata)
        case ("GET", "/.well-known/oauth-authorization-server/auth"):
            guard serveAuthorizationServerMetadata else { return .status(404) }
            var doc: [String: Any] = [
                "issuer": base + "/auth",
                "authorization_endpoint": base + "/auth/authorize",
                "token_endpoint": base + "/auth/token",
                "scopes_supported": scopesSupported,
                "code_challenge_methods_supported": codeChallengeMethods,
                "response_types_supported": ["code"],
            ]
            if offerRegistration { doc["registration_endpoint"] = base + "/auth/register" }
            return .json(doc)
        case ("POST", "/auth/register"):
            guard offerRegistration, let body = request.json else { return .status(400) }
            lock.lock(); registrations.append(body); counter += 1; let n = counter; lock.unlock()
            return .json(["client_id": "dyn-\(n)", "client_id_issued_at": Int(Date().timeIntervalSince1970), "redirect_uris": body["redirect_uris"] ?? []], status: 201)
        case ("POST", "/auth/token"):
            return token(request)
        case ("POST", "/mcp"):
            return mcp(request)
        case ("GET", "/mcp"):
            return .status(405)
        default:
            return .status(404)
        }
    }

    private var protectedResourceMetadata: [String: Any] {
        ["resource": mcpURL.absoluteString, "authorization_servers": [authorizationServerURL.absoluteString], "scopes_supported": scopesSupported]
    }

    private func token(_ request: TinyHTTPServer.Request) -> TinyHTTPServer.Response {
        let form = request.form
        lock.lock(); tokenRequests.append(form.merging(["_authorization": request.header("Authorization") ?? ""]) { a, _ in a }); lock.unlock()
        guard request.header("Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true else { return .json(["error": "invalid_request", "error_description": "form body expected"], status: 400) }
        func issue() -> TinyHTTPServer.Response {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            let access = "access-\(counter)", refresh = "refresh-\(counter)"
            validAccessTokens.insert(access)
            validRefreshTokens.insert(refresh)
            return .json(["access_token": access, "token_type": "Bearer", "expires_in": expiresIn, "refresh_token": refresh, "scope": form["scope"] ?? scopesSupported.joined(separator: " ")])
        }
        switch form["grant_type"] {
        case "authorization_code":
            lock.lock()
            let redirect = form["code"].flatMap { issuedCodes.removeValue(forKey: $0) }
            lock.unlock()
            guard let redirect else { return .json(["error": "invalid_grant", "error_description": "unknown code"], status: 400) }
            guard form["redirect_uri"] == redirect else { return .json(["error": "invalid_grant", "error_description": "redirect_uri mismatch"], status: 400) }
            if let expected = expectedCodeChallenge {
                guard let verifier = form["code_verifier"], PKCE.challenge(for: verifier) == expected else { return .json(["error": "invalid_grant", "error_description": "PKCE verification failed"], status: 400) }
            }
            guard form["resource"] == MCPOAuthClient.canonicalResource(mcpURL).absoluteString else { return .json(["error": "invalid_target", "error_description": "resource \(form["resource"] ?? "nil")"], status: 400) }
            return issue()
        case "refresh_token":
            if rejectRefresh { return .json(["error": "invalid_grant", "error_description": "refresh token revoked"], status: 400) }
            lock.lock()
            let known = form["refresh_token"].map { validRefreshTokens.remove($0) != nil } ?? false
            lock.unlock()
            guard known else { return .json(["error": "invalid_grant", "error_description": "unknown refresh token"], status: 400) }
            return issue()
        default:
            return .json(["error": "unsupported_grant_type"], status: 400)
        }
    }

    private func mcp(_ request: TinyHTTPServer.Request) -> TinyHTTPServer.Response {
        lock.lock(); mcpAuthorizationHeaders.append(request.header("Authorization")); mcpHeaders.append(request.headers); lock.unlock()
        if requireAuth {
            if let apiKeyHeader {
                guard request.header(apiKeyHeader.name) == apiKeyHeader.value else { return .status(401, headers: ["WWW-Authenticate": "Bearer"]) }
            } else {
                let token = request.header("Authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
                guard let token, isAccessTokenValid(token) else {
                    let challenge = protectedResourceMode == .challengeOnly
                        ? "Bearer realm=\"mcp\", error=\"invalid_token\", resource_metadata=\"\(baseURL.absoluteString)/prm-elsewhere\""
                        : "Bearer realm=\"mcp\", error=\"invalid_token\""
                    return .status(401, headers: ["WWW-Authenticate": challenge])
                }
            }
        }
        guard let rpc = request.json, let method = rpc["method"] as? String else { return .status(400) }
        guard let id = rpc["id"] else { return .status(202) }   // a notification
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = (rpc["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
            result = ["protocolVersion": requested, "capabilities": ["tools": [:]], "serverInfo": ["name": "FakeMCP", "version": "1.0"]]
        case "tools/list":
            result = ["tools": []]
        default:
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no such method"]])
        }
        return .json(["jsonrpc": "2.0", "id": id, "result": result], headers: ["Mcp-Session-Id": "session-1"])
    }
}

// MARK: - Tests

final class MCPAuthTests: XCTestCase {
    var server: FakeAuthServer!
    var store: FakeStore!
    var credentials: InMemoryCredentialStore!
    var bus: EventBus!
    var manager: MCPManager!

    override func setUp() async throws {
        server = FakeAuthServer()
        try await server.start()
        store = FakeStore()
        credentials = InMemoryCredentialStore()
        bus = EventBus()
        manager = MCPManager(store: store, eventBus: bus, broker: ToolBroker(), credentials: credentials)
    }

    override func tearDown() async throws {
        await manager.stop()
        server.stop()
    }

    // MARK: Helpers

    private func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    private func status(_ id: MCPServerID) async -> MCPServerStatus? { await manager.statuses[id] }

    @discardableResult
    private func waitFor(_ id: MCPServerID, timeout: TimeInterval = 8, _ predicate: @escaping (MCPServerStatus) -> Bool) async throws -> MCPServerStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = await status(id), predicate(s) { return s }
            try await Task.sleep(for: .milliseconds(25))
        }
        let s = await status(id)
        XCTFail("Timed out waiting for status; last: state=\(s?.state.rawValue ?? "-") auth=\(s?.authState.rawValue ?? "-") detail=\(s?.authDetail ?? "-") error=\(s?.lastError ?? "-")")
        throw ToolError.timeout
    }

    /// What a browser does after the user approves: lands on the loopback redirect.
    private func browserRedirect(_ redirectURI: String, _ params: [String: String]) async throws -> (Int, String) {
        var c = URLComponents(string: redirectURI)!
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await URLSession.shared.data(from: c.url!)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func oauthConfig(name: String = "Fake", scopes: [String] = [], clientID: String? = nil, clientSecret: String? = nil, credentialKey: String? = nil, enabled: Bool = true) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .http(url: server.mcpURL), enabled: enabled, credentialKey: credentialKey, auth: .oauth(scopes: scopes, clientID: clientID, clientSecret: clientSecret))
    }

    // MARK: PKCE and URLs

    func testPKCEChallengeMatchesRFC7636() {
        // RFC 7636 appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let a = PKCE.randomVerifier(), b = PKCE.randomVerifier()
        XCTAssertEqual(a.count, 86)   // 64 bytes, base64url, no padding
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").inverted))
        XCTAssertEqual(PKCE.randomState().count, 43)
    }

    func testResourceCanonicalisation() {
        func canon(_ s: String) -> String { MCPOAuthClient.canonicalResource(URL(string: s)!).absoluteString }
        XCTAssertEqual(canon("HTTPS://Example.COM:443/mcp/#frag"), "https://example.com/mcp/")
        XCTAssertEqual(canon("https://example.com/mcp"), "https://example.com/mcp")
        XCTAssertEqual(canon("http://Host:8080/x?y=1"), "http://host:8080/x?y=1")
        XCTAssertEqual(canon("https://Example.com"), "https://example.com")
        XCTAssertEqual(canon("http://example.com:80/"), "http://example.com/")
    }

    func testWWWAuthenticateParsing() {
        let params = MCPOAuthClient.parseBearerChallenge("Bearer realm=\"mcp\", resource_metadata=\"https://x.test/.well-known/oauth-protected-resource\", error=\"invalid_token\", scope=\"a b\"")
        XCTAssertEqual(params["resource_metadata"], "https://x.test/.well-known/oauth-protected-resource")
        XCTAssertEqual(params["error"], "invalid_token")
        XCTAssertEqual(params["scope"], "a b")
        XCTAssertEqual(MCPOAuthClient.parseBearerChallenge("Basic realm=\"other\", Bearer resource_metadata=https://y.test/m")["resource_metadata"], "https://y.test/m")
        XCTAssertTrue(MCPOAuthClient.parseBearerChallenge("Basic realm=\"x\"").isEmpty)
    }

    func testMetadataURLsArePathAware() {
        let prm = MCPOAuthClient.protectedResourceMetadataURLs(for: URL(string: "https://h.test/api/mcp")!).map(\.absoluteString)
        XCTAssertEqual(prm, ["https://h.test/.well-known/oauth-protected-resource/api/mcp", "https://h.test/.well-known/oauth-protected-resource"])
        let root = MCPOAuthClient.protectedResourceMetadataURLs(for: URL(string: "https://h.test/")!).map(\.absoluteString)
        XCTAssertEqual(root, ["https://h.test/.well-known/oauth-protected-resource"])
        let asURLs = MCPOAuthClient.authorizationServerMetadataURLs(for: URL(string: "https://as.test/tenant")!).map(\.absoluteString)
        XCTAssertEqual(asURLs, ["https://as.test/.well-known/oauth-authorization-server/tenant", "https://as.test/.well-known/openid-configuration/tenant", "https://as.test/tenant/.well-known/openid-configuration"])
        XCTAssertEqual(MCPOAuthClient.authorizationServerMetadataURLs(for: URL(string: "https://as.test")!).map(\.absoluteString), ["https://as.test/.well-known/oauth-authorization-server", "https://as.test/.well-known/openid-configuration"])
    }

    // MARK: Discovery

    func testDiscoveryViaProtectedResourceMetadata() async throws {
        let d = try await MCPOAuthClient().discover(serverURL: server.mcpURL)
        XCTAssertEqual(d.authorizationServer, server.authorizationServerURL)
        XCTAssertEqual(d.authorizeEndpoint.absoluteString, server.baseURL.absoluteString + "/auth/authorize")
        XCTAssertEqual(d.tokenEndpoint.absoluteString, server.baseURL.absoluteString + "/auth/token")
        XCTAssertEqual(d.registrationEndpoint?.absoluteString, server.baseURL.absoluteString + "/auth/register")
        XCTAssertEqual(d.scopesSupported, ["read", "write"])
        XCTAssertEqual(d.resource, MCPOAuthClient.canonicalResource(server.mcpURL))
        XCTAssertEqual(d.authorizationServerSource, "protected-resource metadata")
        XCTAssertTrue(d.metadataFound)
        // The path-suffixed document is asked for first (RFC 9728 §3.1).
        XCTAssertEqual(server.requests.first?.path, "/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(server.requests.first?.header("MCP-Protocol-Version"), "2025-06-18")
    }

    func testDiscoveryViaWWWAuthenticateChallenge() async throws {
        server.protectedResourceMode = .challengeOnly
        let d = try await MCPOAuthClient().discover(serverURL: server.mcpURL)
        XCTAssertEqual(d.authorizationServerSource, "WWW-Authenticate challenge")
        XCTAssertEqual(d.authorizationServer, server.authorizationServerURL)
        XCTAssertEqual(d.tokenEndpoint.absoluteString, server.baseURL.absoluteString + "/auth/token")
        let probe = server.requests.first { $0.method == "POST" && $0.path == "/mcp" }
        XCTAssertEqual((probe?.json?["method"] as? String), "initialize")
        XCTAssertNil(probe?.header("Authorization"))
        XCTAssertTrue(server.requests.contains { $0.path == "/prm-elsewhere" })
    }

    func testDiscoveryFallsBackToOriginDefaults() async throws {
        server.protectedResourceMode = .none
        server.serveAuthorizationServerMetadata = false
        let d = try await MCPOAuthClient().discover(serverURL: server.mcpURL)
        XCTAssertEqual(d.authorizationServerSource, "MCP origin")
        XCTAssertEqual(d.authorizationServer, server.baseURL)
        XCTAssertEqual(d.authorizeEndpoint.absoluteString, server.baseURL.absoluteString + "/authorize")
        XCTAssertEqual(d.tokenEndpoint.absoluteString, server.baseURL.absoluteString + "/token")
        XCTAssertEqual(d.registrationEndpoint?.absoluteString, server.baseURL.absoluteString + "/register")
        XCTAssertFalse(d.metadataFound)
        XCTAssertNil(d.scopesSupported)
    }

    func testDiscoveryRequiresS256() async throws {
        server.codeChallengeMethods = ["plain"]
        do {
            _ = try await MCPOAuthClient().discover(serverURL: server.mcpURL)
            XCTFail("expected a discovery failure")
        } catch let e as MCPAuthError {
            guard case .discoveryFailed(let why) = e else { return XCTFail("unexpected \(e)") }
            XCTAssertTrue(why.contains("S256"), why)
        }
    }

    // MARK: Full OAuth flow

    func testBeginAuthRegistersClientAndBuildsAuthorizeURL() async throws {
        let config = oauthConfig()
        try await manager.add(config)
        var s = try await waitFor(config.id) { $0.state == .disconnected }
        XCTAssertEqual(s.authState, .signedOut)

        let url = try await manager.beginAuth(config.id)
        let q = query(url)
        XCTAssertTrue(url.absoluteString.hasPrefix(server.baseURL.absoluteString + "/auth/authorize?"))
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], "dyn-1")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["scope"], "read write")   // from scopes_supported: the config had none
        XCTAssertEqual(q["resource"], MCPOAuthClient.canonicalResource(server.mcpURL).absoluteString)
        XCTAssertEqual(q["code_challenge"]?.count, 43)
        XCTAssertEqual(q["state"]?.isEmpty, false)
        XCTAssertTrue(q["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true && q["redirect_uri"]?.hasSuffix("/callback") == true, q["redirect_uri"] ?? "nil")

        // Registration request (RFC 7591).
        XCTAssertEqual(server.registrations.count, 1)
        let reg = server.registrations[0]
        XCTAssertEqual(reg["client_name"] as? String, "Pennant")
        XCTAssertEqual(reg["redirect_uris"] as? [String], [q["redirect_uri"]!])
        XCTAssertEqual(reg["grant_types"] as? [String], ["authorization_code", "refresh_token"])
        XCTAssertEqual(reg["response_types"] as? [String], ["code"])
        XCTAssertEqual(reg["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(reg["scope"] as? String, "read write")

        s = try await waitFor(config.id) { $0.authState == .authorizing }
        XCTAssertEqual(s.authDetail, "Waiting for you in the browser")
        // The client is remembered under <credentialKey>.client and the config gained its credential key.
        let key = "mcp-\(config.id.rawValue)"
        let stored = await store.mcpServers[config.id]
        XCTAssertEqual(stored?.credentialKey, key)
        let client = try XCTUnwrap(credentials.get(key + ".client").flatMap(RegisteredClient.decode))
        XCTAssertEqual(client.clientID, "dyn-1")
        XCTAssertEqual(client.redirectURI, q["redirect_uri"])
        XCTAssertTrue(client.dynamic)
        let pending = await manager.pendingAuths.count
        XCTAssertEqual(pending, 1)
    }

    func testFullFlowSignsInStoresTokensAndConnects() async throws {
        let config = oauthConfig(name: "Fake <Server>")
        try await manager.add(config)
        let url = try await manager.beginAuth(config.id)
        let q = query(url)
        server.expectedCodeChallenge = q["code_challenge"]
        let code = server.issueCode(redirectURI: q["redirect_uri"]!)

        let (statusCode, html) = try await browserRedirect(q["redirect_uri"]!, ["code": code, "state": q["state"]!])
        XCTAssertEqual(statusCode, 200)
        XCTAssertTrue(html.contains("You are signed in to Fake &lt;Server&gt;."), html)
        XCTAssertTrue(html.contains("go back to Pennant"))

        let signedIn = try await waitFor(config.id) { $0.authState == .signedIn && $0.state == .connected }
        XCTAssertTrue(signedIn.authDetail?.hasPrefix("Signed in · expires in ") == true, signedIn.authDetail ?? "nil")
        XCTAssertEqual(signedIn.serverInfo, "FakeMCP 1.0")

        // Token exchange used the code, the verifier, the redirect URI and the resource.
        let exchange = try XCTUnwrap(server.tokenRequests.first)
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["code"], code)
        XCTAssertEqual(exchange["client_id"], "dyn-1")
        XCTAssertEqual(exchange["redirect_uri"], q["redirect_uri"])
        XCTAssertEqual(exchange["resource"], q["resource"])
        XCTAssertEqual(exchange["_authorization"], "")   // public client: no Basic auth

        // The token set is stored as JSON under the credential key.
        let key = "mcp-\(config.id.rawValue)"
        let set = try XCTUnwrap(credentials.get(key).flatMap(OAuthTokenSet.decode))
        XCTAssertTrue(set.accessToken.hasPrefix("access-"))
        XCTAssertTrue(set.refreshToken?.hasPrefix("refresh-") == true)
        XCTAssertEqual(set.tokenType, "Bearer")
        XCTAssertEqual(set.scope, "read write")
        XCTAssertEqual(set.tokenEndpoint, server.baseURL.absoluteString + "/auth/token")
        let expiresAt = try XCTUnwrap(set.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 3600, accuracy: 30)
        // Raw JSON keys as documented.
        let rawJSON = try XCTUnwrap(credentials.get(key))
        for field in ["\"access_token\"", "\"refresh_token\"", "\"token_type\"", "\"expires_at\""] { XCTAssertTrue(rawJSON.contains(field), field) }
        // The MCP endpoint saw the bearer token.
        XCTAssertTrue(server.mcpAuthorizationHeaders.contains("Bearer \(set.accessToken)"))
        let pending = await manager.pendingAuths.count
        XCTAssertEqual(pending, 0)

        // A later flow reuses the registered client and its port instead of registering again.
        let again = try await manager.beginAuth(config.id)
        XCTAssertEqual(query(again)["client_id"], "dyn-1")
        XCTAssertEqual(query(again)["redirect_uri"], q["redirect_uri"])
        XCTAssertEqual(server.registrations.count, 1)
        await manager.cancelAuth(config.id)
        let afterCancel = try await waitFor(config.id) { $0.authState == .signedIn }
        XCTAssertEqual(afterCancel.authState, .signedIn)   // the stored token still counts
    }

    func testStateMismatchFailsTheFlow() async throws {
        let config = oauthConfig()
        try await manager.add(config)
        let url = try await manager.beginAuth(config.id)
        let q = query(url)
        let code = server.issueCode(redirectURI: q["redirect_uri"]!)
        _ = try await browserRedirect(q["redirect_uri"]!, ["code": code, "state": "not-the-state"])
        let failed = try await waitFor(config.id) { $0.authState == .failed }
        XCTAssertTrue(failed.authDetail?.contains("state mismatch") == true, failed.authDetail ?? "nil")
        XCTAssertNil(credentials.get("mcp-\(config.id.rawValue)"))
        XCTAssertTrue(server.tokenRequests.isEmpty)
    }

    func testAuthorizationErrorRedirectFails() async throws {
        let config = oauthConfig()
        try await manager.add(config)
        let q = query(try await manager.beginAuth(config.id))
        let (_, html) = try await browserRedirect(q["redirect_uri"]!, ["error": "access_denied", "error_description": "User said no", "state": q["state"]!])
        XCTAssertTrue(html.contains("did not complete"), html)
        XCTAssertTrue(html.contains("User said no"))
        let failed = try await waitFor(config.id) { $0.authState == .failed }
        XCTAssertEqual(failed.authDetail, "access_denied: User said no")
    }

    func testConfiguredScopesAreAskedFor() async throws {
        let config = oauthConfig(scopes: ["read"])
        try await manager.add(config)
        let q = query(try await manager.beginAuth(config.id))
        XCTAssertEqual(q["scope"], "read")   // configured scopes win over scopes_supported
        server.expectedCodeChallenge = q["code_challenge"]
        let code = server.issueCode(redirectURI: q["redirect_uri"]!)
        _ = try await browserRedirect(q["redirect_uri"]!, ["code": code, "state": q["state"]!])
        let s = try await waitFor(config.id) { $0.authState == .signedIn && $0.state == .connected }
        XCTAssertEqual(s.authState, .signedIn)
        XCTAssertNotNil(credentials.get("mcp-\(config.id.rawValue)").flatMap(OAuthTokenSet.decode))
    }

    func testNewBeginAuthReplacesPendingFlowAndCancelRestoresState() async throws {
        let config = oauthConfig()
        try await manager.add(config)
        let first = query(try await manager.beginAuth(config.id))
        let second = query(try await manager.beginAuth(config.id))
        XCTAssertNotEqual(first["state"], second["state"])
        let pending = await manager.pendingAuths[config.id]
        XCTAssertEqual(pending?.state, second["state"])
        await manager.cancelAuth(config.id)
        let s = try await waitFor(config.id) { $0.authState == .signedOut }
        XCTAssertNil(s.authDetail)
        let none = await manager.pendingAuths.isEmpty
        XCTAssertTrue(none)
    }

    func testPreRegisteredClientUsesBasicAuthAndSkipsRegistration() async throws {
        let config = oauthConfig(clientID: "pennant-app", clientSecret: "shh")
        try await manager.add(config)
        let q = query(try await manager.beginAuth(config.id))
        XCTAssertEqual(q["client_id"], "pennant-app")
        XCTAssertTrue(server.registrations.isEmpty)
        let code = server.issueCode(redirectURI: q["redirect_uri"]!)
        _ = try await browserRedirect(q["redirect_uri"]!, ["code": code, "state": q["state"]!])
        try await waitFor(config.id) { $0.authState == .signedIn }
        let exchange = try XCTUnwrap(server.tokenRequests.first)
        XCTAssertEqual(exchange["_authorization"], "Basic " + Data("pennant-app:shh".utf8).base64EncodedString())
        XCTAssertEqual(exchange["client_id"], "pennant-app")
    }

    // MARK: Refresh

    func testRefreshesBeforeConnectingWhenAboutToExpire() async throws {
        server.accept(accessToken: "old-access", refreshToken: "old-refresh")
        let key = "k1"
        let set = OAuthTokenSet(accessToken: "old-access", refreshToken: "old-refresh", scope: "read", expiresAt: Date().addingTimeInterval(30), tokenEndpoint: server.baseURL.absoluteString + "/auth/token")
        try credentials.set(key, value: try set.encoded())
        try credentials.set(key + ".client", value: try RegisteredClient(clientID: "dyn-9", clientSecret: nil, redirectURI: "http://127.0.0.1:1/callback", dynamic: true).encoded())
        let config = oauthConfig(credentialKey: key)
        try await manager.add(config)
        let s = try await waitFor(config.id) { $0.state == .connected }
        XCTAssertEqual(s.authState, .signedIn)
        let refresh = try XCTUnwrap(server.tokenRequests.first)
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["refresh_token"], "old-refresh")
        XCTAssertEqual(refresh["client_id"], "dyn-9")
        XCTAssertEqual(refresh["resource"], MCPOAuthClient.canonicalResource(server.mcpURL).absoluteString)
        // Rotated tokens are stored; the connection used the new one; no discovery was needed.
        let rotated = try XCTUnwrap(credentials.get(key).flatMap(OAuthTokenSet.decode))
        XCTAssertNotEqual(rotated.accessToken, "old-access")
        XCTAssertNotEqual(rotated.refreshToken, "old-refresh")
        XCTAssertTrue(rotated.refreshToken?.hasPrefix("refresh-") == true)
        XCTAssertEqual(server.mcpAuthorizationHeaders.last, "Bearer \(rotated.accessToken)")
        XCTAssertFalse(server.requests.contains { $0.path.hasPrefix("/.well-known") })
    }

    func testRefreshOn401DuringSession() async throws {
        server.accept(accessToken: "live-access", refreshToken: "live-refresh")
        let key = "k2"
        let set = OAuthTokenSet(accessToken: "live-access", refreshToken: "live-refresh", expiresAt: Date().addingTimeInterval(3600), tokenEndpoint: server.baseURL.absoluteString + "/auth/token")
        try credentials.set(key, value: try set.encoded())
        let config = oauthConfig(clientID: "pennant-app", credentialKey: key)
        try await manager.add(config)
        try await waitFor(config.id) { $0.state == .connected }
        XCTAssertTrue(server.tokenRequests.isEmpty)

        // The server drops the token; the next request gets a 401, one refresh, and a retry.
        server.revoke(accessToken: "live-access")
        let connection = await manager.connections[config.id]
        let client = try XCTUnwrap(connection?.client)
        let (tools, _) = try await client.listTools()
        XCTAssertTrue(tools.isEmpty)
        XCTAssertEqual(server.tokenRequests.count, 1)
        XCTAssertEqual(server.tokenRequests[0]["grant_type"], "refresh_token")
        XCTAssertEqual(server.tokenRequests[0]["refresh_token"], "live-refresh")
        let rotated = try XCTUnwrap(credentials.get(key).flatMap(OAuthTokenSet.decode))
        XCTAssertNotEqual(rotated.accessToken, "live-access")
        XCTAssertEqual(server.mcpAuthorizationHeaders.last, "Bearer \(rotated.accessToken)")
        let s = try await waitFor(config.id) { $0.authState == .signedIn }
        XCTAssertTrue(s.authDetail?.hasPrefix("Signed in · expires in") == true)
    }

    func testRefreshFailureMarksExpired() async throws {
        server.rejectRefresh = true
        let key = "k3"
        let set = OAuthTokenSet(accessToken: "dead-access", refreshToken: "dead-refresh", expiresAt: Date().addingTimeInterval(-10), tokenEndpoint: server.baseURL.absoluteString + "/auth/token")
        try credentials.set(key, value: try set.encoded())
        let config = oauthConfig(clientID: "pennant-app", credentialKey: key)
        try await manager.add(config)
        let s = try await waitFor(config.id) { $0.authState == .expired }
        XCTAssertEqual(s.authDetail, "Sign in again")
        XCTAssertEqual(s.state, .disconnected)
        XCTAssertTrue(server.mcpAuthorizationHeaders.isEmpty)   // never tried the dead token
    }

    // MARK: API keys and pasted tokens

    func testAPIKeySetAndSignOut() async throws {
        server.apiKeyHeader = ("X-API-Key", "k-123")
        let config = MCPServerConfig(name: "Keyed", transport: .http(url: server.mcpURL), auth: .apiKey(header: "X-API-Key", prefix: ""))
        try await manager.add(config)
        var s = try await waitFor(config.id) { $0.state == .disconnected }
        XCTAssertEqual(s.authState, .signedOut)

        try await manager.setCredential(config.id, secret: "  k-123\n")
        s = try await waitFor(config.id) { $0.state == .connected }
        XCTAssertEqual(s.authState, .signedIn)
        XCTAssertEqual(s.authDetail, "Signed in with API key")
        let key = "mcp-\(config.id.rawValue)"
        XCTAssertEqual(credentials.get(key), "k-123")
        let persisted = await store.mcpServers[config.id]
        XCTAssertEqual(persisted?.credentialKey, key)
        XCTAssertEqual(server.mcpHeaders.last?["X-API-Key"], "k-123")
        XCTAssertNil(server.mcpHeaders.last?["Authorization"])

        try await manager.signOut(config.id)
        s = try await waitFor(config.id) { $0.authState == .signedOut }
        XCTAssertEqual(s.state, .disconnected)
        XCTAssertNil(s.authDetail)
        XCTAssertNil(credentials.get(key))
        XCTAssertNil(credentials.get(key + ".client"))
        let tools = await manager.connections[config.id]
        XCTAssertNil(tools)
    }

    func testPastedTokenForOAuthServer() async throws {
        server.accept(accessToken: "pasted-token")
        let config = oauthConfig()
        try await manager.add(config)
        try await manager.setCredential(config.id, secret: "pasted-token")
        let s = try await waitFor(config.id) { $0.state == .connected }
        XCTAssertEqual(s.authState, .signedIn)
        XCTAssertEqual(s.authDetail, "Signed in with a pasted token")
        let stored = await manager.statuses[config.id]!.config
        let looked = await manager.credentialLookup(stored)
        XCTAssertEqual(looked, "pasted-token")
        XCTAssertEqual(server.mcpAuthorizationHeaders.last, "Bearer pasted-token")
        // Setting a key on a server without a sign-in method is refused.
        let open = MCPServerConfig(name: "Open", transport: .http(url: server.mcpURL), enabled: false)
        try await manager.add(open)
        do {
            try await manager.setCredential(open.id, secret: "x")
            XCTFail("expected noAuthConfigured")
        } catch let e as MCPAuthError {
            guard case .noAuthConfigured = e else { return XCTFail("unexpected \(e)") }
        }
    }

    func testStartDerivesAuthStateFromStoredCredentials() async throws {
        let open = MCPServerConfig(name: "A open", transport: .http(url: server.mcpURL), enabled: false)
        let keyed = MCPServerConfig(name: "B keyed", transport: .http(url: server.mcpURL), enabled: false, credentialKey: "kb", auth: .bearerKey)
        let expired = MCPServerConfig(name: "C expired", transport: .http(url: server.mcpURL), enabled: false, credentialKey: "kc", auth: .oauthDefault)
        let fresh = MCPServerConfig(name: "D fresh", transport: .http(url: server.mcpURL), enabled: false, credentialKey: "kd", auth: .oauthDefault)
        let signedOut = MCPServerConfig(name: "E out", transport: .http(url: server.mcpURL), enabled: false, auth: .oauthDefault)
        let pasted = MCPServerConfig(name: "F pasted", transport: .http(url: server.mcpURL), enabled: false, credentialKey: "kf", auth: .oauthDefault)
        for c in [open, keyed, expired, fresh, signedOut, pasted] { try await store.upsertMCPServer(c) }
        try credentials.set("kb", value: "secret")
        try credentials.set("kc", value: try OAuthTokenSet(accessToken: "x", expiresAt: Date().addingTimeInterval(-60)).encoded())
        try credentials.set("kd", value: try OAuthTokenSet(accessToken: "y", refreshToken: "r", expiresAt: Date().addingTimeInterval(3 * 3600)).encoded())
        try credentials.set("kf", value: "raw-token")

        await manager.start()
        let statuses = await manager.allStatuses()
        let byName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.config.name, $0) })
        XCTAssertEqual(byName["A open"]?.authState, .notRequired)
        XCTAssertEqual(byName["B keyed"]?.authState, .signedIn)
        XCTAssertEqual(byName["B keyed"]?.authDetail, "Signed in with API key")
        XCTAssertEqual(byName["C expired"]?.authState, .expired)
        XCTAssertEqual(byName["C expired"]?.authDetail, "Sign in again")
        XCTAssertEqual(byName["D fresh"]?.authState, .signedIn)
        XCTAssertEqual(byName["D fresh"]?.authDetail, "Signed in · expires in 3 h")
        XCTAssertEqual(byName["E out"]?.authState, .signedOut)
        XCTAssertEqual(byName["F pasted"]?.authState, .signedIn)
        XCTAssertEqual(byName["F pasted"]?.authDetail, "Signed in with a pasted token")
        // Every published status carries the auth fields.
        let events = await store.events
        let published = events.compactMap { if case .mcpServerStatus(let s) = $0.payload { return s } else { return nil } }
        XCTAssertTrue(published.isEmpty)   // disabled servers are not connected, so nothing was published
    }

    func testStatusEventsCarryAuthState() async throws {
        let stream = await bus.subscribe()
        let config = oauthConfig()
        try await manager.add(config)
        var seen: [(MCPAuthState, String?)] = []
        for await event in stream {
            guard case .mcpServerStatus(let s) = event.payload, s.id == config.id else { continue }
            seen.append((s.authState, s.authDetail))
            if s.state == .disconnected && s.authState == .signedOut { break }
        }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0.0 == .signedOut })
    }

    func testRemoveForgetsCredentials() async throws {
        let key = "k-remove"
        try credentials.set(key, value: "v")
        try credentials.set(key + ".client", value: "{}")
        let config = MCPServerConfig(name: "Gone", transport: .http(url: server.mcpURL), enabled: false, credentialKey: key, auth: .bearerKey)
        try await manager.add(config)
        try await manager.remove(config.id)
        XCTAssertNil(credentials.get(key))
        XCTAssertNil(credentials.get(key + ".client"))
        let gone = await store.mcpServers[config.id]
        XCTAssertNil(gone)
    }

    // MARK: Loopback listener

    /// A locked value the listener's queue can append to while the test awaits.
    private final class Recorder<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    func testLoopbackListenerServesPageAndCapturesParametersOnce() async throws {
        let callbacks = Recorder<LoopbackRedirectListener.Callback>()
        let listener = try LoopbackRedirectListener(port: nil, serverName: "Fake <Server>") { cb in callbacks.append(cb) }
        try await listener.start()
        defer { listener.stop() }
        XCTAssertGreaterThan(listener.port, 0)
        XCTAssertEqual(listener.redirectURI.absoluteString, "http://127.0.0.1:\(listener.port)/callback")

        let (favicon, faviconResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.port)/favicon.ico")!)
        XCTAssertEqual((faviconResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertFalse(favicon.isEmpty)

        let (page, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.port)/callback?code=abc&state=xyz")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("You are signed in to Fake &lt;Server&gt;."), html)

        let (again, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.port)/callback?code=second&state=xyz")!)
        XCTAssertTrue(String(decoding: again, as: UTF8.self).contains("already completed"))

        XCTAssertEqual(callbacks.all, [LoopbackRedirectListener.Callback(code: "abc", state: "xyz")])

        // A fixed port can be reused after the listener stops (a registered client keeps its redirect URI).
        let port = listener.port
        listener.stop()
        try await Task.sleep(for: .milliseconds(50))
        let second = try LoopbackRedirectListener(port: port, serverName: "x") { _ in }
        try await second.start()
        XCTAssertEqual(second.port, port)
        second.stop()
    }

    func testTokenSetDetailAndExpiry() {
        let now = Date()
        XCTAssertEqual(OAuthTokenSet(accessToken: "a").detail(now: now), "Signed in")
        XCTAssertEqual(OAuthTokenSet(accessToken: "a", expiresAt: now.addingTimeInterval(58 * 60)).detail(now: now), "Signed in · expires in 58 min")
        XCTAssertEqual(OAuthTokenSet(accessToken: "a", expiresAt: now.addingTimeInterval(3 * 86400)).detail(now: now), "Signed in · expires in 3 d")
        XCTAssertTrue(OAuthTokenSet(accessToken: "a", expiresAt: now.addingTimeInterval(30)).expires(within: 60, now: now))
        XCTAssertFalse(OAuthTokenSet(accessToken: "a", expiresAt: now.addingTimeInterval(120)).expires(within: 60, now: now))
        XCTAssertFalse(OAuthTokenSet(accessToken: "a").expires(within: 60, now: now))
        XCTAssertNil(OAuthTokenSet.decode("raw-token"))
        XCTAssertEqual(OAuthTokenSet.accessToken(from: "raw-token"), "raw-token")
        let json = "{\"access_token\":\"t\",\"token_type\":\"Bearer\",\"expires_at\":\"2030-01-01T00:00:00Z\"}"
        XCTAssertEqual(OAuthTokenSet.decode(json)?.accessToken, "t")
        XCTAssertEqual(OAuthTokenSet.accessToken(from: json), "t")
    }
}
