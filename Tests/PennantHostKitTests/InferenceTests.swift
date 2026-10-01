import CoreGraphics
import PennantCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PennantHostKit

// MARK: - URLProtocol mock

/// Serves canned responses for the inference provider. Each handler receives the request
/// (with its body materialised) and returns a status, headers, and body chunks that are
/// delivered one at a time to simulate streaming.
final class MockURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data]
    }

    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest, Data?) -> Response)?
    nonisolated(unsafe) private static var recordedRequests: [(URLRequest, Data?)] = []
    private static let lock = NSLock()

    static func install(_ handler: @escaping @Sendable (URLRequest, Data?) -> Response) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        recordedRequests = []
    }

    static var requests: [(URLRequest, Data?)] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        Self.lock.lock()
        Self.recordedRequests.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = handler(request, body)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - Helpers

private func sse(_ objects: [String]) -> Data {
    Data((objects.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8)
}

private func delta(_ content: String? = nil, reasoning: String? = nil, toolCalls: String? = nil, finish: String? = nil) -> String {
    var deltaFields: [String] = []
    if let content { deltaFields.append("\"content\": \(quoted(content))") }
    if let reasoning { deltaFields.append("\"reasoning_content\": \(quoted(reasoning))") }
    if let toolCalls { deltaFields.append("\"tool_calls\": \(toolCalls)") }
    let finishJSON = finish.map { "\"\($0)\"" } ?? "null"
    return #"{"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{\#(deltaFields.joined(separator: ","))},"finish_reason":\#(finishJSON)}]}"#
}

private func quoted(_ s: String) -> String {
    String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
}

private func testConfig(supportsTools: Bool = true, supportsVision: Bool = true) -> HostConfig.Inference {
    HostConfig.Inference(baseURL: "http://mock.local/v1", model: "test-model", contextWindowTokens: 8000, supportsVision: supportsVision, supportsTools: supportsTools)
}

private func makeProvider(supportsTools: Bool = true, supportsVision: Bool = true) -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(config: testConfig(supportsTools: supportsTools, supportsVision: supportsVision), session: MockURLProtocol.makeSession())
}

private func collect(_ provider: OpenAICompatibleProvider, _ request: InferenceRequest) async throws -> [InferenceChunk] {
    var chunks: [InferenceChunk] = []
    for try await chunk in provider.stream(request) { chunks.append(chunk) }
    return chunks
}

private func makeJPEG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private let weatherTool = ToolSpec(
    name: "get_weather",
    description: "Get the current weather for a city.",
    inputSchema: [
        "type": "object",
        "properties": ["city": ["type": "string", "description": "City name"]],
        "required": ["city"],
        "additionalProperties": false,
    ]
)

// MARK: - Tests

final class SSEParserTests: XCTestCase {
    func testSplitsEventsAcrossChunksAndTolerantOfCRLF() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("data: {\"a\":1}\r\n\r\ndata: {\"b\"".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(parser.feed(Data(":2}\n: comment\nevent: x\n\ndata:{\"c\":3}\n".utf8)), ["{\"b\":2}", "{\"c\":3}"])
        XCTAssertEqual(parser.feed(Data("data: [DONE]".utf8)), [])
        XCTAssertEqual(parser.flush(), ["[DONE]"])
    }

    func testMultipleEventsInOneChunk() {
        var parser = SSEParser()
        let payloads = parser.feed(sse(["{\"n\":1}", "{\"n\":2}", "{\"n\":3}"]))
        XCTAssertEqual(payloads, ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}", "[DONE]"])
    }
}

final class TokenEstimatorTests: XCTestCase {
    func testTextAndImageEstimates() {
        XCTAssertEqual(TokenEstimator.tokens(forText: ""), 0)
        XCTAssertEqual(TokenEstimator.tokens(forText: String(repeating: "a", count: 360)), 100)
        let jpeg = makeJPEG(width: 560, height: 280, red: 1, green: 0, blue: 0)
        XCTAssertEqual(TokenEstimator.tokens(forImage: jpeg), 200)
        XCTAssertEqual(TokenEstimator.tokens(forImage: Data([0, 1, 2])), TokenEstimator.unknownImageTokens)
        XCTAssertEqual(TokenEstimator.tokens(forImageWidth: 4000, height: 4000), TokenEstimator.maxTokensPerImage)
        let messages: [ModelMessage] = [.system("You are Pennant."), .user("Hello")]
        XCTAssertGreaterThan(TokenEstimator.tokens(for: messages, tools: [weatherTool]), TokenEstimator.tokens(for: messages, tools: []))
    }
}

final class InferenceTests: XCTestCase {
    func testTextStreamingAndUsage() async throws {
        MockURLProtocol.install { _, _ in
            let chunks = [
                delta("Hel"), delta("lo"), delta(" there", finish: "stop"),
                #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#,
            ]
            // Deliver byte-split chunks to exercise incremental parsing.
            let data = sse(chunks)
            let mid = data.count / 3
            return .init(status: 200, chunks: [data.prefix(mid), data.subdata(in: mid ..< 2 * mid), data.suffix(from: 2 * mid)])
        }
        let provider = makeProvider()
        let response = try await provider.complete(InferenceRequest(messages: [.user("hi")]))
        XCTAssertEqual(response.text, "Hello there")
        XCTAssertEqual(response.usage.inputTokens, 12)
        XCTAssertEqual(response.usage.outputTokens, 3)
        XCTAssertEqual(response.finishReason, .stop)
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    func testUsageArrivesBeforeFinished() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([delta("x", finish: "stop"), #"{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#])])
        }
        let chunks = try await collect(makeProvider(), InferenceRequest(messages: [.user("hi")]))
        guard case .finished = chunks.last else { return XCTFail("last chunk must be finished, got \(chunks)") }
        XCTAssertTrue(chunks.contains { if case .usage = $0 { return true } else { return false } })
    }

    func testReasoningDeltas() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([delta(reasoning: "Let me "), delta(reasoning: "think."), delta("Answer", finish: "stop")])])
        }
        let response = try await makeProvider().complete(InferenceRequest(messages: [.user("q")]))
        XCTAssertEqual(response.reasoning, "Let me think.")
        XCTAssertEqual(response.text, "Answer")
    }

    func testToolCallSplitAcrossManyDeltas() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([
                delta(toolCalls: #"[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_","arguments":""}}]"#),
                delta(toolCalls: #"[{"index":0,"function":{"name":"weather"}}]"#),
                delta(toolCalls: #"[{"index":0,"function":{"arguments":"{\"ci"}}]"#),
                delta(toolCalls: #"[{"index":0,"function":{"arguments":"ty\": \"Lis"}}]"#),
                delta(toolCalls: #"[{"index":0,"function":{"arguments":"bon\"}"}}]"#),
                delta(finish: "tool_calls"),
            ])])
        }
        let response = try await makeProvider().complete(InferenceRequest(messages: [.user("weather?")], tools: [weatherTool]))
        XCTAssertEqual(response.finishReason, .toolCalls)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id.rawValue, "call_abc")
        XCTAssertEqual(response.toolCalls.first?.name, "get_weather")
        XCTAssertEqual(response.toolCalls.first?.arguments["city"]?.stringValue, "Lisbon")
    }

    func testTwoParallelToolCallsWithMissingIDs() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([
                delta(toolCalls: #"[{"index":0,"function":{"name":"get_weather","arguments":"{\"city\":\"Lisbon\"}"}},{"index":1,"function":{"name":"get_weather","arguments":"{\"city\":"}}]"#),
                delta(toolCalls: #"[{"index":1,"function":{"arguments":"\"Porto\"}"}}]"#),
                delta(finish: "tool_calls"),
            ])])
        }
        let response = try await makeProvider().complete(InferenceRequest(messages: [.user("weather?")], tools: [weatherTool]))
        XCTAssertEqual(response.toolCalls.count, 2)
        XCTAssertEqual(response.toolCalls.map { $0.arguments["city"]?.stringValue }, ["Lisbon", "Porto"])
        XCTAssertFalse(response.toolCalls[0].id.rawValue.isEmpty)
        XCTAssertNotEqual(response.toolCalls[0].id, response.toolCalls[1].id)
    }

    func testToolCallWithoutFinishReasonStillEmittedAtStreamEnd() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([
                delta(toolCalls: #"[{"index":0,"id":"c1","function":{"name":"get_weather","arguments":"{\"city\":\"Faro\"}"}}]"#),
            ])])
        }
        let response = try await makeProvider().complete(InferenceRequest(messages: [.user("weather?")], tools: [weatherTool]))
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.finishReason, .toolCalls)
    }

    func testMalformedArgumentsAreWrappedNotDropped() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([
                delta(toolCalls: #"[{"index":0,"id":"c1","function":{"name":"get_weather","arguments":"{\"city\": \"Lis"}}]"#),
                delta(finish: "length"),
            ])])
        }
        let response = try await makeProvider().complete(InferenceRequest(messages: [.user("weather?")], tools: [weatherTool]))
        XCTAssertEqual(response.finishReason, .length)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.arguments["_raw"]?.stringValue, "{\"city\": \"Lis")
    }

    func testObjectArgumentsFromEndpointAreAccepted() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([
                delta(toolCalls: #"[{"index":0,"id":"c1","function":{"name":"get_weather","arguments":{"city":"Braga"}}}]"#),
                delta(finish: "tool_calls"),
            ])])
        }
        let response = try await makeProvider().complete(InferenceRequest(messages: [.user("weather?")], tools: [weatherTool]))
        XCTAssertEqual(response.toolCalls.first?.arguments["city"]?.stringValue, "Braga")
    }

    func testHTTPErrorMapping() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 400, headers: ["Content-Type": "application/json"], chunks: [Data(#"{"error":{"message":"model not found"}}"#.utf8)])
        }
        do {
            _ = try await makeProvider().complete(InferenceRequest(messages: [.user("hi")]))
            XCTFail("expected an error")
        } catch let error as InferenceError {
            guard case .httpStatus(let code, let body) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code, 400)
            XCTAssertTrue(body.contains("model not found"))
        }
    }

    func testContextTooLargeMapping() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 400, headers: ["Content-Type": "application/json"], chunks: [Data(#"{"error":{"message":"This model's maximum context length is 8192 tokens. However, you requested 9000 tokens.","type":"invalid_request_error"}}"#.utf8)])
        }
        do {
            _ = try await makeProvider().complete(InferenceRequest(messages: [.user(String(repeating: "word ", count: 100))]))
            XCTFail("expected an error")
        } catch let error as InferenceError {
            guard case .contextTooLarge(let estimated, let limit) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(limit, 8192)
            XCTAssertGreaterThan(estimated, 0)
        }
    }

    func testStreamedErrorPayloadIsSurfaced() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [Data("data: {\"error\":{\"message\":\"backend exploded\",\"code\":503}}\n\n".utf8)])
        }
        do {
            _ = try await makeProvider().complete(InferenceRequest(messages: [.user("hi")]))
            XCTFail("expected an error")
        } catch let error as InferenceError {
            guard case .httpStatus(let code, let message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code, 503)
            XCTAssertEqual(message, "backend exploded")
        }
    }

    func testUnreachableEndpointMapsToUnreachable() async throws {
        let config = HostConfig.Inference(baseURL: "http://127.0.0.1:1/v1", model: "x", requestTimeout: 5)
        let provider = OpenAICompatibleProvider(config: config)
        do {
            _ = try await provider.complete(InferenceRequest(messages: [.user("hi")]))
            XCTFail("expected an error")
        } catch let error as InferenceError {
            guard case .unreachable = error else { return XCTFail("wrong error \(error)") }
        }
        let healthy = await provider.healthCheck()
        XCTAssertFalse(healthy)
    }

    func testCancellationEndsStream() async throws {
        MockURLProtocol.install { _, _ in
            // A long stream with no terminator; the consumer cancels early.
            .init(status: 200, chunks: (0 ..< 200).map { _ in Data("data: \(delta("tick "))\n\n".utf8) })
        }
        let provider = makeProvider()
        let task = Task { () -> Int in
            var count = 0
            for try await chunk in provider.stream(InferenceRequest(messages: [.user("hi")])) {
                if case .textDelta = chunk { count += 1 }
                if count == 3 { break }
            }
            return count
        }
        let count = try await task.value
        XCTAssertEqual(count, 3)
    }

    func testRequestBodyRendersToolsImagesAndToolResults() async throws {
        MockURLProtocol.install { _, _ in .init(status: 200, chunks: [sse([delta("ok", finish: "stop")])]) }
        let jpeg = makeJPEG(width: 8, height: 8, red: 0, green: 0, blue: 1)
        let call = ToolCall(id: ToolCallID("call_1"), name: "get_weather", arguments: ["city": "Lisbon"])
        let request = InferenceRequest(
            messages: [
                .system("You are Pennant."),
                ModelMessage(role: .user, parts: [.text("Look at this"), .image(data: jpeg, mimeType: "image/jpeg")]),
                .assistant("Checking", toolCalls: [call]),
                .tool(callID: call.id, name: "get_weather", parts: [.text("Sunny"), .image(data: jpeg, mimeType: "image/jpeg")]),
            ],
            tools: [weatherTool],
            maxOutputTokens: 512,
            temperature: 0.1,
            jsonMode: true
        )
        _ = try await makeProvider().complete(request)

        let (urlRequest, bodyData) = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(urlRequest.url?.absoluteString, "http://mock.local/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONValue.from(try XCTUnwrap(bodyData))
        XCTAssertEqual(body["model"]?.stringValue, "test-model")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body["stream_options"]?["include_usage"]?.boolValue, true)
        XCTAssertEqual(body["max_tokens"]?.intValue, 512)
        XCTAssertEqual(body["temperature"]?.doubleValue, 0.1)
        XCTAssertEqual(body["tool_choice"]?.stringValue, "auto")
        XCTAssertEqual(body["response_format"]?["type"]?.stringValue, "json_object")

        let tools = try XCTUnwrap(body["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"]?.stringValue, "function")
        XCTAssertEqual(tools[0]["function"]?["name"]?.stringValue, "get_weather")
        XCTAssertEqual(tools[0]["function"]?["parameters"]?["type"]?.stringValue, "object")

        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 5, "tool message with an image yields a follow-up user message")
        XCTAssertEqual(messages[0]["role"]?.stringValue, "system")
        XCTAssertEqual(messages[0]["content"]?.stringValue, "You are Pennant.")

        let userParts = try XCTUnwrap(messages[1]["content"]?.arrayValue)
        XCTAssertEqual(userParts[0]["type"]?.stringValue, "text")
        XCTAssertEqual(userParts[1]["type"]?.stringValue, "image_url")
        let uri = try XCTUnwrap(userParts[1]["image_url"]?["url"]?.stringValue)
        XCTAssertTrue(uri.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertEqual(Data(base64Encoded: String(uri.dropFirst("data:image/jpeg;base64,".count))), jpeg)

        XCTAssertEqual(messages[2]["role"]?.stringValue, "assistant")
        XCTAssertEqual(messages[2]["content"]?.stringValue, "Checking")
        let toolCalls = try XCTUnwrap(messages[2]["tool_calls"]?.arrayValue)
        XCTAssertEqual(toolCalls[0]["id"]?.stringValue, "call_1")
        XCTAssertEqual(toolCalls[0]["function"]?["name"]?.stringValue, "get_weather")
        XCTAssertEqual(toolCalls[0]["function"]?["arguments"]?.stringValue, "{\"city\":\"Lisbon\"}")

        XCTAssertEqual(messages[3]["role"]?.stringValue, "tool")
        XCTAssertEqual(messages[3]["tool_call_id"]?.stringValue, "call_1")
        XCTAssertEqual(messages[3]["content"]?.stringValue, "Sunny")

        XCTAssertEqual(messages[4]["role"]?.stringValue, "user")
        let followUp = try XCTUnwrap(messages[4]["content"]?.arrayValue)
        XCTAssertEqual(followUp[0]["text"]?.stringValue, "Result image for tool call call_1")
        XCTAssertEqual(followUp[1]["type"]?.stringValue, "image_url")
    }

    func testVisionDisabledReplacesImagesWithNote() {
        let jpeg = makeJPEG(width: 8, height: 8, red: 0, green: 1, blue: 0)
        let request = InferenceRequest(messages: [ModelMessage(role: .user, parts: [.text("see"), .image(data: jpeg, mimeType: "image/jpeg")])])
        let body = OpenAICompatibleProvider.requestBody(for: request, config: testConfig(supportsVision: false))
        let parts = body["messages"]?[0]?["content"]?.arrayValue
        XCTAssertEqual(parts?[1]["type"]?.stringValue, "text")
        XCTAssertEqual(parts?[1]["text"]?.stringValue, "[image omitted: \(jpeg.count) bytes]")
    }

    func testDisableToolsOmitsToolsField() {
        let request = InferenceRequest(messages: [.user("hi")], tools: [weatherTool], disableTools: true)
        let body = OpenAICompatibleProvider.requestBody(for: request, config: testConfig())
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
    }

    func testPromptedToolFallbackWhenEndpointLacksNativeTools() async throws {
        MockURLProtocol.install { _, _ in
            .init(status: 200, chunks: [sse([
                delta("I'll check that. "),
                delta("<tool_call>{\"name\": \"get_weather\", "),
                delta("\"arguments\": {\"city\": \"Lisbon\"}}</tool_call>", finish: "stop"),
            ])])
        }
        let provider = makeProvider(supportsTools: false)
        let response = try await provider.complete(InferenceRequest(messages: [.user("weather in Lisbon?")], tools: [weatherTool]))
        XCTAssertEqual(response.text, "I'll check that.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "get_weather")
        XCTAssertEqual(response.toolCalls.first?.arguments["city"]?.stringValue, "Lisbon")
        XCTAssertEqual(response.finishReason, .toolCalls)

        let (_, bodyData) = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = try JSONValue.from(try XCTUnwrap(bodyData))
        XCTAssertNil(body["tools"], "prompted mode must not send native tools")
        let systemTexts = body["messages"]?.arrayValue?.filter { $0["role"]?.stringValue == "system" }.compactMap { $0["content"]?.stringValue } ?? []
        XCTAssertTrue(systemTexts.contains { $0.contains("get_weather") && $0.contains("<tool_call>") })
    }

    func testPromptedFallbackParsesFencedJSON() {
        let text = "Sure.\n```json\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Porto\"}}\n```\nDone."
        let (cleaned, calls) = ChunkAssembler.extractPromptedToolCalls(from: text, allowedNames: ["get_weather"])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments["city"]?.stringValue, "Porto")
        XCTAssertEqual(cleaned, "Sure.\n\nDone.")
        let (unchanged, none) = ChunkAssembler.extractPromptedToolCalls(from: "```json\n{\"name\": \"unknown_tool\", \"arguments\": {}}\n```", allowedNames: ["get_weather"])
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(unchanged.isEmpty)
    }

    func testContextLimitExtraction() {
        XCTAssertEqual(OpenAICompatibleProvider.contextLimit(from: "This model's maximum context length is 131072 tokens."), 131072)
        XCTAssertNil(OpenAICompatibleProvider.contextLimit(from: "nothing here"))
        XCTAssertTrue(OpenAICompatibleProvider.looksLikeContextOverflow("Requested tokens exceed the context window of 4096"))
        XCTAssertFalse(OpenAICompatibleProvider.looksLikeContextOverflow("model not found"))
    }

    func testEmbeddingProviderBatches() async throws {
        MockURLProtocol.install { _, body in
            let input = (try? JSONValue.from(body ?? Data()))?["input"]?.arrayValue ?? []
            let items = input.indices.reversed().map { i in "{\"index\":\(i),\"embedding\":[\(Double(i)),0.5,0.25]}" }
            return .init(status: 200, headers: ["Content-Type": "application/json"], chunks: [Data("{\"data\":[\(items.joined(separator: ","))]}".utf8)])
        }
        let provider = OpenAIEmbeddingProvider(config: HostConfig.Embeddings(enabled: true, baseURL: "http://mock.local/v1", model: "emb"), session: MockURLProtocol.makeSession())
        let vectors = try await provider.embed((0 ..< 70).map { "text \($0)" })
        XCTAssertEqual(vectors.count, 70)
        XCTAssertEqual(MockURLProtocol.requests.count, 3, "70 inputs in batches of 32")
        XCTAssertEqual(vectors[0], [0, 0.5, 0.25])
        XCTAssertEqual(vectors[31], [31, 0.5, 0.25])
        XCTAssertEqual(vectors[32], [0, 0.5, 0.25], "second batch restarts at index 0")
    }
}

// MARK: - Live smoke test (PENNANT_LIVE_INFERENCE=1)

final class LiveInferenceTests: XCTestCase {
    private var liveConfig: HostConfig.Inference? {
        guard ProcessInfo.processInfo.environment["PENNANT_LIVE_INFERENCE"] == "1" else { return nil }
        let env = ProcessInfo.processInfo.environment
        return HostConfig.Inference(
            baseURL: env["PENNANT_LIVE_BASE_URL"] ?? "http://localhost:11434/v1",
            model: env["PENNANT_LIVE_MODEL"] ?? "gemma4:e2b-it-qat",
            contextWindowTokens: 32_000,
            maxOutputTokens: 256,
            temperature: 0,
            requestTimeout: 120
        )
    }

    func testLiveVisionAndToolCall() async throws {
        guard let config = liveConfig else { throw XCTSkip("Set PENNANT_LIVE_INFERENCE=1 to run against a live endpoint") }
        let provider = OpenAICompatibleProvider(config: config)
        let healthy = await provider.healthCheck()
        XCTAssertTrue(healthy, "endpoint \(config.baseURL) is not reachable")

        // Vision
        let jpeg = makeJPEG(width: 64, height: 64, red: 1, green: 0, blue: 0)
        let visionStart = Date()
        let vision = try await provider.complete(InferenceRequest(
            messages: [ModelMessage(role: .user, parts: [.text("What colour is this image? Answer in one word."), .image(data: jpeg, mimeType: "image/jpeg")])],
            maxOutputTokens: 1024, // thinking models spend output budget on reasoning first
            temperature: 0
        ))
        let visionSeconds = Date().timeIntervalSince(visionStart)
        print("LIVE vision: \(String(format: "%.2f", visionSeconds))s text=\(vision.text.debugDescription) reasoningChars=\(vision.reasoning.count) usage=\(vision.usage)")
        XCTAssertTrue(vision.text.lowercased().contains("red"), "expected 'red' in \(vision.text)")

        // Tools
        let toolStart = Date()
        var firstChunkSeconds: TimeInterval?
        var response = InferenceResponse()
        for try await chunk in provider.stream(InferenceRequest(
            messages: [.user("Use the tool to get the weather in Lisbon.")],
            tools: [weatherTool],
            maxOutputTokens: 1024,
            temperature: 0
        )) {
            if firstChunkSeconds == nil { firstChunkSeconds = Date().timeIntervalSince(toolStart) }
            switch chunk {
            case .textDelta(let t): response.text += t
            case .reasoningDelta(let r): response.reasoning += r
            case .toolCall(let c): response.toolCalls.append(c)
            case .usage(let u): response.usage = u
            case .finished(let f): response.finishReason = f
            }
        }
        let toolSeconds = Date().timeIntervalSince(toolStart)
        print("LIVE tools: \(String(format: "%.2f", toolSeconds))s first-chunk=\(String(format: "%.2f", firstChunkSeconds ?? -1))s calls=\(response.toolCalls) finish=\(response.finishReason) reasoningChars=\(response.reasoning.count) usage=\(response.usage)")
        XCTAssertEqual(response.toolCalls.first?.name, "get_weather", "expected a get_weather tool call; text was \(response.text.debugDescription)")
        XCTAssertNotNil(response.toolCalls.first?.arguments["city"]?.stringValue)
    }
}

final class CommandTokenAuthorityTests: XCTestCase {
    func testRunsTheCommandCachesAndRefreshes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("n")
        // Prints token-1, token-2, … on successive runs.
        let auth = CommandTokenAuthority(command: "n=$(cat '\(counter.path)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(counter.path)'; echo token-$n", baseURL: "https://example/v1")
        let first = try await auth.credential()
        XCTAssertEqual(first.bearer, "token-1")
        XCTAssertEqual(first.baseURL, "https://example/v1")
        let again = try await auth.credential()
        XCTAssertEqual(again.bearer, "token-1", "cached until it nears expiry")
        let refreshed = try await auth.refreshCredential(rejected: first)
        XCTAssertEqual(refreshed.bearer, "token-2")
        XCTAssertTrue(auth.shouldRetry(status: 401, body: "", attempt: 0))
        XCTAssertFalse(auth.shouldRetry(status: 401, body: "", attempt: 1))
        XCTAssertFalse(auth.shouldRetry(status: 403, body: "Public access is disabled", attempt: 0))
    }

    func testReadsJWTExpiryAndReportsFailures() async throws {
        let payload = Data(#"{"exp":2000000000}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CommandTokenAuthority.expiry(of: "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"), Date(timeIntervalSince1970: 2_000_000_000 - 300))
        XCTAssertNil(CommandTokenAuthority.expiry(of: "plain-token"))
        let failing = CommandTokenAuthority(command: "echo nope >&2; exit 3", baseURL: "https://example/v1")
        do { _ = try await failing.credential(); XCTFail("a failing command must throw") } catch {
            XCTAssertTrue(String(describing: error).contains("exit 3"))
        }
    }
}
