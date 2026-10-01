import PennantCore
import CryptoKit
import Foundation

/// Makes what an approval card needs from a finished video: a small H.264 preview the app can play (the full file
/// may be far larger than a message can carry) and a poster frame. Uses ffmpeg/ffprobe from Homebrew.
enum VideoPreview {
    struct Made {
        var preview: Data
        var poster: Data?
        var duration: Double
        var width: Int
        var height: Int
    }

    /// Previews stay under this so they travel to the app in one message (32 MB WebSocket frames carry base64,
    /// so about 23 MB of raw data at most).
    static let maxPreviewBytes = 20 * 1024 * 1024

    static func make(from source: URL) async throws -> Made {
        let ffprobe = MCPManager.resolveExecutable("ffprobe"), ffmpeg = MCPManager.resolveExecutable("ffmpeg")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let probe = try await BrowserRunner.run(executable: ffprobe, arguments: args(ffprobe, "ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "json", source.path]),
                                                cwd: temp, stdin: nil, timeout: 60)
        guard probe.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any] else {
            throw ToolError.failed("Cannot read the video \(source.lastPathComponent) (is ffmpeg installed? `brew install ffmpeg`): \(probe.stderr.suffix(300))")
        }
        let stream = (json["streams"] as? [[String: Any]])?.first ?? [:]
        let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        let width = stream["width"] as? Int ?? 0, height = stream["height"] as? Int ?? 0
        guard duration > 0, width > 0 else { throw ToolError.failed("\(source.lastPathComponent) has no video stream.") }

        // Aim for the byte budget: bitrate from duration, capped for quality, 720p tall at most.
        let totalKbps = Int(Double(maxPreviewBytes * 8) / 1000 / max(duration, 1) * 0.9)
        let videoKbps = max(300, min(4000, totalKbps - 96))
        let preview = temp.appendingPathComponent("preview.mp4")
        let encode = try await BrowserRunner.run(executable: ffmpeg, arguments: args(ffmpeg, "ffmpeg", [
            "-y", "-v", "error", "-i", source.path,
            "-vf", "scale=-2:'min(720,ih)'", "-c:v", "libx264", "-preset", "veryfast", "-b:v", "\(videoKbps)k", "-maxrate", "\(videoKbps * 3 / 2)k", "-bufsize", "\(videoKbps * 2)k",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", preview.path,
        ]), cwd: temp, stdin: nil, timeout: 900)
        guard encode.status == 0, let previewData = try? Data(contentsOf: preview) else {
            throw ToolError.failed("Could not make a preview of \(source.lastPathComponent): \(encode.stderr.suffix(300))")
        }
        guard previewData.count <= 22 * 1024 * 1024 else {
            throw ToolError.failed("The preview came out at \(previewData.count / 1_048_576) MB; the video is too long for an approval card.")
        }
        let poster = temp.appendingPathComponent("poster.jpg")
        let still = try await BrowserRunner.run(executable: ffmpeg, arguments: args(ffmpeg, "ffmpeg", ["-y", "-v", "error", "-ss", String(format: "%.2f", min(1.6, duration / 3)), "-i", source.path, "-frames:v", "1", "-vf", "scale=-2:'min(720,ih)'", "-q:v", "3", poster.path]),
                                                cwd: temp, stdin: nil, timeout: 60)
        return Made(preview: previewData, poster: still.status == 0 ? try? Data(contentsOf: poster) : nil, duration: duration, width: width, height: height)
    }

    /// SHA-256 of a file, read in chunks so a large video does not have to fit in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `resolveExecutable` may hand back /usr/bin/env, which needs the tool's name first.
    private static func args(_ executable: String, _ name: String, _ rest: [String]) -> [String] {
        executable.hasSuffix("/env") ? [name] + rest : rest
    }
}
