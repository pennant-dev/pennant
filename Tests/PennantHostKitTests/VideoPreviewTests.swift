import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Approval-card previews: small enough for one message, with a poster, and a fingerprint that notices edits.
final class VideoPreviewTests: XCTestCase {
    func testMakesPreviewPosterAndFingerprint() async throws {
        let ffmpeg = MCPManager.resolveExecutable("ffmpeg")
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: ffmpeg) || ffmpeg.hasSuffix("/env"), "ffmpeg not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("demo.mp4")
        let made = try await BrowserRunner.run(executable: ffmpeg, arguments: ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=6",
                                                                          "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path],
                                               cwd: dir, stdin: nil, timeout: 120)
        XCTAssertEqual(made.status, 0, made.stderr)

        let preview = try await VideoPreview.make(from: source)
        XCTAssertEqual(preview.width, 1920)
        XCTAssertEqual(preview.height, 1080)
        XCTAssertEqual(preview.duration, 6, accuracy: 0.2)
        XCTAssertGreaterThan(preview.preview.count, 10_000)
        XCTAssertLessThanOrEqual(preview.preview.count, VideoPreview.maxPreviewBytes)
        XCTAssertNotNil(preview.poster)

        let before = try VideoPreview.sha256(of: source)
        XCTAssertEqual(before.count, 64)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertNotEqual(try VideoPreview.sha256(of: source), before, "an edited file must not match its approval")
    }
}
