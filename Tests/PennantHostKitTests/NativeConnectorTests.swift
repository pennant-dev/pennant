import PennantCore
@testable import PennantHostKit
import Foundation
import MCP
import XCTest

// MARK: - A URLProtocol stub for the providers' APIs

/// Intercepts requests to the real API hosts (graph.microsoft.com, api.linkedin.com, oauth.reddit.com) so connector
/// code runs unchanged against canned replies. Registered for the duration of each test.
final class StubAPI: URLProtocol {
    struct Seen: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var form: [String: String] { MCPOAuthClient.formDecode(String(decoding: body, as: UTF8.self)) }
        func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }

    typealias Reply = (status: Int, headers: [String: String], body: Data)
    nonisolated(unsafe) static var handler: (@Sendable (Seen) -> Reply)?
    nonisolated(unsafe) private static var log: [Seen] = []
    private static let lock = NSLock()
    static var seen: [Seen] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }

    static let hosts: Set<String> = ["graph.microsoft.com", "api.linkedin.com", "oauth.reddit.com", "linkedin-upload.example"]

    override class func canInit(with request: URLRequest) -> Bool { hosts.contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let seen = Seen(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.lock.withLock { Self.log.append(seen) }
        let reply: Reply = Self.handler?(seen) ?? (status: 404, headers: [:], body: Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
        (status, headers.merging(["Content-Type": "application/json"]) { a, _ in a }, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

final class NativeConnectorTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(StubAPI.self)
        StubAPI.reset()
        StubAPI.handler = nil
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubAPI.self)
        StubAPI.handler = nil
    }

    private func api(token: String = "tok", refreshed: String? = nil, settings: [String: String] = [:]) -> ConnectorAPI {
        ConnectorAPI(token: { token }, refresh: { _ in refreshed }, settings: settings)
    }

    // MARK: Microsoft Graph

    func testGraphWhoamiSendsBearerAndRefreshesOnce401() async throws {
        StubAPI.handler = { seen in
            if seen.header("Authorization") == "Bearer stale" { return StubAPI.json(["error": ["code": "InvalidAuthenticationToken", "message": "expired"]], status: 401) }
            return StubAPI.json(["displayName": "Alex", "mail": "alex@example.com", "jobTitle": "CEO"])
        }
        let out = try await MicrosoftGraphConnector().call("whoami", arguments: [:], api: api(token: "stale", refreshed: "fresh"))
        XCTAssertEqual(out, "Alex <alex@example.com> — CEO")
        XCTAssertEqual(StubAPI.seen.map { $0.header("Authorization") }, ["Bearer stale", "Bearer fresh"])
        XCTAssertEqual(StubAPI.seen.first?.url.path, "/v1.0/me")
    }

    func testGraphSendMailAndTeamsMessageShapes() async throws {
        StubAPI.handler = { seen in
            switch (seen.method, seen.url.path) {
            case ("POST", "/v1.0/me/sendMail"): return (202, [:], Data())
            case ("GET", "/v1.0/me"): return StubAPI.json(["id": "me-1"])
            case ("POST", "/v1.0/chats"): return StubAPI.json(["id": "chat-9"], status: 201)
            case ("POST", "/v1.0/chats/chat-9/messages"): return StubAPI.json(["id": "m-1"], status: 201)
            default: return StubAPI.json(["error": ["message": "unexpected \(seen.url.path)"]], status: 400)
            }
        }
        let graph = MicrosoftGraphConnector()
        let sent = try await graph.call("mail_send", arguments: ["to": .array([.string("a@x.com")]), "subject": "Hi", "body": "Hello"], api: api())
        XCTAssertTrue(sent.contains("a@x.com"))
        let mail = try XCTUnwrap(StubAPI.seen.first?.json?["message"] as? [String: Any])
        XCTAssertEqual(mail["subject"] as? String, "Hi")
        XCTAssertEqual(((mail["toRecipients"] as? [[String: Any]])?.first?["emailAddress"] as? [String: Any])?["address"] as? String, "a@x.com")

        let dm = try await graph.call("teams_message_person", arguments: ["email": "dana@x.com", "text": "ping"], api: api())
        XCTAssertTrue(dm.contains("chat-9"))
        let create = try XCTUnwrap(StubAPI.seen.first { $0.url.path == "/v1.0/chats" }?.json)
        XCTAssertEqual(create["chatType"] as? String, "oneOnOne")
        let binds = (create["members"] as? [[String: Any]] ?? []).compactMap { $0["user@odata.bind"] as? String }
        XCTAssertEqual(binds, ["https://graph.microsoft.com/v1.0/users('me-1')", "https://graph.microsoft.com/v1.0/users('dana@x.com')"])
        let message = try XCTUnwrap(StubAPI.seen.last?.json?["body"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "ping")
    }

    func testGraphReplyKeepsLineBreaksAboveTheQuotedThread() async throws {
        StubAPI.handler = { seen in
            switch (seen.method, seen.url.path) {
            case ("POST", "/v1.0/me/messages/m-1/createReply"):
                return StubAPI.json(["id": "d-1", "body": ["contentType": "html", "content": "<html><head></head><body dir=\"ltr\"><div id=\"quote\">Earlier</div></body></html>"]], status: 201)
            case ("PATCH", "/v1.0/me/messages/d-1"): return StubAPI.json(["id": "d-1"])
            case ("POST", "/v1.0/me/messages/d-1/send"): return (202, [:], Data())
            default: return StubAPI.json(["error": ["message": "unexpected \(seen.method) \(seen.url.path)"]], status: 400)
            }
        }
        let out = try await MicrosoftGraphConnector().call("mail_reply", arguments: ["id": "m-1", "body": "Hi Dana,\n\nThanks & see you Tuesday.\nBest,\nSam"], api: api())
        XCTAssertEqual(out, "Replied.")
        XCTAssertEqual(StubAPI.seen.map { "\($0.method) \($0.url.path)" }, ["POST /v1.0/me/messages/m-1/createReply", "PATCH /v1.0/me/messages/d-1", "POST /v1.0/me/messages/d-1/send"])
        let body = try XCTUnwrap(StubAPI.seen[1].json?["body"] as? [String: Any])
        XCTAssertEqual(body["contentType"] as? String, "HTML")
        let html = try XCTUnwrap(body["content"] as? String)
        XCTAssertTrue(html.contains("<body dir=\"ltr\"><div style="), "the reply goes at the top of the body")
        XCTAssertTrue(html.contains("<p style=\"margin:0 0 12px 0\">Hi Dana,</p><p style=\"margin:0 0 12px 0\">Thanks &amp; see you Tuesday.<br>Best,<br>Sam</p>"))
        XCTAssertTrue(html.contains("<div id=\"quote\">Earlier</div>"), "the quoted thread stays")
    }

    func testGraphMailSearchEncodesQueryAndReadsList() async throws {
        StubAPI.handler = { _ in
            StubAPI.json(["value": [["id": "AAA", "subject": "Invoice", "isRead": false, "receivedDateTime": "2026-09-22T10:00:00Z", "bodyPreview": "Please pay", "from": ["emailAddress": ["name": "Acme", "address": "billing@acme.com"]]]]])
        }
        let out = try await MicrosoftGraphConnector().call("mail_search", arguments: ["query": "from:acme invoice", "limit": 5], api: api())
        XCTAssertTrue(out.contains("Invoice [unread]"))
        XCTAssertTrue(out.contains("id: AAA"))
        let seen = try XCTUnwrap(StubAPI.seen.first)
        XCTAssertEqual(seen.header("ConsistencyLevel"), "eventual")
        let items = URLComponents(url: seen.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "$search" }?.value, "\"from:acme invoice\"")
        XCTAssertEqual(items.first { $0.name == "$top" }?.value, "5")
    }

    func testGraphErrorsSurfaceGraphsMessage() async {
        StubAPI.handler = { _ in StubAPI.json(["error": ["code": "Forbidden", "message": "Missing scope ChannelMessage.Read.All"]], status: 403) }
        do {
            _ = try await MicrosoftGraphConnector().call("teams_channel_messages", arguments: ["team_id": "t", "channel_id": "c"], api: api())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(String(describing: error), "HTTP 403: Missing scope ChannelMessage.Read.All")
        }
    }

    // MARK: LinkedIn

    func testLinkedInPostUsesMemberURNVersionHeadersAndEscapes() async throws {
        StubAPI.handler = { seen in
            switch seen.url.path {
            case "/v2/userinfo": return StubAPI.json(["sub": "abc123", "name": "Alex"])
            case "/rest/posts": return (201, ["x-restli-id": "urn:li:share:777"], Data())
            default: return (404, [:], Data())
            }
        }
        let out = try await LinkedInConnector().call("create_post", arguments: ["text": "Launch (beta) #Acme", "link_url": "https://example.com", "link_title": "Acme"], api: api())
        XCTAssertTrue(out.contains("urn:li:share:777"))
        let post = try XCTUnwrap(StubAPI.seen.first { $0.url.path == "/rest/posts" })
        XCTAssertEqual(post.header("LinkedIn-Version"), LinkedInConnector.apiVersion)
        XCTAssertEqual(post.header("X-Restli-Protocol-Version"), "2.0.0")
        let body = try XCTUnwrap(post.json)
        XCTAssertEqual(body["author"] as? String, "urn:li:person:abc123")
        XCTAssertEqual(body["commentary"] as? String, "Launch \\(beta\\) #Acme")
        XCTAssertEqual(((body["content"] as? [String: Any])?["article"] as? [String: Any])?["source"] as? String, "https://example.com")
    }

    func testLinkedInImageUploadThenPost() async throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("li-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        StubAPI.handler = { seen in
            switch (seen.method, seen.url.host ?? "", seen.url.path) {
            case ("GET", _, "/v2/userinfo"): return StubAPI.json(["sub": "abc123"])
            case ("POST", _, "/rest/images"): return StubAPI.json(["value": ["uploadUrl": "https://linkedin-upload.example/put/1", "image": "urn:li:image:42"]])
            case ("PUT", "linkedin-upload.example", _): return (201, [:], Data())
            case ("POST", _, "/rest/posts"): return (201, ["x-restli-id": "urn:li:share:9"], Data())
            default: return (404, [:], Data())
            }
        }
        _ = try await LinkedInConnector().call("create_post", arguments: ["text": "Photo", "image_path": .string(image.path), "image_alt": "Logo"], api: api())
        let put = try XCTUnwrap(StubAPI.seen.first { $0.method == "PUT" })
        XCTAssertEqual(put.header("Content-Type"), "image/png")
        XCTAssertEqual(put.body.count, 4)
        let media = ((StubAPI.seen.last?.json?["content"] as? [String: Any])?["media"] as? [String: Any])
        XCTAssertEqual(media?["id"] as? String, "urn:li:image:42")
        XCTAssertEqual(media?["altText"] as? String, "Logo")
    }

    // MARK: Reddit

    func testRedditSubmitSendsFormAndUserAgent() async throws {
        StubAPI.handler = { seen in
            StubAPI.json(["json": ["errors": [], "data": ["url": "https://www.reddit.com/r/test/comments/x1/", "name": "t3_x1"]]])
        }
        let out = try await RedditConnector().call("submit_post", arguments: ["subreddit": "r/test", "title": "Hello", "text": "Body"], api: api(settings: ["username": "alex"]))
        XCTAssertTrue(out.contains("t3_x1"))
        let seen = try XCTUnwrap(StubAPI.seen.first)
        XCTAssertEqual(seen.url.path, "/api/submit")
        XCTAssertEqual(seen.form["sr"], "test")
        XCTAssertEqual(seen.form["kind"], "self")
        XCTAssertEqual(seen.form["api_type"], "json")
        XCTAssertEqual(seen.header("User-Agent"), RedditConnector.userAgent(username: "alex"))
    }

    func testRedditRefusalIsAnError() async {
        StubAPI.handler = { _ in StubAPI.json(["json": ["errors": [["SUBREDDIT_NOTALLOWED", "you aren't allowed to post there.", "sr"]]]]) }
        do {
            _ = try await RedditConnector().call("submit_post", arguments: ["subreddit": "test", "title": "x", "url": "https://a.b"], api: api())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SUBREDDIT_NOTALLOWED"))
        }
    }

    func testRedditParsing() {
        XCTAssertEqual(RedditConnector.subreddit("r/SwiftUI"), "SwiftUI")
        XCTAssertEqual(RedditConnector.subreddit("https://www.reddit.com/r/macapps/"), "macapps")
        XCTAssertEqual(RedditConnector.postID("t3_1abcde"), "1abcde")
        XCTAssertEqual(RedditConnector.postID("https://www.reddit.com/r/x/comments/1abcde/some_title/"), "1abcde")
        XCTAssertEqual(ConnectorText.plain(fromHTML: "<p>Hi&nbsp;<b>there</b></p><br>ok"), "Hi there\n\nok")
    }

    // MARK: Sign-in with configured endpoints

    /// A token endpoint that records every request.
    final class TokenEndpoint: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [TinyHTTPServer.Request] = []
        var seen: [TinyHTTPServer.Request] { lock.withLock { requests } }
        var server: TinyHTTPServer!

        func start() async throws {
            server = try TinyHTTPServer { [weak self] request in
                self?.lock.withLock { self?.requests.append(request) }
                return .json(["access_token": "at-1", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "rt-1"])
            }
            try await server.start()
        }
    }

    private func signIn(_ config: MCPServerConfig, manager: MCPManager) async throws -> (authorize: URL, token: TinyHTTPServer.Request) {
        try await manager.add(config)
        let authorize = try await manager.beginAuth(config.id)
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        // The redirect names localhost; the listener is on 127.0.0.1 either way.
        var c = URLComponents(string: "http://127.0.0.1:\(MCPManager.fixedRedirectPort)/callback")!
        c.queryItems = [URLQueryItem(name: "code", value: "code-1"), URLQueryItem(name: "state", value: q["state"])]
        _ = try await URLSession.shared.data(from: c.url!)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let s = await manager.statuses[config.id], s.state == .connected { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        return (authorize, try XCTUnwrap(tokenEndpoint.seen.first))
    }

    private var tokenEndpoint: TokenEndpoint!

    func testLinkedInStyleSignInSkipsPKCEAndResourceAndConnectsBuiltin() async throws {
        tokenEndpoint = TokenEndpoint()
        try await tokenEndpoint.start()
        defer { tokenEndpoint.server.stop() }
        let base = tokenEndpoint.server.baseURL.absoluteString
        let credentials = InMemoryCredentialStore()
        let broker = ToolBroker()
        let manager = MCPManager(store: FakeStore(), eventBus: EventBus(), broker: broker, credentials: credentials)
        let config = MCPServerConfig(
            name: "LinkedIn", transport: .builtin(connector: "linkedin"),
            auth: .oauth(scopes: ["openid", "w_member_social"], clientID: "li-app", clientSecret: "li-secret"),
            oauthServer: OAuthServerConfig(authorizeURL: base + "/authorize", tokenURL: base + "/token", extraAuthorizeParameters: ["prompt": "login"], secretInBody: true, usesPKCE: false, redirectHost: "localhost")
        )
        let (authorize, token) = try await signIn(config, manager: manager)
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["redirect_uri"], "http://localhost:47831/callback")
        XCTAssertEqual(q["prompt"], "login")
        XCTAssertEqual(q["scope"], "openid w_member_social")
        XCTAssertNil(q["code_challenge"])
        XCTAssertNil(q["resource"])
        XCTAssertEqual(token.form["client_secret"], "li-secret")
        XCTAssertNil(token.form["code_verifier"])
        XCTAssertNil(token.form["resource"])
        XCTAssertNil(token.header("Authorization"))
        let status = await manager.statuses[config.id]
        XCTAssertEqual(status?.authState, .signedIn)
        XCTAssertEqual(status?.state, .connected)
        XCTAssertEqual(status?.toolCount, LinkedInConnector().tools.count)
        let tool = await broker.tool(named: "linkedin__create_post")
        XCTAssertNotNil(tool)
        await manager.stop()
    }

    func testRedditStyleSignInUsesBasicWithEmptySecretAndHeaders() async throws {
        tokenEndpoint = TokenEndpoint()
        try await tokenEndpoint.start()
        defer { tokenEndpoint.server.stop() }
        let base = tokenEndpoint.server.baseURL.absoluteString
        let manager = MCPManager(store: FakeStore(), eventBus: EventBus(), broker: ToolBroker(), credentials: InMemoryCredentialStore())
        let config = MCPServerConfig(
            name: "Reddit", transport: .builtin(connector: "reddit"),
            auth: .oauth(scopes: ["identity"], clientID: "rd-app", clientSecret: nil),
            oauthServer: OAuthServerConfig(authorizeURL: base + "/authorize", tokenURL: base + "/token", extraAuthorizeParameters: ["duration": "permanent"], tokenHeaders: ["User-Agent": "macos:dev.pennant.mac:v1 (by /u/alex)"], basicAuthWithEmptySecret: true, usesPKCE: false, redirectHost: "localhost"),
            settings: ["username": "alex"]
        )
        let (authorize, token) = try await signIn(config, manager: manager)
        XCTAssertTrue(authorize.absoluteString.contains("duration=permanent"))
        XCTAssertEqual(token.header("Authorization"), "Basic " + Data("rd-app:".utf8).base64EncodedString())
        XCTAssertEqual(token.header("User-Agent"), "macos:dev.pennant.mac:v1 (by /u/alex)")
        XCTAssertNil(token.form["client_secret"])
        await manager.stop()
    }

    func testEntraStylePublicClientSendsPKCEAndNoSecret() async throws {
        tokenEndpoint = TokenEndpoint()
        try await tokenEndpoint.start()
        defer { tokenEndpoint.server.stop() }
        let base = tokenEndpoint.server.baseURL.absoluteString
        let manager = MCPManager(store: FakeStore(), eventBus: EventBus(), broker: ToolBroker(), credentials: InMemoryCredentialStore())
        let config = MCPServerConfig(
            name: "Microsoft 365", transport: .builtin(connector: "microsoft365"),
            auth: .oauth(scopes: MCPCatalog.microsoftGraphScopes, clientID: "entra-app", clientSecret: ""),
            oauthServer: OAuthServerConfig(authorizeURL: base + "/authorize", tokenURL: base + "/token", redirectHost: "localhost")
        )
        let (authorize, token) = try await signIn(config, manager: manager)
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertNotNil(q["code_challenge"])
        XCTAssertNil(q["resource"])
        XCTAssertNotNil(token.form["code_verifier"])
        XCTAssertNil(token.form["client_secret"])
        XCTAssertNil(token.header("Authorization"))
        let status = await manager.statuses[config.id]
        XCTAssertEqual(status?.toolCount, MicrosoftGraphConnector().tools.count)
        await manager.stop()
    }
}
