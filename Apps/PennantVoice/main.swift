import Darwin
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS

// Pennant Voice: Pennant's natural voice in Talk mode on a Mac. A neural speech model runs on the GPU here, in a
// process of its own, so a fault in it can't take the app down and its memory is given back when Talk mode ends.
//
// The app writes one JSON request per line and reads one JSON event per line:
//
//   {"op":"load","model":"/…/Kokoro-82M-bf16","voice":"af_heart"} → {"event":"loaded","sampleRate":24000}
//   {"op":"say","id":3,"text":"Hello.","voice":"af_heart"}         → {"event":"audio","id":3,"pcm":"<base64 Float32>"} … {"event":"done","id":3}
//   {"op":"stop"}                                                 drops whatever hasn't been said yet
//
// A load can name a "reference": a recording in this app's bundle (<name>.wav, its words in <name>.txt) whose voice
// the model then speaks in (Penny's). Each piece is a fresh copy of that voice, and copies differ a little.
//
// Audio streams out as it's made (models that stream send it in pieces), mono, at the loaded sample rate.
//
// The app downloads the model and its pronunciation data; HF_HUB_CACHE, set by the app, points at them, so nothing
// here goes to the network. The helper exits as soon as the app closes its end of the pipe.
//
// Run with a command (`speak`, `transcribe`), it does one job for a skill instead: see Commands.swift.

struct Request: Decodable, Sendable {
    var op: String
    var id: Int?
    var model: String?
    var text: String?
    var voice: String?
    var language: String?
    var speed: Double?
    var reference: String?
}

/// A loaded model, and the recording whose voice it clones, if any.
struct LoadedVoice {
    var model: any SpeechGenerationModel
    var reference: MLXArray?
    var referenceText: String?
}

enum HelperError: LocalizedError {
    case noRecording(String)
    var errorDescription: String? {
        switch self {
        case .noRecording(let name): return "the recording \(name) isn't in Pennant Voice"
        }
    }
}

/// The protocol's own copy of stdout. Libraries print progress to stdout, so stdout itself is pointed at stderr.
final class Events: @unchecked Sendable {
    static let shared = Events()
    private let handle: FileHandle
    private let lock = NSLock()

    init() {
        let fd = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func send(_ event: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: event) else { return }
        line.append(0x0A)
        lock.withLock { try? handle.write(contentsOf: line) }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("pennant-voice: \(message)\n".utf8))
}

/// Counts stops. Each request carries the count it arrived under; once it's moved on, the request is dropped.
final class Stops: @unchecked Sendable {
    static let shared = Stops()
    private let lock = NSLock()
    private var count = 0

    var current: Int { lock.withLock { count } }
    func stop() { lock.withLock { count += 1 } }
}

/// Loads the model and says what it's asked, one request at a time. The model never leaves this task.
func speak(_ requests: AsyncStream<(Request, Int)>) async {
    var voice: LoadedVoice?
    for await (request, stopCount) in requests {
        switch request.op {
        case "load":
            voice = await load(request)
        case "say":
            let id = request.id ?? 0
            if stopCount == Stops.shared.current {
                if let voice { await say(request, with: voice, stopCount: stopCount) } else {
                    Events.shared.send(["event": "error", "id": id, "message": "The voice isn't loaded."])
                }
            }
            Events.shared.send(["event": "done", "id": id])
        default:
            log("unknown request \(request.op)")
        }
    }
}

func load(_ request: Request) async -> LoadedVoice? {
    do {
        let model = try await TTS.loadModel(modelRepo: request.model ?? "")
        var voice = LoadedVoice(model: model)
        if let name = request.reference {
            guard let audio = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let words = Bundle.main.url(forResource: name, withExtension: "txt") else { throw HelperError.noRecording(name) }
            voice.reference = try loadAudioArray(from: audio, sampleRate: model.sampleRate).1
            voice.referenceText = try String(contentsOf: words, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The first sentence compiles the GPU kernels; do that now so Pennant's first words come straight away.
        _ = try? await model.generate(
            text: "Hello there.", voice: voice.reference == nil ? request.voice : nil, refAudio: voice.reference,
            refText: voice.referenceText, language: request.language)
        Memory.clearCache()
        Events.shared.send(["event": "loaded", "sampleRate": model.sampleRate])
        return voice
    } catch {
        Events.shared.send(["event": "error", "message": "The voice didn't load: \(error.localizedDescription)"])
        return nil
    }
}

func say(_ request: Request, with voice: LoadedVoice, stopCount: Int) async {
    let id = request.id ?? 0
    let model = voice.model
    if let kokoro = model as? KokoroModel { kokoro.speed = Float(request.speed ?? 1) }
    for piece in pieces(of: request.text ?? "") {
        // A cloned voice sometimes doesn't stop when the words do: it goes on with laughter and voices in the
        // background until the model's own limit, twice the words' length. Its speech is held near the words' length,
        // and once past it, the first quiet moment ends the piece.
        let cloned = voice.reference != nil
        let expected = spokenSeconds(piece)
        var parameters = model.defaultGenerationParameters
        if cloned { parameters.maxTokens = Int((expected * 1.3 + 0.4) * 12.5) }
        var said = 0.0
        do {
            let stream = model.generateStream(
                text: piece, voice: voice.reference == nil ? request.voice : nil, refAudio: voice.reference,
                refText: voice.referenceText, language: request.language,
                generationParameters: parameters, streamingInterval: 0.4)
            for try await event in stream {
                guard stopCount == Stops.shared.current else { return }
                guard case .audio(let audio) = event else { continue }
                let samples = audio.asArray(Float.self)
                if cloned, said > expected * 1.1, loudness(samples) < 0.015 {
                    log(String(format: "ended a piece at %.1f s, past its words (about %.1f s)", said, expected))
                    break
                }
                said += Double(samples.count) / Double(model.sampleRate)
                let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
                Events.shared.send(["event": "audio", "id": id, "pcm": pcm])
            }
        } catch {
            Events.shared.send(["event": "error", "id": id, "message": error.localizedDescription])
            return
        }
        guard stopCount == Stops.shared.current else { return }
    }
    Memory.clearCache()
}

/// About how long Penny takes to say `text`: 0.06 s a character, more for digits ("$4,250" is five words aloud).
func spokenSeconds(_ text: String) -> Double {
    0.4 + 0.058 * Double(text.count + 8 * text.filter(\.isNumber).count)
}

/// Root-mean-square level of a piece of audio: speech is above 0.03, a pause below 0.015.
func loudness(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

/// Text short enough for the model to say well: long sentences split at commas and dashes, then between words.
func pieces(of text: String, limit: Int = 280) -> [String] {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count > limit else { return text.isEmpty ? [] : [text] }
    var pieces: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        if !current.isEmpty, current.count + word.count + 1 > limit {
            pieces.append(current)
            current = ""
        }
        current += current.isEmpty ? String(word) : " " + word
        if current.count > limit / 2, let last = word.last, ",;:—–".contains(last) {
            pieces.append(current)
            current = ""
        }
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
}

// From the command line (`speak`, `transcribe`): one job, then exit, skipping the GPU teardown as below. Otherwise,
// requests from the app on stdin.
if CommandLine.arguments.count > 1, !CommandLine.arguments[1].hasPrefix("-") {
    _ = Events.shared
    _exit(await Commands.run(Array(CommandLine.arguments.dropFirst())))
}

// Keep the GPU's spare buffers small: the model is small, and the Mac has other work to do.
Memory.cacheLimit = 128 * 1024 * 1024

let (requests, queue) = AsyncStream<(Request, Int)>.makeStream()
// Stops act at once, even while a sentence is being made; everything else waits its turn.
Task.detached { [queue] in
    let decoder = JSONDecoder()
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else {
                log("unreadable request")
                continue
            }
            if request.op == "stop" { Stops.shared.stop() } else { queue.yield((request, Stops.shared.current)) }
        }
    } catch {
        log("stdin: \(error.localizedDescription)")
    }
    // The app closed the pipe or quit: leave at once. Tearing the GPU state down under a sentence still being made
    // crashes, so skip the usual cleanup.
    queue.finish()
    _exit(0)
}
await speak(requests)
