import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioSTT
@preconcurrency import MLXAudioTTS

/// Pennant Voice from the command line, for skills that make audio (a video's narration, say) with the same models as
/// Talk mode:
///
///   Pennant Voice speak --text "…" --out clip.wav [--voice Ryan] [--instruct "calm, warm"] [--language English]
///                       [--ref-audio sample.wav --ref-text "what the sample says"] [--temperature 0.7] [--model <repo>]
///   Pennant Voice transcribe --audio clip.wav [--language en] [--model <repo>]
///
/// `speak` uses Qwen3-TTS 1.7B: the CustomVoice model with a named speaker (and an optional style), or the Base model
/// cloning the voice in `--ref-audio`. `transcribe` uses Whisper large-v3-turbo. Each prints one line of JSON.
/// Models download on first use into Pennant's voice folder (Application Support/Pennant/Voices), unless
/// HF_HUB_CACHE points elsewhere.
enum Commands {
    static let stockModel = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
    static let cloneModel = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
    static let transcriptionModel = "mlx-community/whisper-large-v3-turbo"

    /// Runs `arguments` (the command first) and returns the exit status.
    static func run(_ arguments: [String]) async -> Int32 {
        if ProcessInfo.processInfo.environment["HF_HUB_CACHE"] == nil {
            let voices = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pennant/Voices/hub")
            setenv("HF_HUB_CACHE", voices.path, 1)
        }
        let options = Self.options(arguments.dropFirst())
        do {
            switch arguments.first {
            case "speak": try await speak(options)
            case "transcribe": try await transcribe(options)
            default: throw CommandError.usage
            }
            return 0
        } catch {
            Events.shared.send(["ok": false, "error": error.localizedDescription])
            return 1
        }
    }

    static func speak(_ options: [String: String]) async throws {
        guard let text = options["text"], !text.isEmpty, let out = options["out"] else { throw CommandError.usage }
        let reference = options["ref-audio"].map { URL(fileURLWithPath: $0) }
        let model = try await TTS.loadModel(modelRepo: options["model"] ?? (reference == nil ? stockModel : cloneModel))
        var parameters = model.defaultGenerationParameters
        if let temperature = options["temperature"].flatMap(Float.init) { parameters.temperature = temperature }
        let refAudio = try reference.map { try loadAudioArray(from: $0, sampleRate: model.sampleRate).1 }
        // A named speaker takes its style after a comma ("Ryan, calm and warm"); a cloned voice has no name.
        var voice: String?
        if reference == nil {
            let speaker = options["voice"] ?? "Ryan"
            voice = options["instruct"].map { "\(speaker), \($0)" } ?? speaker
        }
        let audio = try await model.generate(
            text: text, voice: voice, refAudio: refAudio, refText: options["ref-text"], language: options["language"],
            generationParameters: parameters)
        let samples = audio.asArray(Float.self)
        try AudioUtils.writeWavFile(samples: samples, sampleRate: model.sampleRate, fileURL: URL(fileURLWithPath: out))
        Events.shared.send(["ok": true, "file": out, "seconds": Double(samples.count) / Double(model.sampleRate)])
    }

    static func transcribe(_ options: [String: String]) async throws {
        guard let path = options["audio"] else { throw CommandError.usage }
        let model = try await STT.loadModel(modelRepo: options["model"] ?? transcriptionModel)
        let (_, audio) = try loadAudioArray(from: URL(fileURLWithPath: path), sampleRate: 16_000)
        let defaults = model.defaultGenerationParameters
        let parameters = STTGenerateParameters(
            maxTokens: defaults.maxTokens, temperature: defaults.temperature, topP: defaults.topP, topK: defaults.topK,
            language: options["language"] ?? "en", chunkDuration: defaults.chunkDuration,
            minChunkDuration: defaults.minChunkDuration, repetitionPenalty: defaults.repetitionPenalty,
            repetitionContextSize: defaults.repetitionContextSize)
        let output = model.generate(audio: audio, generationParameters: parameters)
        Events.shared.send(["ok": true, "text": output.text.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    /// `--name value` pairs.
    static func options(_ arguments: ArraySlice<String>) -> [String: String] {
        var options: [String: String] = [:]
        var key: String?
        for argument in arguments {
            if argument.hasPrefix("--") {
                key = String(argument.dropFirst(2))
            } else if let name = key {
                options[name] = argument
                key = nil
            }
        }
        return options
    }
}

enum CommandError: LocalizedError {
    case usage
    var errorDescription: String? {
        """
        usage: Pennant Voice speak --text "…" --out file.wav [--voice Ryan] [--instruct style] [--language English] \
        [--ref-audio sample.wav --ref-text "…"] [--temperature 0.7] [--model repo]
               Pennant Voice transcribe --audio file.wav [--language en] [--model repo]
        """
    }
}
