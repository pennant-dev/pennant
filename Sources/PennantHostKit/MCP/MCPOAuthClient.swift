import PennantCore
import CryptoKit
import Foundation

// OAuth 2.1 for MCP servers, following the MCP authorization spec (2025-06-18 revision): protected-resource
// metadata (RFC 9728), authorization-server metadata (RFC 8414 / OpenID Discovery), dynamic client registration
// (RFC 7591), PKCE S256 (RFC 7636), resource indicators (RFC 8707), and the authorization-code and refresh-token
// grants. `MCPOAuthClient` is stateless; the manager keeps the flow state and the credential store keeps tokens.

// MARK: - PKCE

enum PKCE {
    /// Base64url without padding (RFC 4648 §5).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBytes(_ count: Int) -> Data {
        // `UInt8.random` draws from the system's cryptographic generator on Apple platforms.
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// 64 random bytes, base64url-encoded: 86 characters from the unreserved set.
    static func randomVerifier() -> String { base64URL(randomBytes(64)) }

    static func randomState() -> String { base64URL(randomBytes(32)) }

    /// `base64url(SHA256(verifier))`, the S256 transform.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

// MARK: - Models

/// RFC 9728 protected-resource metadata; only the fields Pennant uses.
struct ProtectedResourceMetadata: Codable, Sendable, Equatable {
    var resource: String?
    var authorizationServers: [String]?
    var scopesSupported: [String]?

    private enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

/// RFC 8414 / OpenID Discovery metadata; only the fields Pennant uses.
struct AuthorizationServerMetadata: Codable, Sendable, Equatable {
    var issuer: String?
    var authorizationEndpoint: String?
    var tokenEndpoint: String?
    var registrationEndpoint: String?
    var scopesSupported: [String]?
    var codeChallengeMethodsSupported: [String]?
    var tokenEndpointAuthMethodsSupported: [String]?

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }
}

/// Everything a sign-in needs to know about where to go.
struct MCPOAuthDiscovery: Sendable, Equatable {
    /// Canonical MCP server URL (RFC 8707 resource indicator).
    var resource: URL
    var authorizationServer: URL
    var authorizeEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    /// Scopes advertised by the protected resource, when any.
    var scopesSupported: [String]?
    /// Where the authorization server came from: "protected-resource metadata", "WWW-Authenticate challenge", or
    /// "MCP origin". Kept for status lines and logs.
    var authorizationServerSource: String
    /// False when no metadata document was found and the default endpoints under the AS origin are assumed.
    var metadataFound: Bool
    /// `token_endpoint_auth_methods_supported` from the AS metadata, when present.
    var tokenEndpointAuthMethodsSupported: [String]? = nil
    /// False for providers configured by hand whose APIs reject RFC 8707 `resource` (LinkedIn, Reddit, Graph).
    var sendsResource: Bool = true
    var extraAuthorizeParameters: [String: String] = [:]
    var tokenHeaders: [String: String] = [:]
    var usesPKCE: Bool = true

    /// Discovery for a provider whose endpoints are configured rather than discovered.
    static func configured(_ o: OAuthServerConfig, resource: URL?) throws -> MCPOAuthDiscovery {
        guard let authorize = URL(string: o.authorizeURL), let token = URL(string: o.tokenURL) else {
            throw MCPAuthError.discoveryFailed("the configured OAuth endpoints are not valid URLs")
        }
        return MCPOAuthDiscovery(
            resource: resource ?? token,
            authorizationServer: MCPOAuthClient.origin(authorize),
            authorizeEndpoint: authorize,
            tokenEndpoint: token,
            registrationEndpoint: nil,
            scopesSupported: nil,
            authorizationServerSource: "configured endpoints",
            metadataFound: true,
            tokenEndpointAuthMethodsSupported: o.secretInBody ? ["client_secret_post"] : nil,
            sendsResource: o.sendsResource && resource != nil,
            extraAuthorizeParameters: o.extraAuthorizeParameters,
            tokenHeaders: o.tokenHeaders,
            usesPKCE: o.usesPKCE
        )
    }
}

/// The OAuth client Pennant uses with one authorization server. Persisted under `<credentialKey>.client` so a
/// later sign-in does not register again.
struct RegisteredClient: Codable, Sendable, Equatable {
    var clientID: String
    var clientSecret: String?
    var redirectURI: String
    /// True when the client came from dynamic registration (and can be registered again if the AS forgets it).
    var dynamic: Bool
    /// True when the token endpoint wants the secret in the form body (`client_secret_post`) rather than HTTP Basic.
    var secretInBody: Bool?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case redirectURI = "redirect_uri"
        case dynamic
        case secretInBody = "secret_in_body"
    }

    static func decode(_ raw: String) -> RegisteredClient? {
        try? JSONCodec.decode(RegisteredClient.self, from: Data(raw.utf8))
    }

    func encoded() throws -> String { String(decoding: try JSONCodec.encode(self), as: UTF8.self) }

    var redirectPort: UInt16? {
        URL(string: redirectURI).flatMap { $0.port }.flatMap { UInt16(exactly: $0) }
    }
}

/// The token set stored under `MCPServerConfig.credentialKey` for OAuth servers, as JSON.
struct OAuthTokenSet: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String
    var scope: String?
    var expiresAt: Date?
    /// Remembered so a refresh does not need discovery again.
    var tokenEndpoint: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
        case expiresAt = "expires_at"
        case tokenEndpoint = "token_endpoint"
    }

    init(accessToken: String, refreshToken: String? = nil, tokenType: String = "Bearer", scope: String? = nil, expiresAt: Date? = nil, tokenEndpoint: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
        self.tokenEndpoint = tokenEndpoint
    }

    /// Parses a stored credential. A pasted token that is not JSON is not a token set (see `accessToken(from:)`).
    static func decode(_ raw: String) -> OAuthTokenSet? {
        guard raw.first == "{" else { return nil }
        return try? JSONCodec.decode(OAuthTokenSet.self, from: Data(raw.utf8))
    }

    /// The bearer token from a stored credential: the `access_token` of a token set, or the raw value when the
    /// user pasted a token.
    static func accessToken(from raw: String) -> String {
        decode(raw)?.accessToken ?? raw
    }

    func encoded() throws -> String { String(decoding: try JSONCodec.encode(self), as: UTF8.self) }

    /// True when the token expires within `seconds` from now (or has expired).
    func expires(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= seconds
    }

    var isExpired: Bool { expires(within: 0) }

    /// "Signed in · expires in 58 min", or "Signed in" when the token does not expire.
    /// The access token's public claims when it is a JWT (issuer, audience, organization, scopes, expiry), for
    /// diagnosing a server that rejects it. Never the token or its signature.
    var claimsSummary: String? {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys = ["iss", "aud", "org_id", "scope", "exp", "azp", "client_id"]
        return keys.compactMap { key in claims[key].map { "\(key)=\($0)" } }.joined(separator: " ")
    }

    func detail(now: Date = Date()) -> String {
        guard let expiresAt else { return "Signed in" }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return "Signed in · token expired" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return "Signed in · expires in under a minute" }
        if minutes < 120 { return "Signed in · expires in \(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "Signed in · expires in \(hours) h" }
        return "Signed in · expires in \(hours / 24) d"
    }
}

/// An `error` reply from the authorization server (RFC 6749 §5.2 / RFC 7591 §3.2.2).
struct OAuthServerError: Error, Sendable, CustomStringConvertible {
    var code: String
    var detail: String?
    var description: String {
        if let detail, !detail.isEmpty { return "\(code): \(detail)" }
        return code
    }
}

// MARK: - Client

struct MCPOAuthClient: Sendable {
    let session: URLSession
    static let protocolVersion = "2025-06-18"
    static let clientName = "Pennant"

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.httpAdditionalHeaders = ["User-Agent": "Pennant/\(PennantVersion.string)"]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: URLs

    /// RFC 8707 canonical form of an MCP server URL: lowercase scheme and host, default port dropped, fragment
    /// dropped, path and query kept as written (a trailing slash stays only when the URL has one).
    static func canonicalResource(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.fragment = nil
        if let port = c.port, (c.scheme == "https" && port == 443) || (c.scheme == "http" && port == 80) { c.port = nil }
        return c.url ?? url
    }

    /// `scheme://host[:port]` with no path.
    static func origin(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.path = ""
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.url ?? url
    }

    private static func pathComponent(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        return path == "/" ? "" : path
    }

    private static func wellKnown(_ base: URL, _ name: String, pathSuffix: String = "") -> URL? {
        guard var c = URLComponents(url: origin(base), resolvingAgainstBaseURL: false) else { return nil }
        c.path = "/.well-known/\(name)\(pathSuffix)"
        return c.url
    }

    /// RFC 9728 §3.1: the path-suffixed form first for servers under a path, then the origin's document.
    static func protectedResourceMetadataURLs(for serverURL: URL) -> [URL] {
        var urls: [URL] = []
        let path = pathComponent(serverURL)
        if !path.isEmpty, let u = wellKnown(serverURL, "oauth-protected-resource", pathSuffix: path) { urls.append(u) }
        if let u = wellKnown(serverURL, "oauth-protected-resource") { urls.append(u) }
        return urls
    }

    /// RFC 8414 §3.1 (path-aware) and OpenID Discovery 1.0 §4.1, in the order the MCP spec recommends.
    static func authorizationServerMetadataURLs(for asURL: URL) -> [URL] {
        var urls: [URL] = []
        let path = pathComponent(asURL)
        if !path.isEmpty {
            if let u = wellKnown(asURL, "oauth-authorization-server", pathSuffix: path) { urls.append(u) }
            if let u = wellKnown(asURL, "openid-configuration", pathSuffix: path) { urls.append(u) }
            // OpenID's path-appended form: <issuer>/.well-known/openid-configuration.
            let base = asURL.absoluteString.hasSuffix("/") ? String(asURL.absoluteString.dropLast()) : asURL.absoluteString
            if let u = URL(string: base + "/.well-known/openid-configuration") { urls.append(u) }
        } else {
            if let u = wellKnown(asURL, "oauth-authorization-server") { urls.append(u) }
            if let u = wellKnown(asURL, "openid-configuration") { urls.append(u) }
        }
        return urls
    }

    // MARK: Discovery

    /// Finds the authorization server and its endpoints for an MCP server URL.
    func discover(serverURL: URL) async throws -> MCPOAuthDiscovery {
        let resource = Self.canonicalResource(serverURL)

        // (a) Protected-resource metadata at the well-known locations.
        var prm: ProtectedResourceMetadata?
        var source = "protected-resource metadata"
        for candidate in Self.protectedResourceMetadataURLs(for: serverURL) {
            if let m: ProtectedResourceMetadata = await fetchJSON(candidate), m.authorizationServers?.isEmpty == false {
                prm = m
                break
            }
        }
        // (b) The server's own 401 challenge names its metadata document.
        if prm == nil, let url = await protectedResourceMetadataURLFromChallenge(serverURL) {
            if let m: ProtectedResourceMetadata = await fetchJSON(url), m.authorizationServers?.isEmpty == false {
                prm = m
                source = "WWW-Authenticate challenge"
            }
        }
        // (c) Otherwise the MCP origin is the authorization server.
        let asURL: URL
        if let first = prm?.authorizationServers?.first, let u = URL(string: first), u.host != nil {
            asURL = u
        } else {
            asURL = Self.origin(serverURL)
            source = "MCP origin"
        }

        var metadata: AuthorizationServerMetadata?
        for candidate in Self.authorizationServerMetadataURLs(for: asURL) {
            if let m: AuthorizationServerMetadata = await fetchJSON(candidate), m.tokenEndpoint != nil || m.authorizationEndpoint != nil {
                metadata = m
                break
            }
        }
        if let methods = metadata?.codeChallengeMethodsSupported, !methods.contains("S256") {
            throw MCPAuthError.discoveryFailed("\(asURL.host ?? asURL.absoluteString) does not support PKCE S256 (offers \(methods.joined(separator: ", ")))")
        }
        let asOrigin = Self.origin(asURL)
        func endpoint(_ value: String?, default name: String) -> URL? {
            if let value, let u = URL(string: value, relativeTo: asURL)?.absoluteURL, u.host != nil { return u }
            return asOrigin.appendingPathComponent(name)
        }
        guard let authorize = endpoint(metadata?.authorizationEndpoint, default: "authorize"),
              let token = endpoint(metadata?.tokenEndpoint, default: "token") else {
            throw MCPAuthError.discoveryFailed("no usable endpoints for \(asURL.absoluteString)")
        }
        let registration: URL? = metadata == nil ? asOrigin.appendingPathComponent("register") : metadata?.registrationEndpoint.flatMap { URL(string: $0, relativeTo: asURL)?.absoluteURL }
        return MCPOAuthDiscovery(
            resource: resource,
            authorizationServer: asURL,
            authorizeEndpoint: authorize,
            tokenEndpoint: token,
            registrationEndpoint: registration,
            scopesSupported: prm?.scopesSupported,
            authorizationServerSource: source,
            metadataFound: metadata != nil,
            tokenEndpointAuthMethodsSupported: metadata?.tokenEndpointAuthMethodsSupported
        )
    }

    /// Sends an unauthenticated `initialize` and reads `resource_metadata` from a 401's `WWW-Authenticate`.
    func protectedResourceMetadataURLFromChallenge(_ serverURL: URL) async -> URL? {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": Self.protocolVersion, "capabilities": [:], "clientInfo": ["name": Self.clientName, "version": PennantVersion.string]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 401 || http.statusCode == 403 else { return nil }
        guard let header = http.value(forHTTPHeaderField: "WWW-Authenticate") else { return nil }
        let params = Self.parseBearerChallenge(header)
        guard let raw = params["resource_metadata"], let url = URL(string: raw, relativeTo: serverURL)?.absoluteURL else { return nil }
        return url
    }

    /// Parameters of the `Bearer` challenge in a `WWW-Authenticate` header (RFC 6750 §3), keys lowercased.
    static func parseBearerChallenge(_ header: String) -> [String: String] {
        // Find the Bearer scheme (there may be other challenges in the same header).
        let scanner = header
        guard let range = scanner.range(of: "bearer", options: [.caseInsensitive]) else { return [:] }
        let rest = scanner[range.upperBound...]
        var params: [String: String] = [:]
        var i = rest.startIndex
        func skipSpaces() { while i < rest.endIndex, rest[i] == " " || rest[i] == "\t" || rest[i] == "," { i = rest.index(after: i) } }
        while true {
            skipSpaces()
            guard i < rest.endIndex else { break }
            var key = ""
            while i < rest.endIndex, rest[i] != "=", rest[i] != ",", rest[i] != " " { key.append(rest[i]); i = rest.index(after: i) }
            skipSpaces()
            guard i < rest.endIndex, rest[i] == "=" else {
                // A bare token starts another challenge scheme; stop here.
                break
            }
            i = rest.index(after: i)
            var value = ""
            if i < rest.endIndex, rest[i] == "\"" {
                i = rest.index(after: i)
                while i < rest.endIndex, rest[i] != "\"" {
                    if rest[i] == "\\", rest.index(after: i) < rest.endIndex { i = rest.index(after: i) }
                    value.append(rest[i]); i = rest.index(after: i)
                }
                if i < rest.endIndex { i = rest.index(after: i) }
            } else {
                while i < rest.endIndex, rest[i] != "," { value.append(rest[i]); i = rest.index(after: i) }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { params[key.lowercased()] = value }
        }
        return params
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Registration (RFC 7591)

    func register(at endpoint: URL, redirectURI: URL, scope: String?) async throws -> RegisteredClient {
        var body: [String: Any] = [
            "client_name": Self.clientName,
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        if let scope, !scope.isEmpty { body["scope"] = scope }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw MCPAuthError.registrationFailed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw MCPAuthError.registrationFailed("no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let code = json?["error"] as? String ?? "HTTP \(http.statusCode)"
            let detail = json?["error_description"] as? String
            throw MCPAuthError.registrationFailed(detail.map { "\(code): \($0)" } ?? code)
        }
        guard let clientID = json?["client_id"] as? String, !clientID.isEmpty else { throw MCPAuthError.registrationFailed("the reply had no client_id") }
        return RegisteredClient(clientID: clientID, clientSecret: json?["client_secret"] as? String, redirectURI: redirectURI.absoluteString, dynamic: true)
    }

    // MARK: Authorization request

    func authorizeURL(discovery: MCPOAuthDiscovery, client: RegisteredClient, redirectURI: URL, scope: String?, codeChallenge: String, state: String) throws -> URL {
        guard var c = URLComponents(url: discovery.authorizeEndpoint, resolvingAgainstBaseURL: false) else {
            throw MCPAuthError.discoveryFailed("bad authorization endpoint \(discovery.authorizeEndpoint.absoluteString)")
        }
        var items = c.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
        ])
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        if discovery.usesPKCE {
            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        items.append(URLQueryItem(name: "state", value: state))
        if discovery.sendsResource { items.append(URLQueryItem(name: "resource", value: discovery.resource.absoluteString)) }
        for (k, v) in discovery.extraAuthorizeParameters.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = items
        // URLComponents leaves "+" unescaped in query values; a scope with "+" would be read as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else { throw MCPAuthError.discoveryFailed("could not build the authorization URL") }
        return url
    }

    // MARK: Token endpoint

    func exchangeCode(tokenEndpoint: URL, code: String, redirectURI: URL, client: RegisteredClient, codeVerifier: String?, resource: URL?, headers: [String: String] = [:]) async throws -> OAuthTokenSet {
        var form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", client.clientID),
        ]
        if let codeVerifier { form.append(("code_verifier", codeVerifier)) }
        if let resource { form.append(("resource", resource.absoluteString)) }
        var set = try await tokenRequest(tokenEndpoint, form: form, client: client, headers: headers)
        set.tokenEndpoint = tokenEndpoint.absoluteString
        return set
    }

    func refresh(tokenEndpoint: URL, refreshToken: String, client: RegisteredClient, resource: URL?, scope: String?, headers: [String: String] = [:]) async throws -> OAuthTokenSet {
        var form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", client.clientID),
        ]
        if let resource { form.append(("resource", resource.absoluteString)) }
        if let scope, !scope.isEmpty { form.append(("scope", scope)) }
        var set = try await tokenRequest(tokenEndpoint, form: form, client: client, headers: headers)
        // A refresh reply may omit the refresh token; the old one stays valid then (RFC 6749 §6).
        if set.refreshToken == nil { set.refreshToken = refreshToken }
        set.tokenEndpoint = tokenEndpoint.absoluteString
        return set
    }

    private func tokenRequest(_ endpoint: URL, form: [(String, String)], client: RegisteredClient, headers: [String: String] = [:]) async throws -> OAuthTokenSet {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        var form = form
        if let secret = client.clientSecret {
            if client.secretInBody == true {
                // The server advertised only `client_secret_post` (HubSpot, for one).
                form.append(("client_secret", secret))
            } else {
                // RFC 6749 §2.3.1: form-encode both halves before base64.
                let basic = Data("\(Self.formEncode(client.clientID)):\(Self.formEncode(secret))".utf8).base64EncodedString()
                request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw MCPAuthError.tokenExchangeFailed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw MCPAuthError.tokenExchangeFailed("no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthServerError(code: json?["error"] as? String ?? "HTTP \(http.statusCode)", detail: json?["error_description"] as? String)
        }
        guard let access = json?["access_token"] as? String, !access.isEmpty else { throw MCPAuthError.tokenExchangeFailed("the reply had no access_token") }
        var expiresAt: Date?
        if let n = json?["expires_in"] as? Double { expiresAt = Date().addingTimeInterval(n) }
        else if let s = json?["expires_in"] as? String, let n = Double(s) { expiresAt = Date().addingTimeInterval(n) }
        return OAuthTokenSet(
            accessToken: access,
            refreshToken: json?["refresh_token"] as? String,
            tokenType: json?["token_type"] as? String ?? "Bearer",
            scope: json?["scope"] as? String,
            expiresAt: expiresAt
        )
    }

    // MARK: Form encoding

    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
    }

    static func formDecode(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            let key = String(k).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(k)
            let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }
}
