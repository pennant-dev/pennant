import PennantCore
import Foundation
import XCTest
@testable import PennantHostKit

// MARK: - Fixtures

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// An unsigned JWT with these claims; the host reads the payload and never checks the signature.
private func fakeJWT(_ claims: [String: Any]) -> String {
    let header = base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
    let payload = base64URL(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).signature"
}

private func accessJWT(expiresIn: TimeInterval, accountID: String = "acct_123", plan: String = "plus", residency: String? = nil, subject: String = "user-1") -> String {
    var auth: [String: Any] = ["chatgpt_account_id": accountID, "chatgpt_plan_type": plan, "chatgpt_user_id": "user-1"]
    if let residency { auth["chatgpt_data_residency"] = residency }
    return fakeJWT(["sub": subject, "exp": Date().addingTimeInterval(expiresIn).timeIntervalSince1970, "https://api.openai.com/auth": auth])
}

private func idJWT(email: String = "user@example.com", accountID: String = "acct_123", plan: String = "plus") -> String {
    fakeJWT(["email": email, "email_verified": true, "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": plan]])
}

private func sse(_ events: [String]) -> String {
    events.map { "event: response\ndata: \($0)\n\n" }.joined()
}

/// A text reply, a reasoning item with encrypted content, and one function call, ending in `response.completed`.
private let toolCallTranscript: [String] = [
    #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#,
    #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}"#,
    #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"Thinking"}"#,
    #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":1,"delta":"more"}"#,
    #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"Thinking"},{"type":"summary_text","text":"more"}],"encrypted_content":"ENC1"}}"#,
    #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#,
    #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":"Hello"}"#,
    #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":" there"}"#,
    #"{"type":"response.output_item.done","output_index":1,"item":{"id":"msg_1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello there"}]}}"#,
    #"{"type":"response.output_item.added","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"get_weather","arguments":""}}"#,
    #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":2,"delta":"{\"city\":"}"#,
    #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":2,"delta":"\"Lisbon\"}"}"#,
    #"{"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":2,"arguments":"{\"city\":\"Lisbon\"}"}"#,
    #"{"type":"response.output_item.done","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Lisbon\"}","status":"completed"}}"#,
    #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":120,"output_tokens":30}}}"#,
]

private let textOnlyTranscript: [String] = [
    #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#,
    #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"Sunny."}"#,
    #"{"type":"response.completed","response":{"id":"resp_2","status":"completed","usage":{"input_tokens":10,"output_tokens":2}}}"#,
]

private func describe(_ chunk: InferenceChunk) -> String {
    switch chunk {
    case .textDelta(let t): return "text:\(t)"
    case .reasoningDelta(let r): return "reasoning:\(r)"
    case .toolCall(let c): return "tool:\(c.id.rawValue) \(c.name) \(c.arguments.compactText)"
    case .usage(let u): return "usage:\(u.inputTokens)/\(u.outputTokens)"
    case .finished(let f): return "finished:\(f.rawValue)"
    }
}

private func collect(_ provider: ChatGPTProvider, _ request: InferenceRequest) async throws -> [InferenceChunk] {
    var chunks: [InferenceChunk] = []
    for try await chunk in provider.stream(request) { chunks.append(chunk) }
    return chunks
}

private func chatGPTConfig(model: String = "gpt-5.6-sol", supportsVision: Bool = true, contextWindowTokens: Int = 8000) -> HostConfig.Inference {
    HostConfig.Inference(baseURL: "http://ignored.local/v1", model: model, contextWindowTokens: contextWindowTokens, supportsVision: supportsVision, provider: HostConfig.Inference.chatGPTProvider)
}

private let weatherTool = ToolSpec(
    name: "get_weather",
    description: "Get the current weather for a city.",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]
)

private func waitUntil(_ timeout: TimeInterval = 8, _ predicate: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("Timed out waiting for the condition")
}

// MARK: - Fake auth.openai.com + ChatGPT backend

/// The token endpoint and the Responses endpoint in one process on 127.0.0.1.
private final class FakeChatGPTBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var http: TinyHTTPServer!

    var validAccessTokens: Set<String> = []
    var validRefreshTokens: Set<String> = []
    var expectedCodeChallenge: String?
    var issuedCode = "code-1"
    var transcript: [String] = textOnlyTranscript
    var rejectAllResponses = false
    private var refreshCounter = 0
    private(set) var tokenRequests: [[String: String]] = []
    private(set) var responsesRequests: [TinyHTTPServer.Request] = []
    /// The account's model list, as the backend answers `GET /models`, and the status it answers with.
    var modelsBody = Data(#"{"models":[]}"#.utf8)
    var modelsStatus = 200
    private(set) var modelsRequests: [TinyHTTPServer.Request] = []
    private(set) var lastIssuedAccessToken: String?

    var baseURL: URL { http.baseURL }
    var endpoints: ChatGPTAuthManager.Endpoints {
        ChatGPTAuthManager.Endpoints(authorize: baseURL.appendingPathComponent("oauth/authorize"), token: baseURL.appendingPathComponent("oauth/token"), responses: baseURL.appendingPathComponent("responses"), redirectPort: nil)
    }

    func start() async throws {
        http = try TinyHTTPServer { [unowned self] request in self.handle(request) }
        try await http.start()
    }

    func stop() { http.stop() }

    private func issueTokens() -> [String: Any] {
        refreshCounter += 1
        let access = accessJWT(expiresIn: 3600)
        let refresh = "rt-\(refreshCounter + 1)"
        validAccessTokens.insert(access)
        validRefreshTokens.insert(refresh)
        lastIssuedAccessToken = access
        return ["access_token": access, "refresh_token": refresh, "id_token": idJWT(), "expires_in": 3600, "token_type": "Bearer"]
    }

    private func handle(_ request: TinyHTTPServer.Request) -> TinyHTTPServer.Response {
        lock.lock(); defer { lock.unlock() }
        switch (request.method, request.path) {
        case ("POST", "/oauth/token"):
            let form = request.form
            tokenRequests.append(form)
            guard form["client_id"] == ChatGPTAuthManager.clientID else { return .json(["error": "invalid_client"], status: 401) }
            switch form["grant_type"] {
            case "refresh_token":
                guard let token = form["refresh_token"], validRefreshTokens.contains(token) else {
                    return .json(["error": "invalid_grant", "error_description": "refresh token is not valid"], status: 400)
                }
                validRefreshTokens.remove(token)
                return .json(issueTokens())
            case "authorization_code":
                guard form["code"] == issuedCode, let verifier = form["code_verifier"], PKCE.challenge(for: verifier) == expectedCodeChallenge, form["redirect_uri"]?.isEmpty == false else {
                    return .json(["error": "invalid_grant", "error_description": "bad code or verifier"], status: 400)
                }
                return .json(issueTokens())
            default:
                return .json(["error": "unsupported_grant_type"], status: 400)
            }
        case ("POST", "/responses"):
            responsesRequests.append(request)
            let bearer = request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            guard validAccessTokens.contains(bearer), !rejectAllResponses else { return .json(["detail": "Unauthorized"], status: 401) }
            return TinyHTTPServer.Response(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(sse(transcript).utf8))
        case ("GET", "/models"):
            modelsRequests.append(request)
            let bearer = request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            guard validAccessTokens.contains(bearer) else { return .json(["detail": "Unauthorized"], status: 401) }
            return TinyHTTPServer.Response(status: modelsStatus, headers: ["Content-Type": "application/json"], body: modelsBody)
        default:
            return .status(404)
        }
    }
}

// MARK: - Tests

final class ChatGPTProviderTests: XCTestCase {
    private var backend: FakeChatGPTBackend!
    private var credentials: InMemoryCredentialStore!
    private var auth: ChatGPTAuthManager!
    private var tempDir: URL!

    override func setUp() async throws {
        backend = FakeChatGPTBackend()
        try await backend.start()
        credentials = InMemoryCredentialStore()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-chatgpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        auth = ChatGPTAuthManager(credentials: credentials, codexAuthFile: tempDir.appendingPathComponent("auth.json"), endpoints: backend.endpoints, session: URLSession(configuration: .ephemeral))
    }

    override func tearDown() async throws {
        await auth.cancelSignIn()
        backend.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func storeTokens(expiresIn: TimeInterval, refreshToken: String? = "rt-1", source: String = ChatGPTTokens.pennantSource) throws -> ChatGPTTokens {
        let tokens = ChatGPTTokens(accessToken: accessJWT(expiresIn: expiresIn), refreshToken: refreshToken, idToken: idJWT(), expiresIn: nil, source: source)
        try credentials.set(ChatGPTAuthManager.tokenKey, value: try tokens.encoded())
        return tokens
    }

    private func makeProvider(session: URLSession? = nil, config: HostConfig.Inference = chatGPTConfig()) -> ChatGPTProvider {
        ChatGPTProvider(config: config, auth: auth, session: session ?? URLSession(configuration: .ephemeral))
    }

    // MARK: JWT and identity

    func testJWTPayloadParsing() {
        let access = accessJWT(expiresIn: 600, accountID: "acct_9", plan: "pro", residency: "eu")
        let identity = ChatGPTJWT.identity(idToken: idJWT(email: "me@example.com", accountID: "acct_9", plan: "pro"), accessToken: access)
        XCTAssertEqual(identity.email, "me@example.com")
        XCTAssertEqual(identity.accountID, "acct_9")
        XCTAssertEqual(identity.plan, "pro")
        XCTAssertEqual(identity.residency, "eu")
        XCTAssertEqual(identity.expiresAt!.timeIntervalSinceNow, 600, accuracy: 5)

        // Without an id token the access token's claims serve; a non-JWT yields nothing.
        let accessOnly = ChatGPTJWT.identity(idToken: nil, accessToken: access)
        XCTAssertNil(accessOnly.email)
        XCTAssertEqual(accessOnly.accountID, "acct_9")
        XCTAssertNil(ChatGPTJWT.claims("not-a-jwt"))
        XCTAssertNil(ChatGPTJWT.claims("a.b"))
        XCTAssertEqual(ChatGPTJWT.base64URLDecode("aGk"), Data("hi".utf8))
    }

    // MARK: Codex CLI import

    func testImportCodexLoginCopiesTokensWithoutTouchingTheFile() async throws {
        let file = tempDir.appendingPathComponent("auth.json")
        let contents: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": ["id_token": idJWT(email: "codex@example.com", accountID: "acct_c", plan: "plus"), "access_token": accessJWT(expiresIn: 1800, accountID: "acct_c"), "refresh_token": "rt-codex", "account_id": "acct_c"],
            "last_refresh": "2026-09-22T10:00:00Z",
        ]
        let original = try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys])
        try original.write(to: file)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: file.path)

        let account = try await auth.importCodexLogin()
        XCTAssertTrue(account.signedIn)
        XCTAssertEqual(account.email, "codex@example.com")
        XCTAssertEqual(account.accountID, "acct_c")
        XCTAssertEqual(account.plan, "plus")
        XCTAssertEqual(account.source, "codex-cli")
        XCTAssertNil(account.detail)
        XCTAssertEqual(account.expiresAt!.timeIntervalSinceNow, 1800, accuracy: 5)

        let stored = try XCTUnwrap(credentials.get(ChatGPTAuthManager.tokenKey).flatMap(ChatGPTTokens.decode))
        XCTAssertEqual(stored.refreshToken, "rt-codex")
        XCTAssertEqual(stored.source, "codex-cli")
        XCTAssertTrue(credentials.get(ChatGPTAuthManager.tokenKey)!.contains("\"refresh_token\""))
        let usable = await auth.isUsable()
        XCTAssertTrue(usable)

        XCTAssertEqual(try Data(contentsOf: file), original, "the Codex CLI file must not be rewritten")
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributesBefore[.modificationDate] as? Date, attributesAfter[.modificationDate] as? Date)

        // An API-key login has no tokens; a missing file is reported as such.
        try Data(#"{"OPENAI_API_KEY":"sk-test","tokens":null}"#.utf8).write(to: file)
        do { _ = try await auth.importCodexLogin(); XCTFail("expected codexLoginMissing") } catch let e as ChatGPTAuthError {
            guard case .codexLoginMissing = e else { return XCTFail("\(e)") }
        }
        try FileManager.default.removeItem(at: file)
        do { _ = try await auth.importCodexLogin(); XCTFail("expected codexLoginMissing") } catch let e as ChatGPTAuthError {
            guard case .codexLoginMissing = e else { return XCTFail("\(e)") }
        }
    }

    // MARK: Request body

    func testRequestBodyForMixedHistory() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let messages: [ModelMessage] = [
            .system("You are Pennant."),
            ModelMessage(role: .user, parts: [.text("What is on screen?"), .image(data: jpeg, mimeType: "image/jpeg")]),
            .assistant("Let me look.", toolCalls: [ToolCall(id: ToolCallID("call_1"), name: "screenshot", arguments: ["region": "full"])]),
            .tool(callID: ToolCallID("call_1"), name: "screenshot", parts: [.text("captured"), .image(data: png, mimeType: "image/png")]),
            .assistant("", toolCalls: [ToolCall(id: ToolCallID("call_2"), name: "get_weather", arguments: ["city": "Lisbon"])]),
            .tool(callID: ToolCallID("call_2"), name: "get_weather", parts: [.text("Sunny")]),
        ]
        let cache = ReasoningReplayCache()
        cache.store(callIDs: ["call_2"], items: [["type": "reasoning", "summary": [], "encrypted_content": "ENC2"]])
        let request = InferenceRequest(messages: messages, tools: [weatherTool], maxOutputTokens: 2048, temperature: 0.7)
        let body = ChatGPTProvider.requestBody(for: request, config: chatGPTConfig(), replay: cache, cacheScope: "session-a")

        XCTAssertEqual(body["model"]?.stringValue, "gpt-5.6-sol")
        XCTAssertEqual(body["instructions"]?.stringValue, "You are Pennant.")
        XCTAssertEqual(body["store"]?.boolValue, false)
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body["tool_choice"]?.stringValue, "auto")
        XCTAssertEqual(body["parallel_tool_calls"]?.boolValue, true)
        XCTAssertEqual(body["include"], ["reasoning.encrypted_content"])
        XCTAssertEqual(body["reasoning"], ["effort": "medium", "summary": "auto"])
        let cacheKey = try XCTUnwrap(body["prompt_cache_key"]?.stringValue)
        XCTAssertTrue(cacheKey.hasPrefix("pck_"))
        XCTAssertEqual(cacheKey.count, 28)
        XCTAssertNotEqual(cacheKey, ChatGPTProvider.requestBody(for: request, config: chatGPTConfig(), cacheScope: "session-b")["prompt_cache_key"]?.stringValue)
        for absent in ["temperature", "max_output_tokens", "messages", "text", "stream_options"] {
            XCTAssertNil(body[absent], "\(absent) is not part of a Codex backend request")
        }

        let tools = try XCTUnwrap(body["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"]?.stringValue, "function")
        XCTAssertEqual(tools[0]["name"]?.stringValue, "get_weather")
        XCTAssertEqual(tools[0]["description"]?.stringValue, weatherTool.description)
        XCTAssertEqual(tools[0]["parameters"], weatherTool.inputSchema)
        XCTAssertEqual(tools[0]["strict"]?.boolValue, false)
        XCTAssertNil(tools[0]["function"])

        let input = try XCTUnwrap(body["input"]?.arrayValue)
        XCTAssertEqual(input.map { $0["type"]?.stringValue ?? "?" }, ["message", "message", "function_call", "function_call_output", "message", "reasoning", "function_call", "function_call_output"])

        XCTAssertEqual(input[0]["role"]?.stringValue, "user")
        let userParts = try XCTUnwrap(input[0]["content"]?.arrayValue)
        XCTAssertEqual(userParts[0], ["type": "input_text", "text": "What is on screen?"])
        XCTAssertEqual(userParts[1]["type"]?.stringValue, "input_image")
        XCTAssertEqual(userParts[1]["image_url"]?.stringValue, "data:image/jpeg;base64," + jpeg.base64EncodedString())

        XCTAssertEqual(input[1]["role"]?.stringValue, "assistant")
        XCTAssertEqual(input[1]["content"], [["type": "output_text", "text": "Let me look."]])
        XCTAssertEqual(input[2], ["type": "function_call", "call_id": "call_1", "name": "screenshot", "arguments": "{\"region\":\"full\"}"])
        XCTAssertEqual(input[3], ["type": "function_call_output", "call_id": "call_1", "output": "captured"])

        // The tool's image rides in a follow-up user turn: `input_image` is only accepted there.
        XCTAssertEqual(input[4]["role"]?.stringValue, "user")
        let followUp = try XCTUnwrap(input[4]["content"]?.arrayValue)
        XCTAssertEqual(followUp[0]["text"]?.stringValue, "Result image for tool call call_1")
        XCTAssertEqual(followUp[1]["image_url"]?.stringValue, "data:image/png;base64," + png.base64EncodedString())

        // The cached reasoning of the turn that produced call_2 precedes its function_call; the empty assistant
        // text adds no message item.
        XCTAssertEqual(input[5]["encrypted_content"]?.stringValue, "ENC2")
        XCTAssertEqual(input[6]["call_id"]?.stringValue, "call_2")
        XCTAssertEqual(input[7], ["type": "function_call_output", "call_id": "call_2", "output": "Sunny"])

        // Replay switched off: no encrypted content asked for or sent.
        let plain = ChatGPTProvider.requestBody(for: request, config: chatGPTConfig(), replay: cache, replayReasoning: false)
        XCTAssertEqual(plain["include"], [])
        XCTAssertFalse(plain["input"]!.arrayValue!.contains { $0["type"]?.stringValue == "reasoning" })

        // JSON mode and disabled tools.
        let summary = ChatGPTProvider.requestBody(for: InferenceRequest(messages: [.user("Summarise")], tools: [weatherTool], disableTools: true, jsonMode: true), config: chatGPTConfig())
        XCTAssertNil(summary["tools"])
        XCTAssertNil(summary["tool_choice"])
        XCTAssertTrue(summary["instructions"]!.stringValue!.hasSuffix("Reply with a single JSON object and nothing else."))
        XCTAssertTrue(summary["instructions"]!.stringValue!.hasPrefix(ChatGPTProvider.defaultInstructions))

        // Vision off: images become notes and no follow-up turn is added.
        let blind = ChatGPTProvider.requestBody(for: request, config: chatGPTConfig(supportsVision: false))
        let blindInput = blind["input"]!.arrayValue!
        XCTAssertEqual(blindInput.map { $0["type"]?.stringValue ?? "?" }, ["message", "message", "function_call", "function_call_output", "function_call", "function_call_output"])
        XCTAssertEqual(blindInput[0]["content"]?.arrayValue?[1]["text"]?.stringValue, "[image omitted: \(jpeg.count) bytes]")
        XCTAssertEqual(blindInput[3]["output"]?.stringValue, "captured\n[image omitted: \(png.count) bytes]")
    }

    // MARK: SSE mapping

    func testSSEEventsMapToChunks() throws {
        var assembler = ResponsesEventAssembler()
        var chunks: [InferenceChunk] = []
        for event in toolCallTranscript { chunks.append(contentsOf: try assembler.handle(payload: event)) }
        chunks.append(contentsOf: try assembler.end())
        XCTAssertEqual(chunks.map(describe), [
            "reasoning:Thinking", "reasoning:\n\nmore",
            "text:Hello", "text: there",
            "tool:call_1 get_weather {\"city\":\"Lisbon\"}",
            "usage:120/30",
            "finished:toolCalls",
        ])
        XCTAssertEqual(assembler.emittedCallIDs, ["call_1"])
        XCTAssertEqual(assembler.reasoningItems, [["type": "reasoning", "summary": [["type": "summary_text", "text": "Thinking"], ["type": "summary_text", "text": "more"]], "encrypted_content": "ENC1"]])

        // A backend that announces a call but never sends its done event: settled at completion.
        var settled = ResponsesEventAssembler()
        var out: [InferenceChunk] = []
        for event in [
            #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_2","type":"function_call","call_id":"call_2","name":"open_app","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_2","output_index":0,"delta":"{\"name\":\"Safari\"}"}"#,
            #"{"type":"response.completed","response":{"id":"r","status":"completed","usage":{"input_tokens":5,"output_tokens":1}}}"#,
        ] { out.append(contentsOf: try settled.handle(payload: event)) }
        XCTAssertEqual(out.map(describe), ["usage:5/1", "tool:call_2 open_app {\"name\":\"Safari\"}", "finished:toolCalls"])

        // Commentary-phase text goes to the reasoning channel; a message delivered only in its done event still arrives.
        var phased = ResponsesEventAssembler()
        out = []
        for event in [
            #"{"type":"response.output_item.added","output_index":0,"item":{"id":"m1","type":"message","phase":"commentary","content":[]}}"#,
            #"{"type":"response.output_text.delta","output_index":0,"delta":"Checking the window"}"#,
            #"{"type":"response.output_item.done","output_index":1,"item":{"id":"m2","type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
            #"{"type":"response.incomplete","response":{"id":"r","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":9,"output_tokens":9}}}"#,
        ] { out.append(contentsOf: try phased.handle(payload: event)) }
        XCTAssertEqual(out.map(describe), ["reasoning:Checking the window", "text:Done.", "usage:9/9", "finished:length"])

        // No terminal frame: text still ends the stream; nothing at all is an error.
        var truncated = ResponsesEventAssembler()
        _ = try truncated.handle(payload: #"{"type":"response.output_text.delta","output_index":0,"delta":"partial"}"#)
        XCTAssertEqual(try truncated.end().map(describe), ["finished:stop"])
        var empty = ResponsesEventAssembler()
        _ = try empty.handle(payload: #"{"type":"response.created","response":{}}"#)
        XCTAssertThrowsError(try empty.end())
    }

    func testFailedResponsesAndErrorEventsBecomeInferenceErrors() throws {
        var failed = ResponsesEventAssembler()
        XCTAssertThrowsError(try failed.handle(payload: #"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"boom"}}}"#)) { error in
            guard case InferenceError.httpStatus(let code, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "server_error: boom")
        }
        var limited = ResponsesEventAssembler()
        XCTAssertThrowsError(try limited.handle(payload: #"{"type":"error","code":"rate_limit_exceeded","message":"You have hit your usage limit."}"#)) { error in
            guard case InferenceError.httpStatus(let code, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 429)
        }
        var overflow = ResponsesEventAssembler()
        XCTAssertThrowsError(try overflow.handle(payload: #"{"type":"error","error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model"}}"#)) { error in
            guard case InferenceError.contextTooLarge = error else { return XCTFail("\(error)") }
        }
        var garbage = ResponsesEventAssembler()
        XCTAssertThrowsError(try garbage.handle(payload: "{not json"))
    }

    // MARK: Provider over a mocked session

    func testStreamSendsCodexHeadersAndReplaysReasoningOnTheNextTurn() async throws {
        let residency = accessJWT(expiresIn: 3600, residency: "eu")
        try credentials.set(ChatGPTAuthManager.tokenKey, value: try ChatGPTTokens(accessToken: residency, refreshToken: "rt-1", idToken: idJWT(), expiresIn: nil, source: "pennant").encoded())
        MockURLProtocol.install { _, _ in MockURLProtocol.Response(status: 200, chunks: [Data(sse(toolCallTranscript).utf8)]) }
        let provider = makeProvider(session: MockURLProtocol.makeSession())

        let first = InferenceRequest(messages: [.system("Be brief."), .user("Weather in Lisbon?")], tools: [weatherTool])
        let chunks = try await collect(provider, first)
        XCTAssertEqual(chunks.map(describe), ["reasoning:Thinking", "reasoning:\n\nmore", "text:Hello", "text: there", "tool:call_1 get_weather {\"city\":\"Lisbon\"}", "usage:120/30", "finished:toolCalls"])

        let (request, body) = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.url?.absoluteString, backend.endpoints.responses.absoluteString)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(residency)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct_123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "pennant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session_id"), provider.sessionID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-openai-internal-codex-residency"), "eu")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try JSONValue.from(try XCTUnwrap(body))
        XCTAssertEqual(json["model"]?.stringValue, "gpt-5.6-sol")
        XCTAssertEqual(json["instructions"]?.stringValue, "Be brief.")
        XCTAssertEqual(json["input"]?.arrayValue?.count, 1)
        XCTAssertEqual(provider.replay.count, 1)

        // The follow-up request carries the reasoning item in front of the function_call it produced.
        MockURLProtocol.install { _, _ in MockURLProtocol.Response(status: 200, chunks: [Data(sse(textOnlyTranscript).utf8)]) }
        var history = first.messages
        history.append(.assistant("Hello there", toolCalls: [ToolCall(id: ToolCallID("call_1"), name: "get_weather", arguments: ["city": "Lisbon"])]))
        history.append(.tool(callID: ToolCallID("call_1"), name: "get_weather", parts: [.text("Sunny, 24°C")]))
        let second = try await collect(provider, InferenceRequest(messages: history, tools: [weatherTool]))
        XCTAssertEqual(second.map(describe), ["text:Sunny.", "usage:10/2", "finished:stop"])
        let (_, secondBody) = try XCTUnwrap(MockURLProtocol.requests.last)
        let input = try XCTUnwrap(try JSONValue.from(try XCTUnwrap(secondBody))["input"]?.arrayValue)
        XCTAssertEqual(input.map { $0["type"]?.stringValue ?? "?" }, ["message", "reasoning", "message", "function_call", "function_call_output"])
        XCTAssertEqual(input[1]["encrypted_content"]?.stringValue, "ENC1")
        XCTAssertEqual(input[1]["summary"]?.arrayValue?.count, 2)
        XCTAssertNil(input[1]["id"], "item ids are not replayed with store=false")
        XCTAssertEqual(input[3]["call_id"]?.stringValue, "call_1")
    }

    func testRefusedReasoningReplayIsRetriedWithoutIt() async throws {
        _ = try storeTokens(expiresIn: 3600)
        let provider = makeProvider(session: MockURLProtocol.makeSession())
        provider.replay.store(callIDs: ["call_x"], items: [["type": "reasoning", "summary": [], "encrypted_content": "STALE"]])
        MockURLProtocol.install { _, body in
            let text = String(decoding: body ?? Data(), as: UTF8.self)
            if text.contains("STALE") {
                return MockURLProtocol.Response(status: 400, headers: ["Content-Type": "application/json"], chunks: [Data(#"{"detail":"invalid_encrypted_content: the reasoning item could not be decrypted"}"#.utf8)])
            }
            return MockURLProtocol.Response(status: 200, chunks: [Data(sse(textOnlyTranscript).utf8)])
        }
        let history: [ModelMessage] = [
            .user("Open Safari"),
            .assistant("", toolCalls: [ToolCall(id: ToolCallID("call_x"), name: "open_app", arguments: ["name": "Safari"])]),
            .tool(callID: ToolCallID("call_x"), name: "open_app", parts: [.text("opened")]),
        ]
        let chunks = try await collect(provider, InferenceRequest(messages: history))
        XCTAssertEqual(chunks.map(describe), ["text:Sunny.", "usage:10/2", "finished:stop"])
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(provider.replay.count, 0)
        let retry = try JSONValue.from(try XCTUnwrap(MockURLProtocol.requests.last?.1))
        XCTAssertEqual(retry["include"], [])
    }

    func testHTTPErrorsMapLikeTheOpenAIAdapter() async throws {
        _ = try storeTokens(expiresIn: 3600)
        let provider = makeProvider(session: MockURLProtocol.makeSession())
        MockURLProtocol.install { _, _ in MockURLProtocol.Response(status: 429, headers: ["Content-Type": "application/json"], chunks: [Data(#"{"detail":"usage limit reached"}"#.utf8)]) }
        do { _ = try await collect(provider, InferenceRequest(messages: [.user("hi")])); XCTFail("expected an error") } catch let error as InferenceError {
            guard case .httpStatus(let code, let body) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 429)
            XCTAssertTrue(body.contains("usage limit"))
        }
        MockURLProtocol.install { _, _ in MockURLProtocol.Response(status: 400, headers: ["Content-Type": "application/json"], chunks: [Data(#"{"error":{"message":"Your input exceeds the context window of this model (272000 tokens)"}}"#.utf8)]) }
        do { _ = try await collect(provider, InferenceRequest(messages: [.user("hi")])); XCTFail("expected an error") } catch let error as InferenceError {
            guard case .contextTooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testNotSignedInIsReportedAsUnreachable() async throws {
        let provider = makeProvider()
        let healthy = await provider.healthCheck()
        XCTAssertFalse(healthy)
        do { _ = try await collect(provider, InferenceRequest(messages: [.user("hi")])); XCTFail("expected an error") } catch let error as InferenceError {
            guard case .unreachable(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("No ChatGPT account"))
        }
    }

    // MARK: Refresh against the fake token endpoint

    func test401RefreshesOnceAndRetries() async throws {
        let stale = try storeTokens(expiresIn: 3600, refreshToken: "rt-1")
        backend.validRefreshTokens = ["rt-1"]
        // The stored access token is not accepted by the backend (revoked upstream), so the first request 401s.
        let provider = makeProvider()
        let chunks = try await collect(provider, InferenceRequest(messages: [.user("Weather?")]))
        XCTAssertEqual(chunks.map(describe), ["text:Sunny.", "usage:10/2", "finished:stop"])

        XCTAssertEqual(backend.responsesRequests.count, 2)
        XCTAssertEqual(backend.tokenRequests.count, 1)
        let refresh = backend.tokenRequests[0]
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["refresh_token"], "rt-1")
        XCTAssertEqual(refresh["client_id"], ChatGPTAuthManager.clientID)
        XCTAssertEqual(refresh["scope"], "openid profile email")
        XCTAssertEqual(backend.responsesRequests[0].header("Authorization"), "Bearer \(stale.accessToken)")
        XCTAssertEqual(backend.responsesRequests[1].header("Authorization"), "Bearer \(backend.lastIssuedAccessToken!)")
        XCTAssertEqual(backend.responsesRequests[1].header("chatgpt-account-id"), "acct_123")
        XCTAssertEqual(backend.responsesRequests[1].header("originator"), "pennant")

        let stored = try XCTUnwrap(credentials.get(ChatGPTAuthManager.tokenKey).flatMap(ChatGPTTokens.decode))
        XCTAssertEqual(stored.accessToken, backend.lastIssuedAccessToken)
        XCTAssertEqual(stored.refreshToken, "rt-2")
        XCTAssertNil(stored.refreshFailure)

        // A second 401 in a row (the refreshed token is refused too) is not refreshed again.
        backend.rejectAllResponses = true
        do { _ = try await collect(provider, InferenceRequest(messages: [.user("Again?")])); XCTFail("expected 401") } catch let error as InferenceError {
            guard case .httpStatus(let code, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 401)
        }
        XCTAssertEqual(backend.tokenRequests.count, 2)
    }

    // MARK: The account's models

    /// What the backend lists for Codex clients: ranked by priority, with models it hides from pickers.
    private static let accountModels = Data(#"""
    {"models":[
      {"slug":"gpt-6-luna","display_name":"GPT-6 Luna","context_window":400000,"visibility":"list","priority":2,"input_modalities":["text","image"]},
      {"slug":"gpt-6-sol","display_name":"GPT-6 Sol","context_window":400000,"visibility":"list","priority":1,"input_modalities":["text","image"]},
      {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","priority":5,"input_modalities":["text"]},
      {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","priority":0}
    ]}
    """#.utf8)

    func testTheAccountsOwnModelsAreListed() async throws {
        let tokens = try storeTokens(expiresIn: 3600)
        backend.validAccessTokens = [tokens.accessToken]
        backend.modelsBody = Self.accountModels

        let (models, note) = await auth.availableModels()
        XCTAssertEqual(models.map(\.id), ["gpt-6-sol", "gpt-6-luna", "gpt-5.5"], "ranked by priority, hidden ones left out")
        XCTAssertEqual(models.first?.title, "GPT-6 Sol")
        XCTAssertEqual(models.first?.contextWindowTokens, 400_000)
        XCTAssertEqual(models.last?.supportsVision, false, "text-only models say so")
        XCTAssertEqual(models.last?.contextWindowTokens, 272_000, "a known model keeps its built-in context window when the backend gives none")
        XCTAssertEqual(note, ChatGPTAuthManager.accountNote)
        let request = try XCTUnwrap(backend.modelsRequests.first)
        XCTAssertEqual(request.header("Authorization"), "Bearer \(tokens.accessToken)")
        XCTAssertEqual(request.header("chatgpt-account-id"), "acct_123")
        XCTAssertEqual(request.header("originator"), "pennant")
        XCTAssertEqual(request.query["client_version"], ChatGPTAuthManager.codexClientVersion)

        // Asked again soon, the list comes from memory; signing out drops it.
        _ = await auth.availableModels()
        XCTAssertEqual(backend.modelsRequests.count, 1)
        _ = try await auth.signOut()
        let (signedOut, signedOutNote) = await auth.availableModels()
        XCTAssertEqual(signedOut, ChatGPTAuthManager.models)
        XCTAssertTrue(signedOutNote.hasPrefix("Sign in"), signedOutNote)
    }

    func testARefusedTokenIsRefreshedOnceForTheModelList() async throws {
        _ = try storeTokens(expiresIn: 3600, refreshToken: "rt-1")
        backend.validRefreshTokens = ["rt-1"]
        backend.modelsBody = Self.accountModels

        let (models, _) = await auth.availableModels()
        XCTAssertEqual(models.first?.id, "gpt-6-sol")
        XCTAssertEqual(backend.modelsRequests.count, 2)
        XCTAssertEqual(backend.tokenRequests.count, 1)
        XCTAssertEqual(backend.modelsRequests[1].header("Authorization"), "Bearer \(backend.lastIssuedAccessToken!)")
    }

    func testWhenTheAccountCantBeAskedTheBuiltInListSaysWhy() async throws {
        let tokens = try storeTokens(expiresIn: 3600)
        backend.validAccessTokens = [tokens.accessToken]
        backend.modelsStatus = 503

        let (models, note) = await auth.availableModels()
        XCTAssertEqual(models, ChatGPTAuthManager.models)
        XCTAssertTrue(note.contains("HTTP 503") && note.contains("built-in"), note)

        backend.modelsStatus = 200
        backend.modelsBody = Data(#"{"models":[{"slug":"internal","visibility":"hide"}]}"#.utf8)
        let (fallback, emptyNote) = await auth.availableModels()
        XCTAssertEqual(fallback, ChatGPTAuthManager.models, "an empty list isn't shown as the account's")
        XCTAssertTrue(emptyNote.contains("listed no models"), emptyNote)
    }

    func testRefreshesWhenNearExpiry() async throws {
        _ = try storeTokens(expiresIn: 120, refreshToken: "rt-1")
        backend.validRefreshTokens = ["rt-1"]
        let before = await auth.account()
        XCTAssertEqual(before.expiresAt!.timeIntervalSinceNow, 120, accuracy: 5)

        let (token, accountID) = try await auth.accessToken()
        XCTAssertEqual(token, backend.lastIssuedAccessToken)
        XCTAssertEqual(accountID, "acct_123")
        XCTAssertEqual(backend.tokenRequests.count, 1)
        let after = await auth.account()
        XCTAssertEqual(after.expiresAt!.timeIntervalSinceNow, 3600, accuracy: 5)
        XCTAssertEqual(after.email, "user@example.com")
        XCTAssertNil(after.detail)

        // Fresh enough now: no second refresh.
        _ = try await auth.accessToken()
        XCTAssertEqual(backend.tokenRequests.count, 1)

        // Concurrent callers share one refresh.
        _ = try storeTokens(expiresIn: 60, refreshToken: "rt-1")
        backend.validRefreshTokens = ["rt-1"]
        let manager = auth!
        async let a = manager.accessToken()
        async let b = manager.accessToken()
        let (ta, tb) = try await (a, b)
        XCTAssertEqual(ta.token, tb.token)
        XCTAssertEqual(backend.tokenRequests.count, 2)
    }

    func testRefreshFailureKeepsTheAccountWithADetail() async throws {
        _ = try storeTokens(expiresIn: -10, refreshToken: "rt-dead")
        do { _ = try await auth.accessToken(); XCTFail("expected refreshFailed") } catch let e as ChatGPTAuthError {
            guard case .refreshFailed(let why) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(why.contains("invalid_grant"), why)
        }
        let account = await auth.account()
        XCTAssertTrue(account.signedIn)
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertTrue(account.detail?.contains("Sign in again") == true, account.detail ?? "nil")
        let usable = await auth.isUsable()
        XCTAssertFalse(usable)
        let healthy = await makeProvider().healthCheck()
        XCTAssertFalse(healthy)

        // A refresh token with minutes left on the access token is not fatal.
        _ = try storeTokens(expiresIn: 200, refreshToken: "rt-dead")
        let (token, _) = try await auth.accessToken()
        XCTAssertFalse(token.isEmpty)

        // Signing out clears everything.
        let signedOut = try await auth.signOut()
        XCTAssertFalse(signedOut.signedIn)
        XCTAssertNil(credentials.get(ChatGPTAuthManager.tokenKey))
    }

    // MARK: Browser sign-in against the local listener

    func testBeginSignInBuildsAuthorizeURLAndCompletesOnRedirect() async throws {
        let url: URL = try await auth.beginSignIn()
        XCTAssertTrue(url.absoluteString.hasPrefix(backend.endpoints.authorize.absoluteString + "?"))
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(query["scope"], "openid profile email offline_access")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["id_token_add_organizations"], "true")
        XCTAssertEqual(query["codex_cli_simplified_flow"], "true")
        let state = try XCTUnwrap(query["state"])
        let challenge = try XCTUnwrap(query["code_challenge"])
        XCTAssertGreaterThan(state.count, 20)
        XCTAssertEqual(challenge.count, 43)
        let redirect = try XCTUnwrap(URL(string: try XCTUnwrap(query["redirect_uri"])))
        XCTAssertEqual(redirect.host, "localhost")
        XCTAssertEqual(redirect.path, "/auth/callback")
        let port = try XCTUnwrap(redirect.port)
        backend.expectedCodeChallenge = challenge

        let waiting = await auth.account()
        XCTAssertFalse(waiting.signedIn)
        XCTAssertEqual(waiting.detail, "Waiting for you in the browser")

        // A stray request does not complete the flow.
        let (_, favicon) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual((favicon as? HTTPURLResponse)?.statusCode, 404)

        // The browser lands on the loopback page with the code.
        let (page, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=code-1&state=\(state)")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("You are signed in to ChatGPT."))

        try await waitUntil { await self.auth.account().signedIn }
        let account = await auth.account()
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.accountID, "acct_123")
        XCTAssertEqual(account.plan, "plus")
        XCTAssertEqual(account.source, "pennant")
        XCTAssertNil(account.detail)
        XCTAssertEqual(account.expiresAt!.timeIntervalSinceNow, 3600, accuracy: 5)

        let exchange = try XCTUnwrap(backend.tokenRequests.last)
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["code"], "code-1")
        XCTAssertEqual(exchange["redirect_uri"], "http://localhost:\(port)/auth/callback")
        XCTAssertEqual(exchange["client_id"], ChatGPTAuthManager.clientID)
        XCTAssertEqual(PKCE.challenge(for: exchange["code_verifier"] ?? ""), challenge)

        let stored = try XCTUnwrap(credentials.get(ChatGPTAuthManager.tokenKey).flatMap(ChatGPTTokens.decode))
        XCTAssertEqual(stored.refreshToken, "rt-2")
        XCTAssertNotNil(stored.idToken)

        // The listener is gone once the flow finished.
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=x&state=y")!)
            XCTFail("the listener should have stopped")
        } catch {}
    }

    func testRedirectWithWrongStateOrErrorFailsTheSignIn() async throws {
        let existing = try storeTokens(expiresIn: 3600)
        let url: URL = try await auth.beginSignIn()
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let port = URL(string: query["redirect_uri"]!)!.port!
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=code-1&state=not-it")!)
        try await waitUntil { await self.auth.account().detail?.hasPrefix("Sign-in failed") == true }
        var account = await auth.account()
        XCTAssertTrue(account.detail!.contains("state mismatch"), account.detail!)
        XCTAssertTrue(account.signedIn, "the previous account stays")
        XCTAssertEqual(credentials.get(ChatGPTAuthManager.tokenKey).flatMap(ChatGPTTokens.decode)?.accessToken, existing.accessToken)
        XCTAssertTrue(backend.tokenRequests.isEmpty)

        // The provider's own error page, then a fresh sign-in clears the detail.
        let again: URL = try await auth.beginSignIn()
        let q2 = Dictionary(uniqueKeysWithValues: (URLComponents(url: again, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let port2 = URL(string: q2["redirect_uri"]!)!.port!
        let (page, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port2)/auth/callback?error=access_denied&error_description=The%20user%20declined&state=\(q2["state"]!)")!)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("did not complete"))
        try await waitUntil { await self.auth.account().detail?.contains("access_denied") == true }
        account = await auth.account()
        XCTAssertTrue(account.detail!.contains("The user declined"), account.detail!)
        await auth.cancelSignIn()
        let cleared = await auth.account()
        XCTAssertNil(cleared.detail)
    }

    // MARK: Capabilities and models

    func testCapabilitiesAndModelList() {
        let known = makeProvider(config: chatGPTConfig(model: "gpt-5.6-sol", contextWindowTokens: 8000)).capabilities
        XCTAssertEqual(known.contextWindowTokens, 272_000)
        XCTAssertTrue(known.vision)
        XCTAssertTrue(known.tools)
        XCTAssertEqual(known.endpoint, "chatgpt")
        XCTAssertEqual(known.model, "gpt-5.6-sol")

        let unknown = makeProvider(config: chatGPTConfig(model: "gpt-5.9-preview", contextWindowTokens: 8000)).capabilities
        XCTAssertEqual(unknown.contextWindowTokens, 8000)
        XCTAssertEqual(unknown.model, "gpt-5.9-preview")

        XCTAssertEqual(ChatGPTAuthManager.models.first?.id, "gpt-6.1-sol")
        XCTAssertEqual(Set(ChatGPTAuthManager.models.map(\.id)).count, ChatGPTAuthManager.models.count)
        XCTAssertTrue(ChatGPTAuthManager.models.allSatisfy { $0.contextWindowTokens >= 128_000 })
        XCTAssertEqual(ChatGPTAuthManager.model(withID: "gpt-6-sol")?.contextWindowTokens, 272_000)
    }
}

/// Azure AI Foundry's Responses API: GPT-6 calls tools while reasoning only through it (on Chat Completions it
/// can't). Same body and stream as the ChatGPT provider; the resource's address and Entra token (or key).
final class AzureResponsesProviderTests: XCTestCase {
    actor TokenAuthority: EndpointAuthority {
        var tokens: [String]
        private(set) var refreshed = 0
        init(_ tokens: [String]) { self.tokens = tokens }
        func credential() async throws -> EndpointCredential { EndpointCredential(bearer: tokens[0], baseURL: "https://res.cognitiveservices.azure.com/openai/v1") }
        func refreshCredential(rejected: EndpointCredential) async throws -> EndpointCredential {
            refreshed += 1
            tokens.removeFirst()
            return try await credential()
        }
    }

    private func azure(_ model: String, api: String? = nil) -> HostConfig.Inference {
        var c = HostConfig.Inference(baseURL: "https://res.cognitiveservices.azure.com/openai/v1", model: model, provider: HostConfig.Inference.azureProvider)
        c.azure = HostConfig.Inference.Azure(subscriptionID: "sub", resourceGroup: "rg", resource: "res")
        c.api = api
        return c
    }

    private func collect(_ provider: AzureResponsesProvider, _ request: InferenceRequest) async throws -> [InferenceChunk] {
        var chunks: [InferenceChunk] = []
        for try await chunk in provider.stream(request) { chunks.append(chunk) }
        return chunks
    }

    func testGPT6OnAzureUsesTheResponsesAPIUnlessSetOtherwise() throws {
        XCTAssertTrue(azure("gpt-6-sol").usesResponsesAPI)
        XCTAssertTrue(azure("GPT-6-luna").usesResponsesAPI)
        XCTAssertFalse(azure("gpt-5.4").usesResponsesAPI)
        XCTAssertFalse(azure("gpt-6-sol", api: "chat").usesResponsesAPI)
        XCTAssertTrue(azure("gpt-5.4", api: "responses").usesResponsesAPI)
        XCTAssertFalse(HostConfig.Inference(model: "gpt-6-sol").usesResponsesAPI, "only on Azure")
        let back = try JSONDecoder().decode(HostConfig.Inference.self, from: JSONEncoder().encode(azure("gpt-6-sol", api: "chat")))
        XCTAssertEqual(back.api, "chat")
    }

    func testTheHostPicksTheResponsesProviderForGPT6() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("azr-\(UUID())")
        let chatGPT = ChatGPTAuthManager(credentials: KeychainCredentialStore(keychain: KeychainStore(service: "test.azr", fallbackFileURL: dir.appendingPathComponent("c.json"), preferFile: true)), codexAuthFile: dir.appendingPathComponent("auth.json"))
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        let vault = VaultService(store: try SQLiteStore(paths: paths), keychain: KeychainStore(service: "test.azv", fallbackFileURL: dir.appendingPathComponent("v.json"), preferFile: true))
        XCTAssertTrue(HostService.makeProvider(azure("gpt-6-sol"), chatGPT: chatGPT, vault: vault) is AzureResponsesProvider)
        XCTAssertTrue(HostService.makeProvider(azure("gpt-5.4"), chatGPT: chatGPT, vault: vault) is OpenAICompatibleProvider)
    }

    func testItStreamsToolCallsWithReasoningAndReplaysReasoningNextTurn() async throws {
        MockURLProtocol.install { _, _ in MockURLProtocol.Response(status: 200, chunks: [Data(sse(toolCallTranscript).utf8)]) }
        let provider = AzureResponsesProvider(config: azure("gpt-6-sol"), authority: TokenAuthority(["entra-token"]), session: MockURLProtocol.makeSession())
        let first = InferenceRequest(messages: [ModelMessage(role: .system, parts: [.text("Be brief.")]), .user("Weather in Lisbon?")], tools: [weatherTool], reasoningEffort: "high")
        let chunks = try await collect(provider, first).map(describe)
        XCTAssertTrue(chunks.contains(#"tool:call_1 get_weather {"city":"Lisbon"}"#), "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.hasPrefix("reasoning:") }, "it reasons while calling tools")
        let (request, bodyData) = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.url?.absoluteString, "https://res.cognitiveservices.azure.com/openai/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer entra-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "chatgpt-account-id"), "no ChatGPT headers")
        let body = try JSONValue.from(try XCTUnwrap(bodyData))
        XCTAssertEqual(body["model"]?.stringValue, "gpt-6-sol")
        XCTAssertEqual(body["reasoning"]?["effort"]?.stringValue, "high")
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["name"]?.stringValue, "get_weather")

        // The follow-up carries the encrypted reasoning back in front of the call.
        MockURLProtocol.install { _, _ in MockURLProtocol.Response(status: 200, chunks: [Data(sse(textOnlyTranscript).utf8)]) }
        let call = ToolCall(id: ToolCallID("call_1"), name: "get_weather", arguments: ["city": "Lisbon"])
        let second = InferenceRequest(messages: [.user("Weather in Lisbon?"), ModelMessage(role: .assistant, parts: [], toolCalls: [call]),
                                                 ModelMessage(role: .tool, parts: [.text("Sunny")], toolCallID: ToolCallID("call_1"), toolName: "get_weather")], tools: [weatherTool])
        _ = try await collect(provider, second)
        let secondBody = try JSONValue.from(try XCTUnwrap(MockURLProtocol.requests.last?.1))
        let input = secondBody["input"]?.arrayValue ?? []
        XCTAssertTrue(input.contains { $0["type"]?.stringValue == "reasoning" && $0["encrypted_content"]?.stringValue == "ENC1" }, "\(input)")
    }

    func testAKeyIsSentAsItsHeaderAndARefusedTokenIsRefreshedOnce() async throws {
        MockURLProtocol.install { _, _ in MockURLProtocol.Response(status: 200, chunks: [Data(sse(textOnlyTranscript).utf8)]) }
        let keyed = AzureResponsesProvider(config: azure("gpt-6-luna"), authority: StaticHeaderAuthority(baseURL: "https://res.cognitiveservices.azure.com/openai/v1", headers: ["api-key": "k-123"]), session: MockURLProtocol.makeSession())
        _ = try await collect(keyed, InferenceRequest(messages: [.user("hi")]))
        let (keyRequest, _) = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(keyRequest.value(forHTTPHeaderField: "api-key"), "k-123")
        XCTAssertNil(keyRequest.value(forHTTPHeaderField: "Authorization"))

        MockURLProtocol.install { request, _ in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer old"
                ? MockURLProtocol.Response(status: 401, chunks: [Data(#"{"error":{"message":"expired"}}"#.utf8)])
                : MockURLProtocol.Response(status: 200, chunks: [Data(sse(textOnlyTranscript).utf8)])
        }
        let authority = TokenAuthority(["old", "new"])
        let entra = AzureResponsesProvider(config: azure("gpt-6-sol"), authority: authority, session: MockURLProtocol.makeSession())
        let chunks = try await collect(entra, InferenceRequest(messages: [.user("hi")])).map(describe)
        XCTAssertTrue(chunks.contains("text:Sunny."))
        let refreshed = await authority.refreshed
        XCTAssertEqual(refreshed, 1)
    }
}
