import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest
#if canImport(FoundationModels) && os(macOS)
import FoundationModels
#endif

/// Pure parts run everywhere; framework bridge tests need macOS 26; live tests also need Apple
/// Intelligence switched on and skip cleanly otherwise.
final class AppleOnDeviceProviderTests: XCTestCase {
    // MARK: - Message preparation

    func testPrepareSplitsInstructionsHistoryAndPrompt() {
        let request = InferenceRequest(messages: [
            .system("You are Pennant."),
            .system("Be brief."),
            .user("List my documents"),
            .assistant("I will list them.", toolCalls: [ToolCall(id: ToolCallID("call_1"), name: "list_directory", arguments: .object(["path": .string("/Users/you/Documents")]))]),
            .tool(callID: ToolCallID("call_1"), name: "list_directory", parts: [.text("a.txt\nb.txt")]),
            .user("[Runtime notes]\nRemember to summarise."),
        ])
        let turn = AppleOnDeviceProvider.prepare(request)
        XCTAssertEqual(turn.instructions, "You are Pennant.\n\nBe brief.")
        XCTAssertEqual(turn.history.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(turn.prompt, "[Runtime notes]\nRemember to summarise.")
    }

    func testPrepareContinuesAfterTrailingToolResultsAndHonoursJSONMode() {
        var request = InferenceRequest(messages: [
            .system("sys"),
            .user("What time is it?"),
            .assistant("", toolCalls: [ToolCall(id: ToolCallID("c1"), name: "get_time", arguments: .object([:]))]),
            .tool(callID: ToolCallID("c1"), name: "get_time", parts: [.text("14:32")]),
        ])
        let turn = AppleOnDeviceProvider.prepare(request)
        XCTAssertEqual(turn.prompt, AppleOnDeviceProvider.continueAfterToolsPrompt)
        XCTAssertEqual(turn.history.last?.role, .tool)
        XCTAssertEqual(turn.history.count, 3)

        request.jsonMode = true
        XCTAssertTrue(AppleOnDeviceProvider.prepare(request).instructions.hasSuffix("Reply with a single JSON object and nothing else."))

        let assistantLast = InferenceRequest(messages: [.system("sys"), .user("hi"), .assistant("hello")])
        XCTAssertEqual(AppleOnDeviceProvider.prepare(assistantLast).prompt, AppleOnDeviceProvider.continuePrompt)
    }

    func testImagesAreDroppedWithANote() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let request = InferenceRequest(messages: [
            .system("sys"),
            ModelMessage(role: .user, parts: [.text("earlier"), .image(data: png, mimeType: "image/png")]),
            .assistant("ok"),
            ModelMessage(role: .user, parts: [.image(data: png, mimeType: "image/png"), .text("what is on screen?"), .image(data: png, mimeType: "image/png")]),
        ])
        let turn = AppleOnDeviceProvider.prepare(request)
        XCTAssertEqual(turn.prompt, "what is on screen?\n" + AppleOnDeviceProvider.imageOmittedNote)
        XCTAssertEqual(turn.history.first?.parts, [.text("earlier"), .text(AppleOnDeviceProvider.imageOmittedNote)])
        for message in turn.history {
            for part in message.parts {
                if case .image = part { XCTFail("an image part survived stripping") }
            }
        }
        XCTAssertEqual(AppleOnDeviceProvider.stripImages(.user("plain")), .user("plain"))
    }

    func testTextDeltaHandlesCumulativeSnapshots() {
        XCTAssertEqual(AppleOnDeviceProvider.textDelta(previous: "", current: "Hel"), "Hel")
        XCTAssertEqual(AppleOnDeviceProvider.textDelta(previous: "Hel", current: "Hello"), "lo")
        XCTAssertEqual(AppleOnDeviceProvider.textDelta(previous: "Hello", current: "Hello"), "")
        XCTAssertEqual(AppleOnDeviceProvider.textDelta(previous: "Hi there", current: "Hi you"), "you")
    }

    func testCapabilitiesDescribeTheOnDeviceModel() {
        let provider = AppleOnDeviceProvider()
        XCTAssertFalse(provider.capabilities.vision)
        XCTAssertTrue(provider.capabilities.tools)
        XCTAssertEqual(provider.capabilities.model, "apple-on-device")
        XCTAssertEqual(provider.capabilities.endpoint, "on-device")
        XCTAssertTrue([4096, 8192].contains(provider.capabilities.contextWindowTokens))
        XCTAssertGreaterThan(provider.estimateTokens([.user("hello there")], tools: []), 0)
        XCTAssertFalse(AppleOnDeviceProvider.availability.isEmpty)
    }

    // MARK: - Framework bridge

    func testSchemaConversionCoversCommonJSONSchemaShapes() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
        #if canImport(FoundationModels) && os(macOS)
        let schema: JSONValue = .object([
            "type": "object",
            "properties": .object([
                "path": .object(["type": "string", "description": "Absolute path"]),
                "limit": .object(["type": "integer", "minimum": .number(1)]),
                "ratio": .object(["type": "number"]),
                "recursive": .object(["type": "boolean"]),
                "sort": .object(["type": "string", "enum": .array(["name", "date", "size"])]),
                "extensions": .object(["type": "array", "items": .object(["type": "string"]), "maxItems": .number(5)]),
                "options": .object([
                    "type": "object",
                    "properties": .object([
                        "depth": .object(["type": "integer"]),
                        "mode": .object(["enum": .array([.number(1), .number(2)])]),
                    ]),
                    "required": .array(["depth"]),
                ]),
                "mystery": .object(["oneOf": .array([.object(["type": "string"]), .object(["type": "null"])])]),
                "nullable": .object(["type": .array(["string", "null"])]),
            ]),
            "required": .array(["path"]),
        ])
        let spec = ToolSpec(name: "list_directory", description: "Lists files", inputSchema: schema)
        let generated = try AppleOnDeviceProvider.generationSchema(for: spec)
        let encoded = try JSONValue.from(JSONEncoder().encode(generated)).compactText
        for key in ["path", "limit", "ratio", "recursive", "sort", "extensions", "options", "depth", "mode", "mystery", "nullable", "\"date\""] {
            XCTAssertTrue(encoded.contains(key), "encoded schema lacks \(key): \(encoded)")
        }

        // No-parameter tools, empty schemas and odd names must not throw.
        XCTAssertNoThrow(try AppleOnDeviceProvider.generationSchema(for: ToolSpec(name: "get_time", description: "Time", inputSchema: .object(["type": "object", "properties": .object([:])]))))
        XCTAssertNoThrow(try AppleOnDeviceProvider.generationSchema(for: ToolSpec(name: "mcp:server/odd-name", description: "Odd", inputSchema: .object([:]))))
        #endif
    }

    func testGeneratedContentRoundTripsThroughJSONValue() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
        #if canImport(FoundationModels) && os(macOS)
        let sample: JSONValue = .object([
            "path": .string("/tmp"),
            "limit": .number(3),
            "ratio": .number(0.5),
            "recursive": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "options": .object(["depth": .number(2), "note": .null]),
        ])
        let content = AppleOnDeviceProvider.generatedContent(from: sample)
        XCTAssertEqual(AppleOnDeviceProvider.jsonValue(from: content), sample)
        XCTAssertEqual(try JSONValue.parse(content.jsonString), sample)

        let parsedByFramework = try GeneratedContent(json: sample.compactText)
        XCTAssertEqual(AppleOnDeviceProvider.jsonValue(from: parsedByFramework), sample)
        #endif
    }

    // MARK: - Live (Apple Intelligence on)

    private func liveProvider() throws -> AppleOnDeviceProvider {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
        try XCTSkipUnless(AppleOnDeviceProvider.isAvailable, "Apple on-device model: \(AppleOnDeviceProvider.availability)")
        return AppleOnDeviceProvider()
    }

    private static let getTime = ToolSpec(name: "get_time", description: "Returns the current time of day on this Mac.", inputSchema: .object(["type": "object", "properties": .object([:])]))

    func testLivePlainPromptStreamsTextAndFinishes() async throws {
        let provider = try liveProvider()
        let request = InferenceRequest(
            messages: [.system("You answer with exactly what is asked, nothing more."), .user("Reply with the single word ready")],
            maxOutputTokens: 32,
            temperature: 0
        )
        let started = Date()
        let chunks = try await collect(provider.stream(request), timeout: 25)
        let elapsed = Date().timeIntervalSince(started)

        var text = ""
        var deltas = 0
        var finish: FinishReason?
        var usage: TokenUsage?
        for chunk in chunks {
            switch chunk {
            case .textDelta(let t): deltas += 1; text += t
            case .finished(let f): finish = f
            case .usage(let u): usage = u
            default: break
            }
        }
        XCTAssertGreaterThanOrEqual(deltas, 1)
        XCTAssertTrue(text.lowercased().contains("ready"), "unexpected reply: \(text)")
        XCTAssertEqual(finish, .stop)
        XCTAssertGreaterThan(usage?.inputTokens ?? 0, 0)
        XCTAssertGreaterThan(usage?.outputTokens ?? 0, 0)
        XCTAssertLessThan(elapsed, 25)
    }

    func testLiveToolCallIsQueuedNotRun() async throws {
        let provider = try liveProvider()
        let request = InferenceRequest(
            messages: [.system("You are Pennant, an assistant on this Mac. Use tools when they help."), .user("What time is it right now? Use the tool.")],
            tools: [Self.getTime],
            maxOutputTokens: 128,
            temperature: 0
        )
        let chunks = try await collect(provider.stream(request), timeout: 25)
        let calls = chunks.compactMap { chunk -> ToolCall? in
            if case .toolCall(let call) = chunk { return call } else { return nil }
        }
        let finish = chunks.compactMap { chunk -> FinishReason? in
            if case .finished(let f) = chunk { return f } else { return nil }
        }
        XCTAssertEqual(calls.map(\.name), ["get_time"])
        XCTAssertEqual(calls.first?.arguments, .object([:]))
        XCTAssertFalse(calls.first?.id.rawValue.isEmpty ?? true)
        XCTAssertEqual(finish, [.toolCalls])
    }

    func testLiveTranscriptReplayRecallsHistoryAndToolOutput() async throws {
        let provider = try liveProvider()
        let request = InferenceRequest(
            messages: [
                .system("You are a helpful assistant. Answer briefly."),
                .user("My favourite colour is teal."),
                .assistant("Noted: teal."),
                .user("What time is it?"),
                .assistant("", toolCalls: [ToolCall(id: ToolCallID("call_time"), name: "get_time", arguments: .object([:]))]),
                .tool(callID: ToolCallID("call_time"), name: "get_time", parts: [.text("14:32 on Tuesday")]),
                .user("Tell me the time from the tool result and remind me of my favourite colour."),
            ],
            tools: [Self.getTime],
            maxOutputTokens: 96,
            temperature: 0
        )
        let chunks = try await collect(provider.stream(request), timeout: 25)
        var text = ""
        var finish: FinishReason?
        for chunk in chunks {
            if case .textDelta(let t) = chunk { text += t }
            if case .finished(let f) = chunk { finish = f }
        }
        XCTAssertEqual(finish, .stop)
        XCTAssertTrue(text.contains("14:32"), "time not recalled: \(text)")
        XCTAssertTrue(text.lowercased().contains("teal"), "history not recalled: \(text)")
    }

    func testLiveCancellationStopsTheStream() async throws {
        let provider = try liveProvider()
        let request = InferenceRequest(
            messages: [.system("You are a storyteller."), .user("Write a 400-word story about a lighthouse keeper.")],
            maxOutputTokens: 600,
            temperature: 0.7
        )
        let consumer = Task { () -> Int in
            var deltas = 0
            for try await chunk in provider.stream(request) {
                if case .textDelta = chunk {
                    deltas += 1
                    if deltas == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            return deltas
        }
        let started = Date()
        let outcome = await consumer.result
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 10, "stream did not stop after cancellation")
        switch outcome {
        case .success(let deltas): XCTAssertLessThan(deltas, 40, "stream kept going after cancellation: \(deltas) deltas")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "unexpected error after cancellation: \(error)")
        }
    }

    // MARK: - Helpers

    private struct TimedOut: Error {}

    private func collect(_ stream: AsyncThrowingStream<InferenceChunk, Error>, timeout seconds: Double) async throws -> [InferenceChunk] {
        try await withThrowingTaskGroup(of: [InferenceChunk].self) { group in
            group.addTask {
                var out: [InferenceChunk] = []
                for try await chunk in stream { out.append(chunk) }
                return out
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            guard let first = try await group.next() else { throw TimedOut() }
            group.cancelAll()
            return first
        }
    }
}
