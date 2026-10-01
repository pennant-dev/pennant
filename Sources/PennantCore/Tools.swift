import Foundation

/// Model-facing description of a tool. `inputSchema` is JSON Schema.
public struct ToolSpec: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// Whether the tool changes external state. Consequential tools are read back before retries.
    public var isConsequential: Bool
    /// Whether the tool needs the foreground desktop lease.
    public var needsDesktop: Bool
    /// Origin: "builtin", or "mcp:<server-id>".
    public var source: String
    /// Who may use it. Nil: every agent (within its allowlist).
    public var access: ToolAccess?

    public var id: String { name }

    public init(name: String, description: String, inputSchema: JSONValue, isConsequential: Bool = false, needsDesktop: Bool = false, source: String = "builtin", access: ToolAccess? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.isConsequential = isConsequential
        self.needsDesktop = needsDesktop
        self.source = source
        self.access = access
    }
}

/// Tools not every agent gets.
public enum ToolAccess: String, Hashable, Codable, Sendable {
    /// Only agents the owner granted it to (`AgentProfile.grantedTools`), e.g. the health review's tools.
    case granted
    /// No agent calls it: it only runs from an approval card the user approved (a change to an agent or a skill).
    case approvalOnly
}

public enum ToolOutcomeStatus: String, Codable, Sendable {
    /// Intent recorded, execution not yet started or not acknowledged.
    case intended
    case running
    case succeeded
    case failed
    /// The host lost track between the external action and its acknowledgement.
    case uncertain
    case cancelled
    /// Blocked by permissions, lease revocation, or policy.
    case denied
}

/// Durable record of tool intent and outcome. Runtime records, never overwritten by summaries.
public struct ToolRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: ToolRecordID
    public var taskID: TaskID
    public var agentID: AgentID
    public var call: ToolCall
    public var status: ToolOutcomeStatus
    public var resultSummary: String
    public var isError: Bool
    public var startedAt: Date
    public var finishedAt: Date?
    /// Set when the runtime reconciled an uncertain outcome by reading back target state.
    public var reconciliationNote: String?

    public init(id: ToolRecordID = ToolRecordID(), taskID: TaskID, agentID: AgentID, call: ToolCall, status: ToolOutcomeStatus = .intended, resultSummary: String = "", isError: Bool = false, startedAt: Date = Date(), finishedAt: Date? = nil, reconciliationNote: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.agentID = agentID
        self.call = call
        self.status = status
        self.resultSummary = resultSummary
        self.isError = isError
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.reconciliationNote = reconciliationNote
    }
}

/// Configuration of an MCP server owned by the host.
/// How an HTTP MCP server is authenticated. Secrets never travel in the config; they live in the host's Keychain
/// under `MCPServerConfig.credentialKey`.
public enum MCPAuth: Hashable, Codable, Sendable {
    case none
    /// A static secret sent on every request as `<header>: <prefix><secret>` (for example `Authorization: Bearer …`
    /// or `X-API-Key: …`).
    case apiKey(header: String, prefix: String)
    /// OAuth 2.1 with PKCE as described by the MCP authorization spec: metadata discovery, dynamic client
    /// registration when no client id is given, loopback redirect, refresh tokens.
    case oauth(scopes: [String], clientID: String?, clientSecret: String?)

    public static let bearerKey = MCPAuth.apiKey(header: "Authorization", prefix: "Bearer ")
    public static let oauthDefault = MCPAuth.oauth(scopes: [], clientID: nil, clientSecret: nil)

    public var label: String {
        switch self {
        case .none: return "No sign-in"
        case .apiKey: return "API key"
        case .oauth: return "OAuth"
        }
    }
}

/// Where a server stands with its credentials, for status chips and the Connect button.
public enum MCPAuthState: String, Codable, Sendable {
    /// The server needs no credentials.
    case notRequired
    /// Credentials are required and none are stored yet.
    case signedOut
    /// An OAuth flow is in progress (waiting for the browser).
    case authorizing
    case signedIn
    /// The stored token was rejected or expired and could not be refreshed.
    case expired
    case failed
}

/// The OAuth endpoints of a provider that publishes no discovery metadata (or whose metadata a generic client
/// cannot use): Microsoft Entra for Graph, LinkedIn, Reddit. When set on a server, sign-in skips discovery and
/// dynamic registration and uses these with the configured client.
public struct OAuthServerConfig: Hashable, Codable, Sendable {
    public var authorizeURL: String
    public var tokenURL: String
    /// Added to the authorization request, e.g. `duration=permanent` (Reddit) or `prompt=select_account`.
    public var extraAuthorizeParameters: [String: String]
    /// Whether to send the RFC 8707 `resource` parameter (MCP servers want it; plain APIs such as LinkedIn do not).
    public var sendsResource: Bool
    /// The secret goes in the form body (`client_secret_post`) instead of a Basic header.
    public var secretInBody: Bool
    /// Headers some token endpoints insist on (Reddit wants a descriptive User-Agent).
    public var tokenHeaders: [String: String]
    /// A public client that still authenticates with HTTP Basic and an empty password (Reddit's installed apps).
    /// Other public clients (Entra) must send no secret at all.
    public var basicAuthWithEmptySecret: Bool
    /// PKCE parameters are sent. LinkedIn's standard flow rejects them; Reddit does not document them.
    public var usesPKCE: Bool
    /// The host name in the redirect URL. Entra matches `localhost` redirects on host and path (any port), and
    /// the provider consoles are easiest to fill with `localhost`; the listener still binds 127.0.0.1.
    public var redirectHost: String?

    public init(authorizeURL: String, tokenURL: String, extraAuthorizeParameters: [String: String] = [:], sendsResource: Bool = false, secretInBody: Bool = false, tokenHeaders: [String: String] = [:], basicAuthWithEmptySecret: Bool = false, usesPKCE: Bool = true, redirectHost: String? = nil) {
        self.basicAuthWithEmptySecret = basicAuthWithEmptySecret
        self.usesPKCE = usesPKCE
        self.redirectHost = redirectHost
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.extraAuthorizeParameters = extraAuthorizeParameters
        self.sendsResource = sendsResource
        self.secretInBody = secretInBody
        self.tokenHeaders = tokenHeaders
    }

    /// Fills `{key}` placeholders (a Microsoft tenant, say).
    public func filled(_ values: [String: String]) -> OAuthServerConfig {
        func fill(_ s: String) -> String {
            var out = s
            for (k, v) in values { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
            return out
        }
        var c = self
        c.authorizeURL = fill(authorizeURL)
        c.tokenURL = fill(tokenURL)
        c.tokenHeaders = tokenHeaders.mapValues(fill)
        return c
    }

    /// The redirect URL to register in the provider's console for the host's fixed loopback port.
    public var redirectURIToRegister: String { "http://\(redirectHost ?? "127.0.0.1"):\(OAuthServerConfig.fixedRedirectPort)/callback" }
    /// Must equal the host's `MCPManager.fixedRedirectPort`.
    public static let fixedRedirectPort = 47831

    private enum CodingKeys: String, CodingKey { case authorizeURL, tokenURL, extraAuthorizeParameters, sendsResource, secretInBody, tokenHeaders, basicAuthWithEmptySecret, usesPKCE, redirectHost }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authorizeURL = try c.decode(String.self, forKey: .authorizeURL)
        tokenURL = try c.decode(String.self, forKey: .tokenURL)
        extraAuthorizeParameters = try c.decodeIfPresent([String: String].self, forKey: .extraAuthorizeParameters) ?? [:]
        sendsResource = try c.decodeIfPresent(Bool.self, forKey: .sendsResource) ?? false
        secretInBody = try c.decodeIfPresent(Bool.self, forKey: .secretInBody) ?? false
        tokenHeaders = try c.decodeIfPresent([String: String].self, forKey: .tokenHeaders) ?? [:]
        basicAuthWithEmptySecret = try c.decodeIfPresent(Bool.self, forKey: .basicAuthWithEmptySecret) ?? false
        usesPKCE = try c.decodeIfPresent(Bool.self, forKey: .usesPKCE) ?? true
        redirectHost = try c.decodeIfPresent(String.self, forKey: .redirectHost)
    }
}

public struct MCPServerConfig: Hashable, Codable, Sendable, Identifiable {
    public enum Transport: Hashable, Codable, Sendable {
        case stdio(command: String, arguments: [String], environment: [String: String])
        case http(url: URL)
        /// A connector that runs inside the host and talks to the provider's own API (Microsoft Graph, LinkedIn,
        /// Reddit), served over an in-memory MCP transport so it looks like any other server.
        case builtin(connector: String)
    }
    public var id: MCPServerID
    public var name: String
    public var transport: Transport
    public var enabled: Bool
    /// Keychain item name holding this server's secret (API key, or the OAuth token set as JSON).
    public var credentialKey: String?
    public var auth: MCPAuth
    /// The catalog entry this server was created from, when any.
    public var catalogID: String?
    public var createdAt: Date
    /// OAuth endpoints to use instead of discovery (see `OAuthServerConfig`).
    public var oauthServer: OAuthServerConfig?
    /// Values a connector needs beyond sign-in (a Microsoft tenant id, say). Never secrets.
    public var settings: [String: String]

    public init(id: MCPServerID = MCPServerID(), name: String, transport: Transport, enabled: Bool = true, credentialKey: String? = nil, auth: MCPAuth = .none, catalogID: String? = nil, createdAt: Date = Date(), oauthServer: OAuthServerConfig? = nil, settings: [String: String] = [:]) {
        self.oauthServer = oauthServer
        self.settings = settings
        self.id = id
        self.name = name
        self.transport = transport
        self.enabled = enabled
        self.credentialKey = credentialKey
        self.auth = auth
        self.catalogID = catalogID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, transport, enabled, credentialKey, auth, catalogID, createdAt, oauthServer, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MCPServerID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        transport = try c.decode(Transport.self, forKey: .transport)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        credentialKey = try c.decodeIfPresent(String.self, forKey: .credentialKey)
        // Servers saved before `auth` existed used a bearer token whenever a credential key was set.
        auth = try c.decodeIfPresent(MCPAuth.self, forKey: .auth) ?? (credentialKey == nil ? .none : .bearerKey)
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        oauthServer = try c.decodeIfPresent(OAuthServerConfig.self, forKey: .oauthServer)
        settings = try c.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
    }

    public var isHTTP: Bool { if case .http = transport { return true }; return false }
    public var isBuiltin: Bool { if case .builtin = transport { return true }; return false }
    /// HTTP and built-in servers sign in; local processes get their secrets from their environment.
    public var signsIn: Bool { !isLocalProcess }
    public var isLocalProcess: Bool { if case .stdio = transport { return true }; return false }
}

/// A server Pennant knows how to connect to: what it is, where it lives, and how it signs in.
public struct MCPCatalogEntry: Hashable, Codable, Sendable, Identifiable {
    public struct Parameter: Hashable, Codable, Sendable, Identifiable {
        public var id: String { key }
        /// Placeholder in `arguments` / `environment` values, written as `{key}`.
        public var key: String
        public var label: String
        /// "folder", "text", or "secret".
        public var kind: String
        public var placeholder: String
        public init(key: String, label: String, kind: String = "text", placeholder: String = "") {
            self.key = key; self.label = label; self.kind = kind; self.placeholder = placeholder
        }
    }

    public var id: String
    public var name: String
    public var publisher: String
    public var summary: String
    /// "Developer", "Productivity", "Data", "Web", "Design", "Business", "Local".
    public var category: String
    /// SF Symbol shown on the card.
    public var symbol: String
    /// Remote endpoint for HTTP servers.
    public var url: String?
    /// Command line for local (stdio) servers; `{key}` placeholders are filled from `parameters`.
    public var command: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var auth: MCPAuth
    public var parameters: [Parameter]
    /// Where to create an API key, when `auth` is `.apiKey`.
    public var keyHelpURL: String?
    public var docsURL: String?
    /// True when the endpoint was checked against the publisher's documentation when the catalog was written.
    public var verified: Bool
    /// Asset name of the service's own mark in the PennantUI bundle (a lowercase slug); the card falls back to `symbol` without one.
    public var brandIcon: String?
    /// The brand colour the mark is tinted with, as "#RRGGBB".
    public var brandColor: String?
    /// A second way in that the card offers beside the primary one: a pasted token when OAuth is primary, or
    /// OAuth when a token is. For a local entry it is always the remote server at `url` (see `alternate`).
    public var alternateAuth: MCPAuth?
    /// The provider has no dynamic client registration (RFC 7591): before an OAuth sign-in Connect asks for the
    /// client id and secret of an app registered in the provider's console with the host's fixed redirect URL.
    public var needsRegisteredClient: Bool
    /// A connector that runs inside the host (see `MCPServerConfig.Transport.builtin`).
    public var builtin: String?
    /// OAuth endpoints to use instead of discovery; `{key}` placeholders are filled from `parameters`.
    public var oauthServer: OAuthServerConfig?
    /// Numbered setup steps shown before sign-in (where to register the app, which permissions to add).
    public var setupSteps: [String]
    /// Whether the registered app must have a secret (LinkedIn) or has none (Entra and Reddit public clients).
    public var needsClientSecret: Bool
    /// Parameter values collected before sign-in (a tenant, a username); `makeConfig` uses them when it is given none.
    public var presetValues: [String: String] = [:]

    public init(id: String, name: String, publisher: String, summary: String, category: String, symbol: String, url: String? = nil, command: String? = nil, arguments: [String] = [], environment: [String: String] = [:], auth: MCPAuth = .none, parameters: [Parameter] = [], keyHelpURL: String? = nil, docsURL: String? = nil, verified: Bool = false, brandIcon: String? = nil, brandColor: String? = nil, alternateAuth: MCPAuth? = nil, needsRegisteredClient: Bool = false, builtin: String? = nil, oauthServer: OAuthServerConfig? = nil, setupSteps: [String] = [], needsClientSecret: Bool = true) {
        self.builtin = builtin
        self.oauthServer = oauthServer
        self.setupSteps = setupSteps
        self.needsClientSecret = needsClientSecret
        self.id = id
        self.name = name
        self.publisher = publisher
        self.summary = summary
        self.category = category
        self.symbol = symbol
        self.url = url
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.auth = auth
        self.parameters = parameters
        self.keyHelpURL = keyHelpURL
        self.docsURL = docsURL
        self.verified = verified
        self.brandIcon = brandIcon
        self.brandColor = brandColor
        self.alternateAuth = alternateAuth
        self.needsRegisteredClient = needsRegisteredClient
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, publisher, summary, category, symbol, url, command, arguments, environment, auth, parameters, keyHelpURL, docsURL, verified, brandIcon, brandColor, alternateAuth, needsRegisteredClient, builtin, oauthServer, setupSteps, needsClientSecret
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        publisher = try c.decode(String.self, forKey: .publisher)
        summary = try c.decode(String.self, forKey: .summary)
        category = try c.decode(String.self, forKey: .category)
        symbol = try c.decode(String.self, forKey: .symbol)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        arguments = try c.decode([String].self, forKey: .arguments)
        environment = try c.decode([String: String].self, forKey: .environment)
        auth = try c.decode(MCPAuth.self, forKey: .auth)
        parameters = try c.decode([Parameter].self, forKey: .parameters)
        keyHelpURL = try c.decodeIfPresent(String.self, forKey: .keyHelpURL)
        docsURL = try c.decodeIfPresent(String.self, forKey: .docsURL)
        verified = try c.decode(Bool.self, forKey: .verified)
        brandIcon = try c.decodeIfPresent(String.self, forKey: .brandIcon)
        brandColor = try c.decodeIfPresent(String.self, forKey: .brandColor)
        // Hosts older than the alternate sign-in send entries without these two.
        alternateAuth = try c.decodeIfPresent(MCPAuth.self, forKey: .alternateAuth)
        needsRegisteredClient = try c.decodeIfPresent(Bool.self, forKey: .needsRegisteredClient) ?? false
        builtin = try c.decodeIfPresent(String.self, forKey: .builtin)
        oauthServer = try c.decodeIfPresent(OAuthServerConfig.self, forKey: .oauthServer)
        setupSteps = try c.decodeIfPresent([String].self, forKey: .setupSteps) ?? []
        needsClientSecret = try c.decodeIfPresent(Bool.self, forKey: .needsClientSecret) ?? true
    }

    public var isLocal: Bool { command != nil }

    /// Builds a server config from this entry, substituting `{key}` placeholders with the given values.
    public func makeConfig(values given: [String: String] = [:]) -> MCPServerConfig? {
        let values = presetValues.merging(given) { _, new in new }
        func fill(_ s: String) -> String {
            var out = s
            for (k, v) in values { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
            return out
        }
        if let command {
            var env: [String: String] = [:]
            for (k, v) in environment { env[k] = fill(v) }
            return MCPServerConfig(name: name, transport: .stdio(command: fill(command), arguments: arguments.map(fill), environment: env), auth: auth, catalogID: id)
        }
        let settings = values.filter { key, _ in parameters.contains { $0.key == key && $0.kind != "secret" } }
        var auth = self.auth
        if case .oauth(let scopes, let clientID, let secret) = auth { auth = .oauth(scopes: scopes.map(fill), clientID: clientID, clientSecret: secret) }
        if let builtin {
            return MCPServerConfig(name: name, transport: .builtin(connector: builtin), auth: auth, catalogID: id, oauthServer: oauthServer?.filled(values), settings: settings)
        }
        guard let url, let u = URL(string: fill(url)) else { return nil }
        return MCPServerConfig(name: name, transport: .http(url: u), auth: auth, catalogID: id, oauthServer: oauthServer?.filled(values), settings: settings)
    }
}

public enum MCPConnectionState: String, Codable, Sendable {
    case disconnected, connecting, connected, failed
}

public struct MCPServerStatus: Hashable, Codable, Sendable, Identifiable {
    public var id: MCPServerID
    public var config: MCPServerConfig
    public var state: MCPConnectionState
    public var toolCount: Int
    public var lastError: String?
    public var serverInfo: String?
    public var authState: MCPAuthState
    /// One line about the credentials: "Signed in", "Token expires in 40 min", the failure reason.
    public var authDetail: String?

    public init(config: MCPServerConfig, state: MCPConnectionState = .disconnected, toolCount: Int = 0, lastError: String? = nil, serverInfo: String? = nil, authState: MCPAuthState? = nil, authDetail: String? = nil) {
        self.id = config.id
        self.config = config
        self.state = state
        self.toolCount = toolCount
        self.lastError = lastError
        self.serverInfo = serverInfo
        self.authState = authState ?? (config.auth == .none ? .notRequired : .signedOut)
        self.authDetail = authDetail
    }

    private enum CodingKeys: String, CodingKey { case id, config, state, toolCount, lastError, serverInfo, authState, authDetail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(MCPServerConfig.self, forKey: .config)
        id = try c.decodeIfPresent(MCPServerID.self, forKey: .id) ?? config.id
        state = try c.decodeIfPresent(MCPConnectionState.self, forKey: .state) ?? .disconnected
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        serverInfo = try c.decodeIfPresent(String.self, forKey: .serverInfo)
        authState = try c.decodeIfPresent(MCPAuthState.self, forKey: .authState) ?? (config.auth == .none ? .notRequired : .signedOut)
        authDetail = try c.decodeIfPresent(String.self, forKey: .authDetail)
    }
}
