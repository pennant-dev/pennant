import AVFoundation
import Foundation
import Observation
import PennantClientKit
import PennantCore

/// Where Talk mode's natural voice comes from: the helper on this Mac (`NaturalVoice`), or the host, for a device that
/// can't run the models itself (`HostVoice`).
@MainActor public protocol TalkVoice: AnyObject {
    /// Chosen, and able to speak here.
    var isWanted: Bool { get }
    var isReady: Bool { get }
    /// Loading for a moment: worth waiting for rather than starting a reply in another voice.
    var isStarting: Bool { get }
    /// Talk mode started or ended.
    func begin()
    func end()
    /// Say `text`, handing audio over as it's made, then calling `done` (also when it can't be said).
    func say(_ text: String, audio: @escaping @MainActor (AVAudioPCMBuffer) -> Void, done: @escaping @MainActor () -> Void)
    /// Drop everything not yet said.
    func hush()
}

enum TalkAudio {
    /// Mono samples as a buffer Talk mode can play.
    static func buffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// Talk mode's natural voices on a device that can't run them (the iPhone): the host runs Pennant Voice on its Mac
/// and streams each sentence back as it's made. The voice is chosen on the device, from those the host has
/// downloaded; nothing is downloaded here. Until one is chosen, Penny speaks if the Mac has her, else the catalogue's
/// default voice, else the first the Mac has.
@MainActor @Observable
public final class HostVoice: TalkVoice {
    public static let shared = HostVoice()

    /// The voices the host can speak with; empty until asked, or on a host that can't.
    public private(set) var available: [VoiceCatalog.Voice] = []
    /// The voice chosen on this device: "" for the device's own voices, nil when nothing's been chosen yet.
    public private(set) var voiceID: String?
    private weak var session: HostSession?
    /// Requests the host is still saying, by id.
    private var speaking: Set<String> = []

    static let voiceKey = "talk.hostVoice"

    init() {
        voiceID = UserDefaults.standard.string(forKey: Self.voiceKey)
    }

    public var voice: VoiceCatalog.Voice? {
        guard let voiceID else {
            return available.first { $0.id == "penny" } ?? available.first { $0.id == VoiceCatalog.defaultVoice } ?? available.first
        }
        return available.first { $0.id == voiceID }
    }
    public var isWanted: Bool { voice != nil }
    public var isReady: Bool { voice != nil && session?.connection.isConnected == true }
    public var isStarting: Bool { false }

    /// Ask the host which voices it has (when Talk mode starts, or the voice menu opens).
    public func refresh(from session: HostSession) async {
        self.session = session
        available = (try? await session.hostVoices()) ?? []
    }

    /// Speak with one of the host's voices from now on (on this device), or the device's own voices ("").
    public func use(_ id: String) {
        voiceID = id
        UserDefaults.standard.set(id, forKey: Self.voiceKey)
        if !id.isEmpty { begin() }
    }

    /// Have the host load the voice now (an empty request), so the first reply doesn't wait for it.
    public func begin() {
        guard isReady else { return }
        say("", audio: { _ in }, done: {})
    }

    public func end() { hush() }

    public func say(_ text: String, audio: @escaping @MainActor (AVAudioPCMBuffer) -> Void, done: @escaping @MainActor () -> Void) {
        guard let session, let voice, isReady else { return done() }
        let request = SpeechRequest(text: text, voice: voice.id)
        speaking.insert(request.id)
        Task {
            do {
                try await session.speak(request) { [weak self] header, samples in
                    guard let self, self.speaking.contains(header.speechID) else { return }
                    if let buffer = TalkAudio.buffer(samples, sampleRate: Double(header.sampleRate)) { audio(buffer) }
                    if header.final {
                        self.speaking.remove(header.speechID)
                        done()
                    }
                }
            } catch {
                if speaking.remove(request.id) != nil { done() }
            }
        }
    }

    public func hush() {
        guard !speaking.isEmpty, let session else { return }
        speaking.removeAll()
        Task { await session.stopSpeaking() }
    }
}
