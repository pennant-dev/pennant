import PennantCore
@testable import PennantHostKit
import XCTest

/// Pennant's own meaning search talks to `Pennant Voice embed` over JSON lines. A stand-in helper (a shell script) answers
/// as the real one does, so these run without a GPU or a download.
final class EmbeddingProviderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A helper that says it's ready, then answers each request with one [1, 0] per text; it notes each start in `starts`.
    private func helper(_ body: String? = nil) throws -> URL {
        let script = folder.appendingPathComponent("helper.sh")
        let answer = body ?? """
        echo start >> "\(folder.path)/starts"
        [ "$1" = "embed" ] || exit 2
        echo '{"event":"ready","model":"fake","dimensions":2}'
        while IFS= read -r line; do
          id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          n=$(echo "$line" | awk -F'","' '{print NF}')
          v=$(awk -v n="$n" 'BEGIN{for(i=1;i<=n;i++){printf "%s[1,0]", (i>1?",":"")}}')
          echo "{\\"id\\":$id,\\"vectors\\":[$v]}"
        done
        """
        try ("#!/bin/sh\n" + answer + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private var starts: Int {
        ((try? String(contentsOf: folder.appendingPathComponent("starts"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func testVectorsComeBackInOrderFromOneHelper() async throws {
        let provider = PennantEmbeddingProvider(executable: try helper(), model: "fake", modelsDirectory: folder.appendingPathComponent("Models"))
        let three = try await provider.embed(["harbor", "venue", "maya"])
        XCTAssertEqual(three, [[1, 0], [1, 0], [1, 0]])
        let one = try await provider.embed(["dana"])
        XCTAssertEqual(one, [[1, 0]])
        XCTAssertEqual(starts, 1, "the helper stays up between requests")
        let empty = try await provider.embed([])
        XCTAssertTrue(empty.isEmpty)
        await provider.stop()
    }

    func testAHelperThatCantLoadFailsFastAndIsntRestartedAtOnce() async throws {
        let failing = try helper("""
        echo start >> "\(folder.path)/starts"
        echo '{"event":"error","message":"The embedding model didn'"'"'t load: offline"}'
        exit 1
        """)
        let provider = PennantEmbeddingProvider(executable: failing, model: "fake", modelsDirectory: folder.appendingPathComponent("Models"))
        let began = Date()
        do {
            _ = try await provider.embed(["harbor"])
            XCTFail("no model, no vectors")
        } catch {
            XCTAssertTrue("\(error)".contains("offline"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 4, "a lookup doesn't wait out a helper that failed")
        do {
            _ = try await provider.embed(["venue"])
            XCTFail("still no model")
        } catch {}
        XCTAssertEqual(starts, 1, "a helper that couldn't load isn't started again straight away")
    }

    func testAHelperThatExitsIsStartedAgainOnTheNextCall() async throws {
        // Answers one request, then exits.
        let once = try helper("""
        echo start >> "\(folder.path)/starts"
        echo '{"event":"ready","model":"fake","dimensions":2}'
        IFS= read -r line
        id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
        echo "{\\"id\\":$id,\\"vectors\\":[[0,1]]}"
        """)
        let provider = PennantEmbeddingProvider(executable: once, model: "fake", modelsDirectory: folder.appendingPathComponent("Models"))
        let first = try await provider.embed(["harbor"])
        XCTAssertEqual(first, [[0, 1]])
        // Its exit is noticed, and a helper that was working isn't held back: the next call starts a fresh one.
        try await Task.sleep(for: .milliseconds(300))
        let second = try await provider.embed(["venue"])
        XCTAssertEqual(second, [[0, 1]])
        XCTAssertEqual(starts, 2)
    }

    /// The real helper and model, when PENNANT_VOICE_HELPER points at a built Pennant Voice (and the model is downloaded or
    /// can be): a question finds the memory that answers it.
    func testTheRealModelFindsWhatAnswersAQuestion() async throws {
        guard let path = ProcessInfo.processInfo.environment["PENNANT_VOICE_HELPER"] else { throw XCTSkip("set PENNANT_VOICE_HELPER to a built Pennant Voice") }
        let models = ProcessInfo.processInfo.environment["PENNANT_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("Models")
        let provider = PennantEmbeddingProvider(executable: URL(fileURLWithPath: path), model: HostConfig.Embeddings.builtInModel, modelsDirectory: models)
        await provider.prepare()
        let notes = ["Maya booked the Harbor room for the team dinner on Thursday.", "Dana's flight lands at 7:55 on Friday.", "The venue wants a deposit by the end of the month."]
        let docs = try await provider.embed(notes)
        let query = try await provider.embed(["Instruct: Given a question, retrieve the notes and conversation passages that answer it\nQuery:When does Dana arrive?"])[0]
        XCTAssertEqual(docs.count, 3)
        XCTAssertEqual(query.count, docs[0].count)
        let scores = docs.map { zip($0, query).reduce(0) { $0 + $1.0 * $1.1 } }
        XCTAssertEqual(scores.firstIndex(of: scores.max()!), 1, "\(scores)")
        await provider.stop()
    }
}
