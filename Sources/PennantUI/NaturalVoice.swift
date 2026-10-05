#if os(macOS)
import AVFoundation
import Foundation
import Observation
import os
import PennantCore

/// Pennant's natural voice in Talk mode on a Mac: a neural speech model (`VoiceCatalog`) that sounds like a person
/// rather than a synthesizer. It runs on the Mac's GPU in the Pennant Voice helper inside the app (Apple silicon
/// only), and is downloaded once from Hugging Face, at a pinned revision, into Application Support/Pennant/Voices.
/// Nothing said or heard leaves the Mac.
@MainActor @Observable
public final class NaturalVoice: TalkVoice {
    public static let shared = NaturalVoice()

    public enum HelperState: Equatable, Sendable { case stopped, starting, ready, failed(String) }

    /// Whether Talk mode speaks with a natural voice (on this Mac), rather than the Mac's own voices.
    public var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: Self.onKey) }
    }
    /// The natural voice chosen on this Mac.
    public private(set) var voiceID: String
    public private(set) var helper: HelperState = .stopped
    /// Downloads in progress, from 0 to 1.
    public private(set) var progress: [VoiceCatalog.Pack.ID: Double] = [:]
    public private(set) var downloaded: Set<VoiceCatalog.Pack.ID> = []
    public private(set) var downloadError: String?

    static let onKey = "talk.natural"
    static let voiceKey = "talk.naturalVoice"
    static let log = Logger(subsystem: "dev.pennant.app", category: "voice")

    private var running: VoiceHelper?
    /// Bumped when the helper is replaced, so events from one that's gone are ignored.
    private var generation = 0
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var sampleRate: Double = 24_000
    private var downloads: [VoiceCatalog.Pack.ID: Task<Void, Never>] = [:]
    /// Talk mode is using the helper; when it isn't, the helper quits after a minute.
    private var inUse = false
    private var idleStop: Task<Void, Never>?
    private var preview: (engine: AVAudioEngine, player: AVAudioPlayerNode)?

    private struct Pending {
        var audio: @MainActor (AVAudioPCMBuffer) -> Void
        var done: @MainActor () -> Void
    }

    init() {
        isOn = UserDefaults.standard.object(forKey: Self.onKey) as? Bool ?? true
        let saved = UserDefaults.standard.string(forKey: Self.voiceKey) ?? VoiceCatalog.defaultVoice
        voiceID = VoiceCatalog.voice(saved) == nil ? VoiceCatalog.defaultVoice : saved
        downloaded = Set(VoiceCatalog.packs.filter(VoiceCatalog.isComplete).map(\.id))
    }

    public var voice: VoiceCatalog.Voice { VoiceCatalog.voice(voiceID) ?? VoiceCatalog.voices[0] }

    // MARK: Where it can run

    static var executable: URL? { VoiceHelper.executable(inApp: Bundle.main.bundleURL) }

    /// Apple silicon, with the helper present.
    public static var isSupported: Bool { executable != nil }

    /// Whether Talk mode should speak with the natural voice now: it's chosen, and could run here.
    public var isWanted: Bool { isOn && Self.isSupported }
    public var isReady: Bool { helper == .ready && running?.pack == voice.pack }
    public var isStarting: Bool {
        helper == .starting || (helper == .ready && running?.pack != voice.pack && downloaded.contains(voice.pack))
    }

    // MARK: Choosing

    /// Speak with this natural voice from now on: downloaded first if needed, then loaded.
    public func use(_ id: String) {
        guard let chosen = VoiceCatalog.voice(id) else { return }
        voiceID = chosen.id
        UserDefaults.standard.set(chosen.id, forKey: Self.voiceKey)
        isOn = true
        prepare()
    }

    /// Have the chosen voice ready: download it if needed, then start the helper with it.
    public func prepare() {
        guard Self.isSupported else { return }
        idleStop?.cancel()
        let pack = voice.pack
        guard downloaded.contains(pack) else { return download(pack) }
        if running?.pack != pack { startHelper(with: VoiceCatalog.pack(pack)) }
        if !inUse { scheduleIdleStop() }
    }

    /// Talk mode started: keep the helper running until it ends.
    public func begin() {
        inUse = true
        idleStop?.cancel()
        if isWanted { prepare() }
    }

    /// Talk mode ended: the helper quits after a minute unless it's needed again.
    public func end() {
        inUse = false
        hush()
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, !self.inUse else { return }
            self.stopHelper()
        }
    }

    // MARK: Speaking

    /// Say `text`, handing audio over as it's made, then calling `done` (also when it can't be said).
    public func say(_ text: String, audio: @escaping @MainActor (AVAudioPCMBuffer) -> Void, done: @escaping @MainActor () -> Void) {
        guard isReady, let running else { return done() }
        nextID += 1
        pending[nextID] = Pending(audio: audio, done: done)
        running.say(id: nextID, text: text, voice: voice)
    }

    /// Drop everything not yet said.
    public func hush() {
        pending.removeAll()
        running?.stop()
        preview?.player.stop()
    }

    /// Say a line in the chosen voice through the Mac's speakers (Settings, or the menu when Talk mode is off). A
    /// voice that isn't downloaded yet starts downloading instead.
    public func sample() {
        prepare()
        guard downloaded.contains(voice.pack) else { return }
        Task {
            let deadline = Date().addingTimeInterval(20)
            while !isReady, helper != .stopped, Date() < deadline {
                if case .failed = helper { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard isReady else { return }
            let output = previewOutput()
            say("Hi, this is how I sound now.", audio: { buffer in
                output?.scheduleBuffer(buffer)
                if output?.isPlaying == false { output?.play() }
            }, done: {})
        }
    }

    private func previewOutput() -> AVAudioPlayerNode? {
        if let preview { return preview.player }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        do { try engine.start() } catch {
            Self.log.error("Voice preview output didn't start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        preview = (engine, player)
        return player
    }

    // MARK: The helper

    private func startHelper(with pack: VoiceCatalog.Pack) {
        stopHelper()
        guard let executable = Self.executable else { return }
        generation += 1
        let generation = self.generation
        helper = .starting
        do {
            // Events arrive in order on the pipe's queue; the main queue keeps that order.
            running = try VoiceHelper(executable: executable, pack: pack, voice: voice, log: Self.logFile()) { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(event, from: generation) } }
            }
            Self.log.info("Voice helper started for \(pack.id.rawValue, privacy: .public)")
        } catch {
            helper = .failed("Pennant's voice didn't start: \(error.localizedDescription)")
        }
    }

    /// The helper's own messages, for when it misbehaves: Application Support/Pennant/logs/voice.log, fresh each start.
    private static func logFile() -> FileHandle? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pennant/logs/voice.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return FileHandle(forWritingAtPath: url.path)
    }

    private func stopHelper() {
        guard let running else { return }
        self.running = nil
        generation += 1
        helper = .stopped
        running.terminate()
        finishPending()
        preview?.engine.stop()
        preview = nil
    }

    private func finishPending() {
        let waiting = pending
        pending.removeAll()
        for item in waiting.values { item.done() }
    }

    private func received(_ event: VoiceHelper.Event, from generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .loaded(let rate):
            sampleRate = Double(rate)
            helper = .ready
            Self.log.info("Voice ready")
        case .audio(let id, let samples):
            guard let item = pending[id], let buffer = TalkAudio.buffer(samples, sampleRate: sampleRate) else { return }
            item.audio(buffer)
        case .done(let id):
            pending.removeValue(forKey: id)?.done()
        case .failed(let id, let message):
            Self.log.error("Voice helper: \(message, privacy: .public)")
            if id == nil { helper = .failed(message) }
        case .ended(let status):
            Self.log.error("Voice helper ended (\(status))")
            running = nil
            helper = .failed("Pennant's voice stopped unexpectedly; Talk mode is using the Mac's own voice.")
            finishPending()
        }
    }

    // MARK: Downloading

    public func download(_ id: VoiceCatalog.Pack.ID) {
        guard downloads[id] == nil, !downloaded.contains(id) else { return }
        let pack = VoiceCatalog.pack(id)
        downloadError = nil
        progress[id] = 0
        downloads[id] = Task { [weak self] in
            do {
                try await self?.fetch(pack)
                guard let self else { return }
                self.downloaded.insert(id)
                self.progress[id] = nil
                self.downloads[id] = nil
                Self.log.info("Downloaded the \(id.rawValue, privacy: .public) voice")
                if self.isWanted, self.voice.pack == id { self.prepare() }
            } catch {
                guard let self else { return }
                self.progress[id] = nil
                self.downloads[id] = nil
                if !(error is CancellationError) {
                    self.downloadError = "The voice didn't download: \(error.localizedDescription)"
                    Self.log.error("Voice download failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Delete a downloaded voice (or stop its download). Removing the one in use turns natural voices off, so Talk mode
    /// doesn't fetch it again.
    public func remove(_ id: VoiceCatalog.Pack.ID) {
        if voice.pack == id { isOn = false }
        downloads[id]?.cancel()
        downloads[id] = nil
        progress[id] = nil
        if running?.pack == id { stopHelper() }
        let pack = VoiceCatalog.pack(id)
        try? FileManager.default.removeItem(at: VoiceCatalog.marker(for: pack))
        for repo in pack.repos { try? FileManager.default.removeItem(at: VoiceCatalog.directory(for: repo)) }
        downloaded.remove(id)
    }

    /// Every file of every repository in the pack, skipping files already here, then the marker that says it's whole.
    private func fetch(_ pack: VoiceCatalog.Pack) async throws {
        var done: Int64 = 0
        for repo in pack.repos {
            let directory = VoiceCatalog.directory(for: repo)
            for file in repo.files {
                let destination = directory.appendingPathComponent(file)
                if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64, size > 0 {
                    done += size
                    continue
                }
                let url = URL(string: "https://huggingface.co/\(repo.name)/resolve/\(repo.revision)/\(file)")!
                done += try await Self.fetch(url, to: destination) { [weak self] received in
                    self?.progress[pack.id] = min(0.99, Double(done + received) / Double(pack.size))
                }
                try Task.checkCancellation()
            }
            if repo.addsConfig { try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json")) }
        }
        try Data().write(to: VoiceCatalog.marker(for: pack))
    }

    /// One file, moved into place once it's whole. Returns its size.
    private static func fetch(_ url: URL, to destination: URL, received: @MainActor (Int64) -> Void) async throws -> Int64 {
        let result = DownloadResult()
        let task = URLSession.shared.downloadTask(with: url) { @Sendable file, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { return result.finish(.failure(error)) }
            guard let file, status == 200 else { return result.finish(.failure(VoiceDownloadError.status(status))) }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
                result.finish(.success(size))
            } catch {
                result.finish(.failure(error))
            }
        }
        task.resume()
        while true {
            if let outcome = result.outcome { return try outcome.get() }
            if Task.isCancelled {
                task.cancel()
                throw CancellationError()
            }
            received(task.countOfBytesReceived)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

enum VoiceDownloadError: LocalizedError {
    case status(Int)
    var errorDescription: String? {
        switch self {
        case .status(let code): return code == 0 ? "no answer from Hugging Face" : "Hugging Face answered \(code)"
        }
    }
}

/// A download's outcome, set on URLSession's queue and read on the main actor.
private final class DownloadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Int64, any Error>?

    var outcome: Result<Int64, any Error>? { lock.withLock { value } }
    func finish(_ outcome: Result<Int64, any Error>) { lock.withLock { value = outcome } }
}
#endif
