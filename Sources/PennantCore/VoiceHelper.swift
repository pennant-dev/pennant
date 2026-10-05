#if os(macOS)
import Foundation

/// One running Pennant Voice helper with a voice pack loaded. The Mac app drives one for its own Talk mode, the host
/// one for other devices'. Requests go in as JSON lines on its stdin; what it says comes back to `events`, in order, on
/// the queue that reads its output.
public final class VoiceHelper: @unchecked Sendable {
    public enum Event: Sendable {
        case loaded(sampleRate: Int)
        case audio(id: Int, samples: [Float])
        case done(id: Int)
        /// A request that failed (`id`), or the voice that didn't load (no `id`).
        case failed(id: Int?, message: String)
        /// The helper exited; it wasn't asked to.
        case ended(status: Int32)
    }

    public let pack: VoiceCatalog.Pack.ID
    private let process = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private var stopping = false

    /// The helper inside the app bundle at `bundle` (Pennant.app), or nil where it isn't (an Intel Mac's app, or a
    /// build without it). PENNANT_VOICE_HELPER points elsewhere when testing.
    public static func executable(inApp bundle: URL) -> URL? {
        if let path = ProcessInfo.processInfo.environment["PENNANT_VOICE_HELPER"] { return URL(fileURLWithPath: path) }
        #if arch(arm64)
        let url = bundle.appendingPathComponent("Contents/Helpers/Pennant Voice.app/Contents/MacOS/Pennant Voice")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        #else
        return nil
        #endif
    }

    /// Starts the helper and loads `pack`, speaking as `voice` until told otherwise. `log` takes the helper's own
    /// messages.
    public init(executable: URL, pack: VoiceCatalog.Pack, voice: VoiceCatalog.Voice, log: FileHandle?, events: @escaping @Sendable (Event) -> Void) throws {
        self.pack = pack.id
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        // Pronunciation data is looked up in a Hugging Face cache: this one, downloaded by the app. HF_HOME keeps the
        // helper away from any Hugging Face sign-in on this Mac; it never goes to the network.
        environment["HF_HUB_CACHE"] = VoiceCatalog.hubDirectory.path
        environment["HF_HOME"] = VoiceCatalog.voicesDirectory.path
        environment["HF_HUB_OFFLINE"] = "1"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = log ?? FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        let lines = LineReader()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for event in lines.events(in: data) { events(event) }
        }
        process.terminationHandler = { [weak self] ended in
            guard let self, !self.lock.withLock({ self.stopping }) else { return }
            events(.ended(status: ended.terminationStatus))
        }
        try process.run()
        var load: [String: Any] = ["op": "load", "model": VoiceCatalog.directory(for: pack.repos[0]).path, "voice": VoiceCatalog.speaker(for: voice)]
        load["language"] = pack.language
        load["reference"] = pack.reference
        send(load)
    }

    /// Say `text` as `voice` (one of the pack's); its audio and `done` come back under `id`.
    public func say(id: Int, text: String, voice: VoiceCatalog.Voice) {
        var request: [String: Any] = ["op": "say", "id": id, "text": text, "voice": VoiceCatalog.speaker(for: voice)]
        request["language"] = VoiceCatalog.pack(voice.pack).language
        send(request)
    }

    /// Drop everything not yet said; what's dropped still comes back `done`.
    public func stop() { send(["op": "stop"]) }

    /// Quit the helper: closing its input ends it.
    public func terminate() {
        lock.withLock { stopping = true }
        try? input.close()
        if process.isRunning { process.terminate() }
    }

    private func send(_ request: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return }
        line.append(0x0A)
        lock.withLock { try? input.write(contentsOf: line) }
    }
}

/// One line from the helper.
struct HelperLine: Decodable {
    var event: String
    var id: Int?
    var sampleRate: Int?
    var message: String?
    var pcm: String?

    var asEvent: VoiceHelper.Event? {
        switch event {
        case "loaded": return .loaded(sampleRate: sampleRate ?? 24_000)
        case "audio":
            guard let id, let pcm, let data = Data(base64Encoded: pcm) else { return nil }
            return .audio(id: id, samples: data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
        case "done": return id.map { .done(id: $0) }
        case "error": return .failed(id: id, message: message ?? "Pennant's voice didn't load.")
        default: return nil
        }
    }
}

/// Splits the helper's output into events, a line at a time. Called on the pipe's queue.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func events(in data: Data) -> [VoiceHelper.Event] {
        lock.withLock {
            buffer.append(data)
            var events: [VoiceHelper.Event] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< end]
                buffer.removeSubrange(buffer.startIndex ... end)
                if let event = (try? JSONDecoder().decode(HelperLine.self, from: line))?.asEvent { events.append(event) }
            }
            return events
        }
    }
}
#endif
