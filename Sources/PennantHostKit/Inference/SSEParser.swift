import Foundation

/// Incremental Server-Sent Events parser. Feed raw bytes as they arrive; it yields the payload of
/// every complete `data:` line. Comments, `event:`/`id:` lines and blank lines are ignored.
/// Tolerates `\r\n`, several events per chunk, and events split across chunks.
public struct SSEParser: Sendable {
    public static let doneMarker = "[DONE]"

    private var buffer: [UInt8] = []

    public init() {}

    /// Feed a chunk of bytes. Returns the payloads of all `data:` lines completed by this chunk.
    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(contentsOf: data)
        var payloads: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineBytes = Array(buffer[0 ..< newline])
            buffer.removeFirst(newline + 1)
            if let payload = Self.payload(fromLineBytes: lineBytes) { payloads.append(payload) }
        }
        return payloads
    }

    /// Call once the stream has ended to surface a trailing line without a final newline.
    public mutating func flush() -> [String] {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let payload = Self.payload(fromLineBytes: buffer) else { return [] }
        return [payload]
    }

    private static func payload(fromLineBytes bytes: [UInt8]) -> String? {
        var slice = bytes[...]
        if slice.last == 0x0D { slice = slice.dropLast() }
        guard !slice.isEmpty, let line = String(bytes: slice, encoding: .utf8) else { return nil }
        return payload(fromLine: line)
    }

    /// Extracts the payload from one SSE line, or nil when the line carries no data.
    public static func payload(fromLine line: String) -> String? {
        if line.isEmpty || line.hasPrefix(":") { return nil }
        guard line.hasPrefix("data:") else { return nil }
        var rest = line.dropFirst("data:".count)
        if rest.first == " " { rest = rest.dropFirst() }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
