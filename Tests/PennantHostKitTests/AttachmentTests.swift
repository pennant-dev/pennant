import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class AttachmentTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    /// A 1×1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testUploadedImageAndFileReachTheModel() async throws {
        let provider = ScriptedProvider([.init(text: "I see a tiny image.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        config.inference.supportsVision = true
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")

        guard case .attachment(let image) = await s.handle(.uploadAttachment(fileName: "dot.png", mimeType: "image/png", base64: Self.png.base64EncodedString()), from: client) else { return XCTFail("image upload failed") }
        XCTAssertNil(image.path, "images go to the model, not the file system")
        guard case .attachment(let pdf) = await s.handle(.uploadAttachment(fileName: "report.pdf", mimeType: "application/pdf", base64: Data("%PDF-1.4".utf8).base64EncodedString()), from: client) else { return XCTFail("file upload failed") }
        let path = try XCTUnwrap(pdf.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("%PDF-1.4".utf8))

        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "", attachments: [image, pdf])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(taskID)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }

        let conversation = try await s.store.conversation(conversationID)
        XCTAssertEqual(conversation?.title, "Attachment: dot.png")
        let user = try XCTUnwrap(provider.requests.first?.messages.last { $0.role == .user && !$0.text.hasPrefix("[Context for this turn]") })
        XCTAssertTrue(user.parts.contains { if case .image(_, let mime) = $0 { return mime == "image/png" }; return false }, "the image reaches the model")
        XCTAssertTrue(user.text.contains("saved at \(path)"), "the file's path reaches the model")
        await s.stop()
    }

    func testEmptyOrOversizedUploadsAreRefused() async throws {
        let s = try HostService(paths: paths, config: HostConfig(workingDirectory: paths.root.path), desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: ScriptedProvider([]))
        try await s.start(startAPI: false)
        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")
        guard case .error = await s.handle(.uploadAttachment(fileName: "x", mimeType: "text/plain", base64: ""), from: client) else { return XCTFail("empty upload accepted") }
        let big = Data(count: HostService.maxUploadBytes + 1).base64EncodedString()
        guard case .error(_, let message) = await s.handle(.uploadAttachment(fileName: "big.bin", mimeType: "application/octet-stream", base64: big), from: client) else { return XCTFail("oversized upload accepted") }
        XCTAssertTrue(message.contains("larger than"))
        await s.stop()
    }

    func testReadFileShowsImagesAsImages() async throws {
        let file = paths.root.appendingPathComponent("slide.png")
        try Self.png.write(to: file)
        let store = FakeStore()
        let context = ToolContext(agentID: AgentID(), taskID: TaskID(), conversationID: ConversationID(), store: store, desktop: FakeDesktop(), lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig(workingDirectory: paths.root.path))
        let result = try await ReadFileTool().invoke(["path": .string(file.path)], context: context)
        let image = try XCTUnwrap(result.content.compactMap { if case .image(let ref) = $0 { return ref }; return nil }.first, "an image part")
        XCTAssertEqual(image.mimeType, "image/jpeg")
        let stored = try await store.artifactData(image.artifactID)
        XCTAssertNotNil(stored)
        XCTAssertTrue(result.textContent.contains("1×1 image"))
    }
}

