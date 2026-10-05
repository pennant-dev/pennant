import AVFoundation
import Foundation
import Observation
import os
import PennantClientKit
import PennantCore
import Speech

/// Talk mode: a spoken conversation with the Pennant chat, on the device that's listening.
///
/// What the owner says is recognised on the device; a pause ends their turn (a second and a half unless they choose
/// otherwise) and it goes to the chat as a message. Pennant's reply is read aloud a sentence at a time as it streams
/// in, and so is anything it says later about its threads; a long message is said in a sentence or two instead.
/// Talking over Pennant stops it. Its voice plays through the same audio engine as the microphone with voice
/// processing on, so its echo is cancelled instead of heard as the owner, and a word-for-word check catches the
/// rest. Where voice processing won't start (it builds an aggregate of every audio device, and some virtual ones
/// break it), Talk mode runs the microphone alone and speaks through the system's own speech output: it's stricter
/// about what counts as being talked over, and drops what it half-heard of itself once it stops speaking.
///
/// On a Mac with Apple silicon Pennant speaks with a natural voice (``NaturalVoice``), a neural model run on the GPU,
/// once it's downloaded. On the iPhone the host's Mac makes the same voices and streams them (``HostVoice``). Until
/// one is ready, and where there's none, Pennant speaks with the system's voices.
@MainActor @Observable
public final class TalkSession {
    public enum Phase: Equatable { case off, starting, listening, thinking, speaking }

    public private(set) var phase: Phase = .off
    /// What's being heard right now, while the owner talks.
    public private(set) var heard = ""
    /// Why Talk mode couldn't start or stopped.
    public private(set) var problem: String?
    /// The microphone is muted: nothing is heard or sent, and Pennant can still speak.
    public private(set) var isMuted = false
    public var isOn: Bool { phase != .off }

    /// The pause that ends the owner's turn, chosen on this device. Only the pause ends it (not the recognizer
    /// closing a stretch), so a short one doesn't cut a thought in half.
    public private(set) var pause: TimeInterval = UserDefaults.standard.object(forKey: TalkSession.pauseKey) as? TimeInterval ?? 1.5
    public static let pauseChoices: [TimeInterval] = [1, 1.5, 2, 3]
    static let pauseKey = "talk.pause"
    /// Whole seconds until what was heard is sent, once the owner has gone quiet; nil otherwise.
    public private(set) var sendingIn: Int?
    /// What was heard earlier in this turn, before the recognizer closed a stretch of it.
    private var earlier = ""

    private var session: HostSession?
    private var agentID: AgentID?
    private var chatID: ConversationID?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let synthesizer = AVSpeechSynthesizer()
    /// Without echo cancellation Pennant speaks through the synthesizer itself, which says when each sentence ends.
    private let speechEvents = SpeechEvents()
    /// The voice Pennant speaks with: the one chosen on this device, else the best installed.
    public private(set) var voice = TalkSession.chosenVoice()
    private var converters: [String: AVAudioConverter] = [:]

    private var recognizer: SFSpeechRecognizer?
    private let feed = RecognitionFeed()
    private var recognition: SFSpeechRecognitionTask?
    /// The recognition in progress: results from an earlier one are ignored.
    private var listening = UUID()
    private var lastHeardAt = Date()

    private var loop: Task<Void, Never>?
    /// Messages not to read: already in the chat when Talk mode started, read to the end, or talked over.
    private var done: Set<MessageID> = []
    /// Long messages that will be said in a sentence or two once they're whole, and how many of those the host is
    /// wording now.
    private var summarising: Set<MessageID> = []
    private var gists = 0
    /// How far into each reply has been read.
    private var readUpTo: [MessageID: Int] = [:]
    /// Sentences waiting to be spoken, and what's been said lately (to tell Pennant's echo from the owner).
    private var queue: [String] = []
    private var said = ""
    private var rendering = false
    private var buffersPlaying = 0
    /// Bumped when Pennant is talked over, so audio from before it is dropped.
    private var take = 0
    private var sentAt: Date?
    /// Echo cancellation: on unless the microphone stays silent with it (some setups), then off.
    private var voiceProcessing = true
    private var configurationObserver: (any NSObjectProtocol)?
    private var ticks = 0
    private var quietTicks = 0
    /// Counts starts and stops: a start that's been stopped (or started over) while it waits gives up.
    private var attempt = 0
    private var recognitionErrors = 0

    static let log = Logger(subsystem: "dev.pennant.app", category: "talk")
    /// Echo cancellation failed on this Mac since the app started: don't try it again until it restarts.
    static var echoCancellationFails = false
    /// Said by Talk mode itself when Pennant is quiet a few seconds after the owner spoke.
    static let fillers = ["One moment.", "Let me check.", "On it.", "Give me a second."]
    /// Whether anything was said since the owner's last turn.
    private var answered = false

    /// Without echo cancellation the microphone's engine only listens: the natural voice plays through one of its own.
    private var voiceEngine: AVAudioEngine?
    private let voicePlayer = AVAudioPlayerNode()
    /// Since when a sentence has waited for the natural voice to finish loading.
    private var waitingForVoiceSince: Date?

    /// Where the natural voice comes from on this device: its own helper on a Mac, the host's on the iPhone.
    private var natural: any TalkVoice {
        #if os(macOS)
        NaturalVoice.shared
        #else
        HostVoice.shared
        #endif
    }

    public init() {
        synthesizer.delegate = speechEvents
        speechEvents.onDone = { [weak self] in self?.spokeOne() }
    }

    // MARK: Starting and stopping

    public func start(session: HostSession, agentID: AgentID, chatID: ConversationID) async {
        guard phase == .off else { return }
        phase = .starting
        attempt += 1
        let attempt = self.attempt
        problem = nil
        voiceProcessing = !Self.echoCancellationFails
        ticks = 0
        quietTicks = 0
        recognitionErrors = 0
        self.session = session
        self.agentID = agentID
        self.chatID = chatID
        let allowed = await Self.allowed()
        guard attempt == self.attempt else { return }
        guard allowed else {
            problem = "Talk mode needs the microphone and speech recognition. Turn them on for Pennant in System Settings › Privacy & Security."
            phase = .off
            return
        }
        recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            Self.log.error("Speech recognition unavailable for \(Locale.current.identifier, privacy: .public)")
            problem = "Speech recognition isn't available right now."
            phase = .off
            return
        }
        Self.log.info("Talk mode starting: recognizer \(recognizer.locale.identifier, privacy: .public), on device \(recognizer.supportsOnDeviceRecognition), voice \(self.voice?.identifier ?? "none", privacy: .public)")
        done = Set((session.state.messages[chatID] ?? []).map(\.id))
        #if os(iOS)
        await HostVoice.shared.refresh(from: session)
        #endif
        natural.begin()
        do {
            try await startMicrophone()
        } catch {
            guard attempt == self.attempt else { return }
            problem = "The microphone didn't start: \(error.localizedDescription)"
            stopAudio()
            phase = .off
            return
        }
        // Stopped while the microphone was starting: what was started is already stopped.
        guard attempt == self.attempt else { return }
        listen()
        phase = .listening
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func stop() {
        guard phase != .off else { return }
        attempt += 1
        Self.log.info("Talk mode stopped")
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        loop?.cancel()
        loop = nil
        recognition?.cancel()
        recognition = nil
        feed.request = nil
        hush()
        stopAudio()
        natural.end()
        heard = ""
        earlier = ""
        sendingIn = nil
        isMuted = false
        phase = .off
    }

    /// Mute or unmute the microphone. Muted, nothing is recognised; without echo cancellation the microphone's engine
    /// only listens, so it stops altogether and the Mac's microphone light goes out. Pennant still speaks.
    public func setMuted(_ muted: Bool) {
        guard phase != .off, muted != isMuted else { return }
        isMuted = muted
        Self.log.info("Microphone \(muted ? "muted" : "unmuted", privacy: .public)")
        if muted {
            recognition?.cancel()
            recognition = nil
            feed.request = nil
            heard = ""
            earlier = ""
            sendingIn = nil
            if !voiceProcessing {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        } else {
            if !voiceProcessing, !engine.isRunning {
                do {
                    try installTap()
                    try engine.start()
                } catch {
                    problem = "The microphone didn't start: \(error.localizedDescription)"
                }
            }
            listen()
        }
    }

    static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in done.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func startAudio() throws {
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = engine.inputNode
        // Echo cancellation: what the engine plays is taken out of what the microphone hears. Pennant's voice plays
        // through the engine then, in the microphone's own format, which the voice unit insists on.
        try input.setVoiceProcessingEnabled(voiceProcessing)
        if voiceProcessing {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            let mic = input.outputFormat(forBus: 0)
            guard mic.sampleRate > 0, mic.channelCount > 0, let speaker = AVAudioFormat(standardFormatWithSampleRate: mic.sampleRate, channels: mic.channelCount) else {
                throw TalkError.noMicrophone
            }
            if !engine.attachedNodes.contains(player) { engine.attach(player) }
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: speaker)
        }
        // Without it, the engine only listens: Pennant speaks through the system's speech output.
        try installTap()
        engine.prepare()
        try engine.start()
        Self.log.info("Microphone on: \(input.outputFormat(forBus: 0).description, privacy: .public), echo cancellation \(self.voiceProcessing)")
        // A change of audio route (a headset, echo cancellation's own device) stops the engine: start it again.
        if configurationObserver == nil {
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable [weak self] _ in
                Task { @MainActor in self?.audioRouteChanged() }
            }
        }
    }

    /// The microphone and the speaker, with echo cancellation when it works on this Mac, else without it.
    private func startMicrophone() async throws {
        do {
            try startAudio()
        } catch where voiceProcessing {
            Self.log.error("Echo cancellation didn't start (\(error.localizedDescription, privacy: .public)); going on without it")
            Self.echoCancellationFails = true
            try await startWithoutEchoCancellation()
        }
    }

    /// A fresh engine that only listens, once the audio devices have settled: taking echo cancellation's own device
    /// away reconfigures them for a moment.
    private func startWithoutEchoCancellation() async throws {
        voiceProcessing = false
        replaceEngine()
        let attempt = self.attempt
        var failure: (any Error)?
        for wait in [800, 800, 1_500] {
            try await Task.sleep(for: .milliseconds(wait))
            // Talk mode was stopped meanwhile: leave the microphone off.
            guard attempt == self.attempt, phase != .off else { throw CancellationError() }
            do {
                try startAudio()
                return
            } catch {
                Self.log.error("The microphone didn't start yet (\(error.localizedDescription, privacy: .public))")
                failure = error
                replaceEngine()
            }
        }
        throw failure ?? TalkError.noMicrophone
    }

    /// A new engine and player: one that failed with voice processing can't be trusted to work without it.
    private func replaceEngine() {
        stopAudio()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
    }

    /// Feeds what the microphone hears to recognition. The tap has to be in the format the microphone delivers: the
    /// voice unit's with echo cancellation, else the hardware's own. Once echo cancellation has failed, the node can
    /// still report the voice unit's format (stereo, 44.1 kHz, for a mono 48 kHz microphone), and a tap in a format
    /// the hardware doesn't match raises an exception that ends the app, so the format is checked first.
    private func installTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = voiceProcessing ? input.outputFormat(forBus: 0) : input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TalkError.noMicrophone }
        if !voiceProcessing, format.sampleRate != input.outputFormat(forBus: 0).sampleRate || format.channelCount != input.outputFormat(forBus: 0).channelCount {
            Self.log.info("Microphone reports \(input.outputFormat(forBus: 0).description, privacy: .public); listening in its hardware format \(format.description, privacy: .public)")
        }
        let feed = self.feed
        // Runs on the audio thread: nothing here may assume the main actor.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in feed.append(buffer) }
    }

    private func audioRouteChanged() {
        guard phase != .off, !engine.isRunning, voiceProcessing || !isMuted else { return }
        Self.log.info("Audio route changed; restarting the microphone")
        do {
            try installTap()
            try engine.start()
        } catch {
            Self.log.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.attachedNodes.contains(player) { player.stop() }
        engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        if let voiceEngine {
            voicePlayer.stop()
            voiceEngine.stop()
            voiceEngine.detach(voicePlayer)
        }
        voiceEngine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Listening

    /// Start recognising afresh: a new turn, or (`keeping`) more of this one after the recognizer closed a stretch.
    private func listen(keeping: Bool = false) {
        recognition?.cancel()
        earlier = keeping ? heard : ""
        guard !isMuted else {
            recognition = nil
            feed.request = nil
            heard = ""
            earlier = ""
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        feed.request = request
        if !keeping { heard = "" }
        let id = UUID()
        listening = id
        recognition = recognizer?.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = result == nil ? error.map { ($0 as NSError).localizedDescription } : nil
            Task { @MainActor in self?.recognised(text, final: final, failure: failure, in: id) }
        }
    }

    private func recognised(_ text: String?, final: Bool, failure: String?, in id: UUID) {
        guard id == listening, phase != .off else { return }
        if let failure {
            // Recognition ends after a minute or a long silence: listen again, keeping what was said (the pause
            // still decides when it's sent). Errors that keep coming are shown.
            Self.log.error("Speech recognition stopped: \(failure, privacy: .public)")
            recognitionErrors += 1
            if recognitionErrors >= 3, heard.isEmpty { problem = "Speech recognition isn't hearing anything: \(failure)" }
            listen(keeping: true)
            return
        }
        recognitionErrors = 0
        problem = nil
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if phase == .speaking {
            // Talking over Pennant stops it, unless it's only Pennant's own voice coming back. Without echo
            // cancellation its voice reaches the microphone, so it takes more to count as the owner.
            let words = SpokenText.words(text).count
            let owner = voiceProcessing
                ? words >= 2 && !SpokenText.isEcho(text, of: said)
                : words >= 3 && SpokenText.echoShare(text, of: said) < 0.5
            guard owner else { return }
            hush()
            phase = .listening
        }
        heard = earlier.isEmpty ? text : earlier + " " + text
        lastHeardAt = Date()
        sendingIn = nil
        Self.log.debug("Heard: \(text, privacy: .private)")
        // The recognizer closing a stretch isn't the end of the turn: only the pause is.
        if final { listen(keeping: true) }
    }

    /// Send what's been heard now, without waiting for the pause.
    public func sendNow() {
        guard !heard.isEmpty, phase != .speaking else { return }
        send()
    }

    /// Wait this long after the owner stops talking before sending (on this device).
    public func setPause(_ seconds: TimeInterval) {
        pause = seconds
        UserDefaults.standard.set(seconds, forKey: Self.pauseKey)
    }

    private func send() {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        sendingIn = nil
        listen()
        guard !text.isEmpty, let session, let agentID, let chatID else { return }
        phase = .thinking
        sentAt = Date()
        said = ""
        answered = false
        Task {
            do {
                _ = try await session.sendMessage(to: agentID, conversationID: chatID, text: text, spoken: true)
            } catch {
                problem = HostSessionError.message(error)
                if phase == .thinking { phase = .listening }
            }
        }
    }

    // MARK: Following the chat

    private func tick() {
        guard phase != .off else { return }
        ticks += 1
        if ticks % 10 == 0 {
            let level = feed.takeLevel()
            Self.log.debug("Talk \(String(describing: self.phase), privacy: .public): input peak \(level), heard \(self.heard.count) chars")
            quietTicks = level < 0.000_01 ? quietTicks + 10 : 0
            if quietTicks >= 30, voiceProcessing, phase == .listening {
                Self.log.error("The microphone is silent with echo cancellation on; trying without it")
                quietTicks = 0
                Task {
                    do {
                        try await self.startWithoutEchoCancellation()
                    } catch where !(error is CancellationError) {
                        self.problem = "The microphone didn't start: \(error.localizedDescription)"
                    } catch {}
                }
            }
        }
        // The owner's turn ends at a pause; a long one, after a second of quiet, the bar counts down.
        if !heard.isEmpty, phase != .speaking {
            let quiet = Date().timeIntervalSince(lastHeardAt)
            if quiet >= pause {
                send()
            } else {
                let left = quiet >= 1 && pause - quiet >= 1 ? Int((pause - quiet).rounded(.up)) : nil
                if left != sendingIn { sendingIn = left }
            }
        } else if sendingIn != nil {
            sendingIn = nil
        }
        read()
        // A sentence waiting for the natural voice to load.
        if !rendering, !queue.isEmpty { speakNext() }
        // Quiet a few seconds after the owner spoke: say so, once, so they know they were heard.
        if phase == .thinking, !answered, queue.isEmpty, !rendering, Date().timeIntervalSince(sentAt ?? .distantFuture) > 4 {
            say(Self.fillers.randomElement() ?? "One moment.")
        }
        // Pennant answered without anything to say aloud (a card, a thread started quietly): back to listening.
        if phase == .thinking, queue.isEmpty, !rendering, buffersPlaying == 0, !chatBusy, gists == 0, Date().timeIntervalSince(sentAt ?? .distantPast) > 2 {
            phase = .listening
        }
    }

    /// Pennant's new words in the chat, a sentence at a time as they stream in. A message that turns out long (links,
    /// details, a report) stops being read; once it's whole, the host words it for saying aloud, carrying on from what
    /// was said of it.
    private func read() {
        guard let chatID, let messages = session?.state.messages[chatID] else { return }
        for m in messages where m.role == .assistant && !done.contains(m.id) {
            let text = m.text
            if SpokenText.isLong(text) || summarising.contains(m.id) {
                summarising.insert(m.id)
                if !m.isStreaming {
                    done.insert(m.id)
                    let alreadySaid = SpokenText.clean(String(text.prefix(readUpTo[m.id] ?? 0))) ?? ""
                    readUpTo[m.id] = nil
                    sayGist(of: text, alreadySaid: alreadySaid)
                }
                continue
            }
            // A natural voice is made afresh for each piece it says, and no two pieces sound quite alike: a message
            // waits until it's whole (or turns out long) and goes as one piece, not a first sentence and then the rest.
            if m.isStreaming, natural.isWanted, readUpTo[m.id] == nil { continue }
            let (sentences, offset) = SpokenText.sentences(in: text, from: readUpTo[m.id] ?? 0, final: !m.isStreaming)
            readUpTo[m.id] = offset
            if !m.isStreaming {
                done.insert(m.id)
                readUpTo[m.id] = nil
            }
            if !sentences.isEmpty { say(sentences.joined(separator: " ")) }
        }
    }

    /// A long message, said in a sentence or two. Without an answer from the host, it's read as it is.
    private func sayGist(of text: String, alreadySaid: String) {
        guard let session else { return }
        gists += 1
        let take = self.take
        Task {
            let words = await session.spokenVersion(of: text, alreadySaid: alreadySaid)
            gists -= 1
            guard take == self.take, phase != .off else { return }
            if let words {
                say(words)
            } else {
                let (sentences, _) = SpokenText.sentences(in: text, from: 0, final: true)
                for sentence in sentences where !alreadySaid.contains(sentence) { say(sentence) }
            }
        }
    }

    private var chatBusy: Bool {
        guard let chatID, let tasks = session?.state.tasks else { return false }
        return tasks.contains { $0.conversationID == chatID && !$0.state.isTerminal && $0.state != .waitingForUser }
    }

    // MARK: Speaking

    private func say(_ sentence: String) {
        answered = true
        queue.append(sentence)
        said = String((said + " " + sentence).suffix(1_000))
        phase = .speaking
        speakNext()
    }

    private func speakNext() {
        guard !rendering else { return }
        guard !queue.isEmpty else { return finishedSpeaking() }
        if natural.isWanted {
            if natural.isReady {
                waitingForVoiceSince = nil
                // What's waiting goes together, up to the most the helper says in one piece: a cloned voice holds
                // steadier over a few sentences than over each one alone, and there are fewer joins to hear.
                var text = queue.removeFirst()
                while let next = queue.first, text.count + next.count < 280 { text += " " + queue.removeFirst() }
                Self.log.info("Saying \(text.count) characters in the natural voice")
                return speakNaturally(text)
            }
            // It loads in a moment: wait for it rather than start a reply in one voice and finish it in another.
            if natural.isStarting {
                let since = waitingForVoiceSince ?? Date()
                waitingForVoiceSince = since
                if Date().timeIntervalSince(since) < 4 { return }
            }
        }
        rendering = true
        let utterance = AVSpeechUtterance(string: queue.removeFirst())
        utterance.voice = voice
        Self.log.info("Saying \(utterance.speechString.count) characters in \(self.voice?.name ?? "the system voice", privacy: .public)\(self.natural.isWanted ? " (the natural voice isn't ready)" : "", privacy: .public)")
        guard voiceProcessing else { return synthesizer.speak(utterance) }
        let take = self.take
        synthesizer.write(utterance) { @Sendable [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let end = pcm.frameLength == 0
            let copy = end ? nil : AudioChunk(copying: pcm)
            Task { @MainActor in
                guard let self, take == self.take else { return }
                if let copy { self.play(copy.buffer) } else { self.rendering = false; self.speakNext() }
            }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        guard let out = convert(buffer), let output = outputPlayer() else { return }
        buffersPlaying += 1
        let take = self.take
        output.scheduleBuffer(out) { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, take == self.take else { return }
                self.buffersPlaying -= 1
                self.finishedSpeaking()
            }
        }
        if !output.isPlaying { output.play() }
    }

    /// Where Pennant's voice plays: through the microphone's engine with echo cancellation on; else, for the natural
    /// voice, an engine that only plays.
    private func outputPlayer() -> AVAudioPlayerNode? {
        if voiceProcessing { return player }
        if let voiceEngine, voiceEngine.isRunning { return voicePlayer }
        let engine = voiceEngine ?? AVAudioEngine()
        if !engine.attachedNodes.contains(voicePlayer) {
            engine.attach(voicePlayer)
            engine.connect(voicePlayer, to: engine.mainMixerNode, format: playFormat)
        }
        do {
            try engine.start()
        } catch {
            Self.log.error("Pennant's voice output didn't start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        voiceEngine = engine
        return voicePlayer
    }

    /// A sentence in the natural voice: its audio plays as it arrives, and the next one is made meanwhile.
    private func speakNaturally(_ sentence: String) {
        rendering = true
        let take = self.take
        natural.say(sentence, audio: { [weak self] buffer in
            guard let self, take == self.take else { return }
            self.play(buffer)
        }, done: { [weak self] in
            guard let self, take == self.take else { return }
            self.rendering = false
            self.speakNext()
        })
    }

    /// A sentence spoken through the system's speech output (without echo cancellation) is done.
    private func spokeOne() {
        guard !voiceProcessing, phase != .off else { return }
        rendering = false
        speakNext()
    }

    private func finishedSpeaking() {
        guard phase == .speaking, queue.isEmpty, !rendering, buffersPlaying == 0 else { return }
        phase = chatBusy || gists > 0 ? .thinking : .listening
        // Without echo cancellation, what was heard while speaking is mostly Pennant itself.
        if !voiceProcessing { listen() }
    }

    /// Stop talking at once, and don't come back to what was left of the reply.
    private func hush() {
        take += 1
        queue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        if engine.attachedNodes.contains(player) { player.stop() }
        natural.hush()
        if voiceEngine != nil { voicePlayer.stop() }
        waitingForVoiceSince = nil
        rendering = false
        buffersPlaying = 0
        if let chatID, let messages = session?.state.messages[chatID] {
            for m in messages where m.role == .assistant { done.insert(m.id) }
        }
        readUpTo.removeAll()
        summarising.removeAll()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == playFormat { return buffer }
        let key = buffer.format.description
        guard let converter = converters[key] ?? AVAudioConverter(from: buffer.format, to: playFormat) else { return nil }
        converters[key] = converter
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * playFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    /// A voice to choose from: Siri's natural voices first (the most natural, and apps may use them), then Premium,
    /// Enhanced and the rest, for the system's language.
    public struct VoiceChoice: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
    }

    static let voiceKey = "talk.voice"

    public static func voiceChoices() -> [VoiceChoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { (rank($0), $0.name) < (rank($1), $1.name) }
            .map { VoiceChoice(id: $0.identifier, name: label($0)) }
    }

    /// Siri voices first, then by quality.
    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        if voice.identifier.contains(".siri.") { return 0 }
        switch voice.quality {
        case .premium: return 1
        case .enhanced: return 2
        default: return 3
        }
    }

    /// "Nora (Siri)", "Zoe (Premium)": Siri voices are listed as "Voice 4", so their own name is in the identifier.
    private static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.identifier.contains(".siri."), let name = voice.identifier.split(separator: ".").last { return "\(name) (Siri)" }
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        default: return voice.name
        }
    }

    static func chosenVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return voiceChoices().first.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Speak with another of the system's voices from now on (on this device), and say a line in it.
    public func useVoice(_ id: String) {
        guard let chosen = AVSpeechSynthesisVoice(identifier: id) else { return }
        UserDefaults.standard.set(id, forKey: Self.voiceKey)
        voice = chosen
        #if os(macOS)
        NaturalVoice.shared.isOn = false
        #else
        HostVoice.shared.use("")
        #endif
        if phase == .listening || phase == .thinking {
            say("Hi, this is how I sound now.")
        } else if phase == .off {
            let sample = AVSpeechUtterance(string: "Hi, this is how I sound now.")
            sample.voice = chosen
            synthesizer.speak(sample)
        }
    }

    #if os(macOS)
    /// Speak with a natural voice from now on (on this Mac): downloaded first if it isn't yet, then a line said in it.
    public func useNaturalVoice(_ id: String) {
        let natural = NaturalVoice.shared
        natural.use(id)
        guard natural.downloaded.contains(natural.voice.pack) else { return }
        if phase == .listening || phase == .thinking {
            say("Hi, this is how I sound now.")
        } else if phase == .off {
            natural.sample()
        }
    }
    #else
    /// Speak with one of the host's natural voices from now on (on this device), and say a line in it.
    public func useHostVoice(_ id: String) {
        HostVoice.shared.use(id)
        if phase == .listening || phase == .thinking { say("Hi, this is how I sound now.") }
    }
    #endif

    /// How the natural voice is getting on, while it isn't ready to speak: downloading, or why it can't.
    public var voiceNote: String? {
        #if os(macOS)
        let natural = NaturalVoice.shared
        guard natural.isWanted else { return nil }
        if let progress = natural.progress[natural.voice.pack] { return "Getting Pennant's natural voice: \(Int(progress * 100))%" }
        if case .failed(let message) = natural.helper { return message }
        return natural.downloadError
        #else
        return nil
        #endif
    }
}

/// The recognition request the microphone feeds, swapped for a new one at each turn. Read on the audio thread.
private final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    private var peak: Float = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        guard let samples = buffer.floatChannelData?[0] else { return }
        var loudest: Float = 0
        for i in 0 ..< Int(buffer.frameLength) { loudest = max(loudest, abs(samples[i])) }
        lock.withLock { peak = max(peak, loudest) }
    }

    /// The loudest sample since the last call.
    func takeLevel() -> Float {
        lock.withLock {
            defer { peak = 0 }
            return peak
        }
    }
}

/// A copy of a buffer of synthesized speech, safe to hand to the main actor (the synthesizer may reuse its own).
private final class AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init?(copying source: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let frames = Int(source.frameLength) * Int(source.format.isInterleaved ? source.format.channelCount : 1)
        let channels = Int(source.format.isInterleaved ? 1 : source.format.channelCount)
        if let from = source.floatChannelData, let to = copy.floatChannelData {
            for c in 0 ..< channels { to[c].update(from: from[c], count: frames) }
        } else if let from = source.int16ChannelData, let to = copy.int16ChannelData {
            for c in 0 ..< channels { to[c].update(from: from[c], count: frames) }
        } else if let from = source.int32ChannelData, let to = copy.int32ChannelData {
            for c in 0 ..< channels { to[c].update(from: from[c], count: frames) }
        } else {
            return nil
        }
        buffer = copy
    }
}

enum TalkError: LocalizedError {
    case noMicrophone
    var errorDescription: String? { "no microphone is available" }
}

/// When the synthesizer finishes or abandons a sentence it speaks itself.
private final class SpeechEvents: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onDone: (@MainActor @Sendable () -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { done() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { done() }

    private func done() {
        let onDone = self.onDone
        Task { @MainActor in onDone?() }
    }
}
