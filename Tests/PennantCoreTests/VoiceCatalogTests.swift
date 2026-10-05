@testable import PennantCore
import XCTest

/// Talk mode's natural voices: what's downloaded, from where, and how their speech travels.
final class VoiceCatalogTests: XCTestCase {
    func testEveryVoiceIsInAPackAndKokoroDownloadsEachOfItsVoices() throws {
        XCTAssertEqual(VoiceCatalog.voice(VoiceCatalog.defaultVoice)?.pack, .kokoro)
        XCTAssertEqual(Set(VoiceCatalog.voices.map(\.id)).count, VoiceCatalog.voices.count)
        let files = Set(VoiceCatalog.pack(.kokoro).repos[0].files)
        for voice in VoiceCatalog.voices where voice.pack == .kokoro {
            XCTAssertTrue(files.contains("voices/\(voice.id).safetensors"), voice.id)
        }
        for pack in VoiceCatalog.packs {
            XCTAssertTrue(pack.repos[0].files.contains("config.json"), "\(pack.id): the model's config is what the helper loads it by")
            XCTAssertFalse(VoiceCatalog.voices.filter { $0.pack == pack.id }.isEmpty, "\(pack.id) has no voices")
        }
    }

    /// A revision that's a branch could change under a released app; a commit can't.
    func testDownloadsArePinnedToCommits() {
        for repo in VoiceCatalog.packs.flatMap(\.repos) {
            XCTAssertNotNil(repo.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression), repo.name)
        }
    }

    /// The helper's speech library finds a downloaded repository at hub/mlx-audio/<owner>_<name>; with a config.json
    /// there it uses it without going to the network.
    func testDownloadsLandWhereTheSpeechLibraryLooks() throws {
        let kokoro = VoiceCatalog.pack(.kokoro)
        let model = VoiceCatalog.directory(for: kokoro.repos[0])
        XCTAssertEqual(model.lastPathComponent, "mlx-community_Kokoro-82M-bf16")
        XCTAssertEqual(model.deletingLastPathComponent().lastPathComponent, "mlx-audio")
        XCTAssertEqual(model.deletingLastPathComponent().deletingLastPathComponent().path, VoiceCatalog.hubDirectory.path)
        let pronunciation = try XCTUnwrap(kokoro.repos.first { $0.name == "beshkenadze/kitten-tts-g2p" })
        XCTAssertTrue(pronunciation.addsConfig, "the pronunciation data has no config.json of its own")
    }

    /// Qwen's voices are a speaker and a style ("Ryan, warm…"); Kokoro's and Penny's are just the voice.
    func testSpeakersCarryTheirPacksStyle() throws {
        XCTAssertEqual(VoiceCatalog.speaker(for: try XCTUnwrap(VoiceCatalog.voice("af_heart"))), "af_heart")
        XCTAssertTrue(VoiceCatalog.speaker(for: try XCTUnwrap(VoiceCatalog.voice("Ryan"))).hasPrefix("Ryan, "))
        XCTAssertTrue(VoiceCatalog.voices.allSatisfy { !$0.id.contains(",") })
    }

    /// Penny is a cloned voice: her recording and its words ship inside Pennant Voice, where the helper finds them.
    func testPennysRecordingShipsWithTheHelper() throws {
        let name = try XCTUnwrap(VoiceCatalog.pack(.penny).reference)
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/PennantVoice")
        XCTAssertGreaterThan(try Data(contentsOf: helper.appendingPathComponent("\(name).wav")).count, 100_000)
        XCTAssertFalse(try String(contentsOf: helper.appendingPathComponent("\(name).txt"), encoding: .utf8).isEmpty)
        XCTAssertNil(VoiceCatalog.pack(.kokoro).reference)
    }

    /// Speech goes to the iPhone as 16-bit audio after a header, on the screen stream's binary channel; neither kind
    /// of frame passes for the other.
    func testSpeechFramesRoundTripAndArentScreenFrames() throws {
        let header = SpeechChunkHeader(speechID: "s1", sampleRate: 24_000, final: false)
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let frame = try SpeechChunkCodec.encode(header: header, samples: samples)
        let (decoded, back) = try SpeechChunkCodec.decode(frame)
        XCTAssertEqual(decoded, header)
        XCTAssertEqual(back.count, samples.count)
        for (a, b) in zip(samples, back) { XCTAssertEqual(a, b, accuracy: 0.001) }
        XCTAssertThrowsError(try ScreenFrameCodec.decode(frame))
        let screen = try ScreenFrameCodec.encode(header: ScreenFrameHeader(sequence: 1, width: 2, height: 2, owner: .nobody), jpeg: Data([1, 2, 3]))
        XCTAssertThrowsError(try SpeechChunkCodec.decode(screen))
    }

    #if os(macOS)
    func testHelperLinesBecomeEvents() throws {
        let samples: [Float] = [0, 0.25, -0.5]
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        let reader = LineReader()
        let events = reader.events(in: Data(#"{"event":"loaded","sampleRate":24000}"#.utf8 + [0x0A]) + Data(#"{"event":"audio","id":7,"pcm":"\#(pcm)"}"#.utf8))
        XCTAssertEqual(events.count, 1, "the audio line isn't finished yet")
        let rest = reader.events(in: Data([0x0A]) + Data(#"{"event":"done","id":7}"#.utf8 + [0x0A]))
        guard rest.count == 2, case .audio(let id, let got) = rest[0], case .done(7) = rest[1] else { return XCTFail("\(rest)") }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(got, samples)
    }
    #endif
}
