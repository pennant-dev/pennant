import Foundation
import PennantCore

/// Talk mode's natural voices for devices that can't run them (the iPhone). The host runs Pennant Voice, the helper
/// inside Pennant.app, and streams what it says, a piece at a time, to the device that asked. The Mac app downloads
/// the voices; the host offers the ones that are downloaded. The helper starts on the first request and quits after two
/// quiet minutes.
public actor VoiceService {
    public enum VoiceError: LocalizedError {
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable(let voice): return "The voice \(voice) isn't on this Mac: download it in Pennant's Settings › Pennant › Talk mode."
            }
        }
    }

    /// Where a piece of speech goes: the connection that asked, in order.
    public typealias Sink = @Sendable (SpeechChunkHeader, [Float]) -> Void

    private struct Request {
        var speechID: String
        var connection: UUID
        var text: String
        var voice: VoiceCatalog.Voice
        var send: Sink
    }

    private let executable: URL?
    private var helper: VoiceHelper?
    /// Bumped when the helper is replaced, so events from one that's gone are ignored.
    private var generation = 0
    private var sampleRate = 24_000
    private var nextID = 0
    /// What the helper is saying or has queued, by its request number.
    private var requests: [Int: Request] = [:]
    private var idleStop: Task<Void, Never>?

    public init(executable: URL?) {
        self.executable = executable
    }

    /// The helper in the Pennant.app this host runs from (Contents/Helpers/Pennant Host.app, next to Pennant Voice.app).
    public static var bundledExecutable: URL? {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return VoiceHelper.executable(inApp: app)
    }

    /// The voices this host can speak with: downloaded, on a Mac with the helper.
    public func available() -> [VoiceCatalog.Voice] {
        guard executable != nil else { return [] }
        let ready = Set(VoiceCatalog.packs.filter(VoiceCatalog.isComplete).map(\.id))
        return VoiceCatalog.voices.filter { ready.contains($0.pack) }
    }

    /// Say `request.text` for `connection`; its speech goes to `send`, the last piece `final`. Empty text just loads the
    /// voice, so a device can have it ready before the first reply.
    public func speak(_ request: SpeechRequest, connection: UUID, send: @escaping Sink) throws {
        guard let voice = VoiceCatalog.voice(request.voice), available().contains(voice) else { throw VoiceError.unavailable(request.voice) }
        idleStop?.cancel()
        if helper?.pack != voice.pack { try start(VoiceCatalog.pack(voice.pack), voice: voice) }
        enqueue(Request(speechID: request.id, connection: connection, text: request.text, voice: voice, send: send))
    }

    /// Drop what `connection` asked to be said. The helper can only drop everything, so other devices' requests are
    /// asked for again.
    public func stop(connection: UUID) {
        let theirs = requests.filter { $0.value.connection == connection }
        guard !theirs.isEmpty else { return }
        let others = requests.filter { $0.value.connection != connection }.sorted { $0.key < $1.key }.map(\.value)
        requests.removeAll()
        helper?.stop()
        for request in theirs.values { request.send(SpeechChunkHeader(speechID: request.speechID, sampleRate: sampleRate, final: true), []) }
        for request in others { enqueue(request) }
        scheduleIdleStopIfQuiet()
    }

    private func enqueue(_ request: Request) {
        nextID += 1
        requests[nextID] = request
        helper?.say(id: nextID, text: request.text, voice: request.voice)
    }

    private func start(_ pack: VoiceCatalog.Pack, voice: VoiceCatalog.Voice) throws {
        guard let executable else { throw VoiceError.unavailable(voice.id) }
        stopHelper()
        generation += 1
        let generation = self.generation
        // Events come in order on the helper's pipe; the stream keeps that order on the way into this actor.
        let (events, feed) = AsyncStream<VoiceHelper.Event>.makeStream()
        helper = try VoiceHelper(executable: executable, pack: pack, voice: voice, log: Self.logFile()) { feed.yield($0) }
        Task { [weak self] in
            for await event in events { await self?.received(event, from: generation) }
        }
        log.info("Voice helper started for \(pack.id.rawValue)", category: "voice")
    }

    /// The helper's own messages: Application Support/Pennant/logs/voice-host.log, fresh each start.
    private static func logFile() -> FileHandle? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pennant/logs/voice-host.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return FileHandle(forWritingAtPath: url.path)
    }

    private func stopHelper() {
        helper?.terminate()
        helper = nil
        generation += 1
        failAll("Pennant's voice stopped.")
    }

    private func failAll(_ message: String) {
        let waiting = requests.values
        requests.removeAll()
        for request in waiting {
            request.send(SpeechChunkHeader(speechID: request.speechID, sampleRate: sampleRate, final: true, error: message), [])
        }
    }

    private func received(_ event: VoiceHelper.Event, from generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .loaded(let rate):
            sampleRate = rate
        case .audio(let id, let samples):
            guard let request = requests[id] else { return }
            request.send(SpeechChunkHeader(speechID: request.speechID, sampleRate: sampleRate, final: false), samples)
        case .done(let id):
            if let request = requests.removeValue(forKey: id) {
                request.send(SpeechChunkHeader(speechID: request.speechID, sampleRate: sampleRate, final: true), [])
            }
            scheduleIdleStopIfQuiet()
        case .failed(let id?, let message):
            if let request = requests.removeValue(forKey: id) {
                request.send(SpeechChunkHeader(speechID: request.speechID, sampleRate: sampleRate, final: true, error: message), [])
            }
        case .failed(nil, let message):
            log.error("Voice didn't load: \(message)", category: "voice")
            stopHelper()
        case .ended(let status):
            log.error("Voice helper ended (\(status))", category: "voice")
            helper = nil
            self.generation += 1
            failAll("Pennant's voice stopped unexpectedly.")
        }
    }

    private func scheduleIdleStopIfQuiet() {
        guard requests.isEmpty, helper != nil else { return }
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.stopIfQuiet()
        }
    }

    private func stopIfQuiet() {
        guard requests.isEmpty else { return }
        log.info("Voice helper idle; stopping it", category: "voice")
        stopHelper()
    }
}
