import Darwin
import Foundation
import PennantCore

/// Meaning search with Pennant's own model, no server to install: the Pennant Voice helper runs it on the Mac's GPU
/// (`Pennant Voice embed`). The helper starts on first use, downloads the model the first time (about 630 MB, into
/// `modelsDirectory`), and then stays up for the host's life, so a lookup costs milliseconds. If it exits, the next
/// call starts it again.
public actor PennantEmbeddingProvider: EmbeddingProvider {
    public nonisolated let modelName: String
    private let executable: URL
    private let modelsDirectory: URL
    private let logURL: URL?

    private var process: Process?
    private var input: FileHandle?
    private var ready = false
    /// Why the last start failed, and when: a helper that can't load isn't restarted for a minute.
    private var failure: (message: String, at: Date)?
    private var pending: [Int: CheckedContinuation<[[Float]], Error>] = [:]
    private var nextID = 1

    /// How long a single lookup waits for the model to load: a chat reply goes on without meaning search sooner than wait
    /// for a download. Batches (indexing, the backfill) wait as long as a first download takes.
    static let lookupWait: TimeInterval = 5
    static let batchWait: TimeInterval = 1800
    static let replyWait: TimeInterval = 120
    static let retryAfter: TimeInterval = 60

    public init(executable: URL, model: String, modelsDirectory: URL, logURL: URL? = nil) {
        self.executable = executable
        self.modelName = model
        self.modelsDirectory = modelsDirectory
        self.logURL = logURL
    }

    /// Starts the helper and waits for the model: the backfill calls this before its first batch.
    public func prepare() async {
        try? await waitUntilReady(timeout: Self.batchWait)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        try await waitUntilReady(timeout: texts.count == 1 ? Self.lookupWait : Self.batchWait)
        guard let input else { throw EmbeddingError.unavailable("the embedding helper stopped") }
        let id = nextID
        nextID += 1
        guard var line = try? JSONSerialization.data(withJSONObject: ["id": id, "texts": texts]) else { throw EmbeddingError.unavailable("unreadable text") }
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: EmbeddingError.unavailable("the embedding helper stopped"))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.replyWait))
                await self?.expire(id)
            }
        }
    }

    // MARK: The helper

    private func waitUntilReady(timeout: TimeInterval) async throws {
        if !ready, process == nil {
            if let failure, Date().timeIntervalSince(failure.at) < Self.retryAfter { throw EmbeddingError.unavailable(failure.message) }
            try start()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !ready {
            if process == nil, let failure { throw EmbeddingError.unavailable(failure.message) }
            if Date() >= deadline { throw EmbeddingError.unavailable("the embedding model is still loading") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func start() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["embed", "--model", modelName]
        var environment = ProcessInfo.processInfo.environment
        // Its own Hugging Face cache, away from any sign-in on this Mac; it goes to the network only for the download.
        environment["HF_HUB_CACHE"] = modelsDirectory.path
        environment["HF_HOME"] = modelsDirectory.path
        environment.removeValue(forKey: "HF_HUB_OFFLINE")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            process.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        } else {
            process.standardError = FileHandle.nullDevice
        }
        // A helper that died mustn't take the host with it when the next request is written.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let lines = Lines()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in lines.split(data) { Task { await self?.received(line) } }
        }
        process.terminationHandler = { [weak self] ended in
            Task { await self?.ended(process: ended) }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        failure = nil
    }

    private func received(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let event = object["event"] as? String {
            if event == "ready" {
                ready = true
                log.info("Meaning search is ready (\(modelName), \(object["dimensions"] as? Int ?? 0) dimensions)", category: "memory")
            } else if event == "error" {
                let message = object["message"] as? String ?? "the embedding model didn't load"
                failure = (message, Date())
                log.warn("Meaning search: \(message)", category: "memory")
            }
            return
        }
        guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if let vectors = object["vectors"] as? [[Double]] {
            continuation.resume(returning: vectors.map { $0.map(Float.init) })
        } else {
            continuation.resume(throwing: EmbeddingError.failed(object["error"] as? String ?? "no vectors came back"))
        }
    }

    private func ended(process ended: Process) {
        guard ended === process else { return }
        // One that never got its model loaded waits a minute before the next try; one that was working starts again on
        // the next call.
        if !ready, failure == nil { failure = ("the embedding helper exited (\(ended.terminationStatus))", Date()) }
        process = nil
        input = nil
        ready = false
        for (_, continuation) in pending { continuation.resume(throwing: EmbeddingError.unavailable("the embedding helper stopped")) }
        pending.removeAll()
    }

    private func expire(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: EmbeddingError.failed("no answer from the embedding model in \(Int(Self.replyWait)) s"))
    }

    /// Stops the helper (the host is going away).
    public func stop() {
        process?.terminate()
    }

    /// Whole lines from the helper's output, however the pipe splits them.
    private final class Lines: @unchecked Sendable {
        private var buffer = Data()
        private let lock = NSLock()
        func split(_ data: Data) -> [Data] {
            lock.withLock {
                buffer.append(data)
                var lines: [Data] = []
                while let end = buffer.firstIndex(of: 0x0A) {
                    lines.append(Data(buffer[buffer.startIndex ..< end]))
                    buffer.removeSubrange(buffer.startIndex ... end)
                }
                return lines
            }
        }
    }
}

public enum EmbeddingError: Error, CustomStringConvertible {
    case unavailable(String)
    case failed(String)
    public var description: String {
        switch self {
        case .unavailable(let why): return "Meaning search isn't available: \(why)"
        case .failed(let why): return "Embedding failed: \(why)"
        }
    }
}
