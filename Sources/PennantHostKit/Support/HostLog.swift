import PennantCore
import Foundation
import os

/// Process-wide logging. Writes to the unified log and to a rotating text file for the diagnostics view.
public final class HostLog: Sendable {
    public static let shared = HostLog()

    private let logger = Logger(subsystem: "dev.pennant.host", category: "host")
    private let fileLock = NSLock()
    nonisolated(unsafe) private var handle: FileHandle?

    public func attachFile(at path: String) {
        fileLock.lock(); defer { fileLock.unlock() }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let size = attrs[.size] as? Int, size > 20_000_000 {
            try? FileManager.default.removeItem(atPath: path)
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    public func info(_ message: String, category: String = "host") { write("INFO", category, message); logger.info("[\(category, privacy: .public)] \(message, privacy: .public)") }
    public func warn(_ message: String, category: String = "host") { write("WARN", category, message); logger.warning("[\(category, privacy: .public)] \(message, privacy: .public)") }
    public func error(_ message: String, category: String = "host") { write("ERROR", category, message); logger.error("[\(category, privacy: .public)] \(message, privacy: .public)") }
    public func debug(_ message: String, category: String = "host") { write("DEBUG", category, message); logger.debug("[\(category, privacy: .public)] \(message, privacy: .public)") }

    private func write(_ level: String, _ category: String, _ message: String) {
        fileLock.lock(); defer { fileLock.unlock() }
        guard let handle else { return }
        let line = "\(ISO8601.format(Date())) \(level) [\(category)] \(message)\n"
        handle.write(Data(line.utf8))
    }
}

public let log = HostLog.shared
