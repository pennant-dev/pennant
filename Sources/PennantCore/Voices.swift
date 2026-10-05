import Foundation

/// Pennant's natural voices: neural speech models that sound like a person, run on a Mac with Apple silicon by Pennant
/// Voice, the helper inside Pennant.app (Apps/PennantVoice). The Mac app downloads them, from Hugging Face at pinned
/// revisions. The helper speaks for Talk mode on the Mac and, through the host, for devices that can't run the models
/// themselves (the iPhone).
public enum VoiceCatalog {
    /// A model download: the files of one or more Hugging Face repositories.
    public struct Pack: Identifiable, Sendable {
        public enum ID: String, Codable, Sendable { case kokoro, penny, qwen }
        public var id: ID
        public var name: String
        public var detail: String
        /// The model's repository first; anything it needs besides (pronunciation data) after.
        public var repos: [Repo]
        /// The language the model is told to speak, for models that don't tell from the voice.
        public var language: String?
        /// How the voice should sound, for models that take a style with the speaker ("Ryan, warm and relaxed").
        public var style: String?
        /// A recording in the helper's bundle (`<name>.wav`, with its words in `<name>.txt`) whose voice the model clones.
        public var reference: String?
        /// The download's size in bytes, for progress and to say how big it is.
        public var size: Int64
    }

    public struct Repo: Hashable, Sendable {
        public var name: String
        public var revision: String
        public var files: [String]
        /// The speech library only uses a downloaded copy that has a config.json; some repositories have none.
        public var addsConfig = false
    }

    public struct Voice: Identifiable, Hashable, Codable, Sendable {
        public var id: String
        public var name: String
        public var detail: String
        public var pack: Pack.ID

        public init(id: String, name: String, detail: String, pack: Pack.ID) {
            self.id = id
            self.name = name
            self.detail = detail
            self.pack = pack
        }
    }

    /// Kokoro (82M, Apache 2.0): quick, light and natural; the default.
    static let kokoroVoices: [Voice] = [
        Voice(id: "af_heart", name: "Heart", detail: "American, warm", pack: .kokoro),
        Voice(id: "af_bella", name: "Bella", detail: "American, bright", pack: .kokoro),
        Voice(id: "am_michael", name: "Michael", detail: "American, calm", pack: .kokoro),
        Voice(id: "am_fenrir", name: "Fenrir", detail: "American, deep", pack: .kokoro),
        Voice(id: "am_puck", name: "Puck", detail: "American, lively", pack: .kokoro),
        Voice(id: "bf_emma", name: "Emma", detail: "British", pack: .kokoro),
        Voice(id: "bm_george", name: "George", detail: "British", pack: .kokoro),
        Voice(id: "bm_fable", name: "Fable", detail: "British", pack: .kokoro),
    ]

    /// Penny: Qwen3-TTS (0.6B, Apache 2.0) cloning the voice in a short recording that ships with the helper, a woman's
    /// voice with an English accent. The small model clones fast enough to talk with; the big one doesn't.
    static let pennyVoices: [Voice] = [
        Voice(id: "penny", name: "Penny", detail: "warm and natural", pack: .penny),
    ]

    /// Qwen3-TTS (1.7B, Apache 2.0): the most lifelike, a much bigger download, more of the GPU. Every speaker the
    /// model has; each speaks the reply's English in their own accent. Skills that narrate videos use the same model
    /// through `Pennant Voice speak`.
    static let qwenVoices: [Voice] = [
        Voice(id: "Ryan", name: "Ryan", detail: "English, expressive", pack: .qwen),
        Voice(id: "Aiden", name: "Aiden", detail: "American, sunny", pack: .qwen),
        Voice(id: "Vivian", name: "Vivian", detail: "Chinese, bright", pack: .qwen),
        Voice(id: "Serena", name: "Serena", detail: "Chinese, warm and gentle", pack: .qwen),
        Voice(id: "Uncle_Fu", name: "Uncle Fu", detail: "Chinese, low and mellow", pack: .qwen),
        Voice(id: "Dylan", name: "Dylan", detail: "Chinese, Beijing", pack: .qwen),
        Voice(id: "Eric", name: "Eric", detail: "Chinese, Sichuan", pack: .qwen),
        Voice(id: "Ono_Anna", name: "Ono Anna", detail: "Japanese, playful", pack: .qwen),
        Voice(id: "Sohee", name: "Sohee", detail: "Korean, warm", pack: .qwen),
    ]

    public static let voices = kokoroVoices + pennyVoices + qwenVoices
    public static let defaultVoice = "af_heart"

    public static let packs: [Pack] = [
        Pack(
            id: .kokoro, name: "Natural", detail: "Kokoro, quick and light",
            repos: [
                Repo(name: "mlx-community/Kokoro-82M-bf16", revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
                     files: ["config.json", "kokoro-v1_0.safetensors"] + kokoroVoices.map { "voices/\($0.id).safetensors" }),
                Repo(name: "beshkenadze/kitten-tts-g2p", revision: "9c692b92682d959d9013a9cfe6a49541997add18",
                     files: ["us_bart.safetensors", "us_bart_config.json", "us_gold.json", "us_silver.json"], addsConfig: true),
            ],
            size: 340_000_000),
        Pack(
            id: .penny, name: "Penny", detail: "Qwen3-TTS cloning Penny's recorded voice",
            repos: [
                Repo(name: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7",
                     files: qwenFiles),
            ],
            language: "English", reference: "penny", size: 1_990_000_000),
        Pack(
            id: .qwen, name: "Expressive", detail: "Qwen3-TTS, the most lifelike, uses more of the GPU",
            repos: [
                Repo(name: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776",
                     files: qwenFiles),
            ],
            language: "English", style: "warm, relaxed and friendly, like talking with someone you know", size: 4_520_000_000),
    ]

    /// What a Qwen3-TTS repository holds besides its read-me.
    private static let qwenFiles = [
        "config.json", "generation_config.json", "merges.txt", "model.safetensors", "model.safetensors.index.json",
        "preprocessor_config.json", "tokenizer_config.json", "vocab.json", "speech_tokenizer/config.json",
        "speech_tokenizer/configuration.json", "speech_tokenizer/model.safetensors", "speech_tokenizer/preprocessor_config.json",
    ]

    public static func pack(_ id: Pack.ID) -> Pack { packs.first { $0.id == id }! }
    public static func voice(_ id: String) -> Voice? { voices.first { $0.id == id } }

    /// The voice as the model takes it: the speaker, and the style for models that have one.
    public static func speaker(for voice: Voice) -> String {
        pack(voice.pack).style.map { "\(voice.id), \($0)" } ?? voice.id
    }

    // MARK: Where they live (the same for the app and the host: both run as the owner)

    public static var voicesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pennant/Voices")
    }

    /// Laid out as the speech library's Hugging Face cache, so the helper finds what was downloaded without the network.
    public static var hubDirectory: URL { voicesDirectory.appendingPathComponent("hub") }

    /// Where the speech library looks for a repository in its cache.
    public static func directory(for repo: Repo) -> URL {
        hubDirectory.appendingPathComponent("mlx-audio").appendingPathComponent(repo.name.replacingOccurrences(of: "/", with: "_"))
    }

    /// Written when every file of a pack is in place.
    public static func marker(for pack: Pack) -> URL {
        voicesDirectory.appendingPathComponent(".\(pack.id.rawValue)-complete")
    }

    public static func isComplete(_ pack: Pack) -> Bool {
        FileManager.default.fileExists(atPath: marker(for: pack).path)
    }
}

// MARK: Speech over the connection

/// Talk mode on a device that can't run the voices itself: the host makes the speech and streams it back.
public struct SpeechRequest: Hashable, Codable, Sendable {
    /// Chosen by the device; the audio comes back under it.
    public var id: String
    public var text: String
    /// A `VoiceCatalog` voice the host has downloaded.
    public var voice: String

    public init(id: String = UUID().uuidString, text: String, voice: String) {
        self.id = id
        self.text = text
        self.voice = voice
    }
}

/// Sent before each piece of speech on the binary channel, as a screen frame's header is.
public struct SpeechChunkHeader: Hashable, Codable, Sendable {
    public var speechID: String
    public var sampleRate: Int
    /// The last piece for this request; it may carry no audio.
    public var final: Bool
    /// Why it couldn't be said, on the last piece.
    public var error: String?

    public init(speechID: String, sampleRate: Int, final: Bool, error: String? = nil) {
        self.speechID = speechID
        self.sampleRate = sampleRate
        self.final = final
        self.error = error
    }
}

/// Binary speech frame: 4-byte big-endian header length, JSON `SpeechChunkHeader`, then 16-bit little-endian mono PCM.
public enum SpeechChunkCodec {
    public static func encode(header: SpeechChunkHeader, samples: [Float]) throws -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return try BinaryFrame.encode(header: header, payload: pcm)
    }

    public static func decode(_ data: Data) throws -> (SpeechChunkHeader, [Float]) {
        let (header, pcm) = try BinaryFrame.decode(SpeechChunkHeader.self, from: data)
        let samples = pcm.withUnsafeBytes { raw in
            (0 ..< raw.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / Float(Int16.max) }
        }
        return (header, samples)
    }
}

/// The layout binary frames share: 4-byte big-endian header length, the JSON header, then the payload.
enum BinaryFrame {
    static func encode<Header: Encodable>(header: Header, payload: Data) throws -> Data {
        let head = try JSONCodec.encode(header)
        var out = Data(capacity: 4 + head.count + payload.count)
        var len = UInt32(head.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(head)
        out.append(payload)
        return out
    }

    static func decode<Header: Decodable>(_ type: Header.Type, from data: Data) throws -> (Header, Data) {
        guard data.count >= 4 else { throw ProtocolError.malformedFrame }
        let len = data.prefix(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard data.count >= 4 + len else { throw ProtocolError.malformedFrame }
        let header = try JSONCodec.decode(Header.self, from: data.subdata(in: data.startIndex + 4 ..< data.startIndex + 4 + len))
        return (header, data.subdata(in: data.startIndex + 4 + len ..< data.endIndex))
    }
}
