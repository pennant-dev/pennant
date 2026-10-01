import PennantCore
import XCTest

final class InferencePresetsTests: XCTestCase {
    /// The section-4 vendors plus the local servers Settings has always offered.
    private let expectedIDs = [
        "openai", "anthropic", "google-ai-studio", "xai", "mistral", "deepseek", "moonshot", "kimi-code",
        "zai", "zai-coding", "alibaba-coding", "alibaba-model-studio", "openrouter", "groq", "together",
        "fireworks", "perplexity", "ollama-cloud", "ollama", "lm-studio", "vllm",
    ]

    func testCatalogueCoversTheSpec() {
        let ids = Set(InferencePresets.all.map(\.id))
        for id in expectedIDs { XCTAssertTrue(ids.contains(id), "missing preset \(id)") }
    }

    func testIDsAreUniqueSlugs() {
        let ids = InferencePresets.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
        for id in ids {
            XCTAssertEqual(id, id.lowercased(), "\(id) should be lowercase")
            XCTAssertFalse(id.contains(" "), "\(id) should not contain spaces")
        }
        let urls = InferencePresets.all.map(\.baseURL)
        XCTAssertEqual(urls.count, Set(urls).count, "two presets share a base URL")
    }

    func testBaseURLsParseAndRemoteOnesUseHTTPS() throws {
        for p in InferencePresets.all {
            let url = try XCTUnwrap(URL(string: p.baseURL), "\(p.id): base URL does not parse")
            let host = try XCTUnwrap(url.host(), "\(p.id): base URL has no host")
            XCTAssertFalse(p.baseURL.hasSuffix("/"), "\(p.id): the host appends /models itself, so no trailing slash")
            if host == "localhost" || host == "127.0.0.1" {
                XCTAssertEqual(url.scheme, "http", "\(p.id): local servers are plain http")
            } else {
                XCTAssertEqual(url.scheme, "https", "\(p.id): remote endpoints must use https")
            }
        }
    }

    func testEveryKeyedPresetSaysWhereTheKeyComesFrom() throws {
        for p in InferencePresets.all {
            if p.needsKey {
                let help = try XCTUnwrap(p.keyHelpURL, "\(p.id): needs a key but has no key URL")
                let url = try XCTUnwrap(URL(string: help), "\(p.id): key URL does not parse")
                XCTAssertEqual(url.scheme, "https", "\(p.id): key URL must be https")
            } else {
                XCTAssertNil(p.keyHelpURL, "\(p.id): no key, so no key link")
            }
            if let docs = p.docsURL {
                XCTAssertEqual(URL(string: docs)?.scheme, "https", "\(p.id): docs URL must be https")
            }
        }
    }

    func testNamesAndExamplesAreFilled() {
        for p in InferencePresets.all {
            XCTAssertFalse(p.name.isEmpty, "\(p.id): empty name")
            XCTAssertFalse(p.publisher.isEmpty, "\(p.id): empty publisher")
            XCTAssertFalse(p.symbol.isEmpty, "\(p.id): empty symbol")
            if !p.supportsModelsEndpoint {
                XCTAssertFalse(p.exampleModels.isEmpty, "\(p.id): no models endpoint, so it must carry example ids")
            }
            for id in p.exampleModels { XCTAssertFalse(id.contains(" "), "\(p.id): model id \(id) has whitespace") }
        }
    }

    func testUnverifiedEntriesAreTheHypotheses() {
        let unverified = InferencePresets.all.filter { !$0.verified }.map(\.id)
        XCTAssertEqual(unverified, ["alibaba-model-studio"])
    }

    func testPresetByID() {
        XCTAssertEqual(InferencePresets.preset(id: "deepseek")?.name, "DeepSeek")
        XCTAssertNil(InferencePresets.preset(id: "nope"))
    }

    func testPresetForBaseURLMatchesByPrefix() {
        XCTAssertEqual(InferencePresets.preset(for: "https://api.deepseek.com")?.id, "deepseek")
        XCTAssertEqual(InferencePresets.preset(for: "https://api.deepseek.com/v1")?.id, "deepseek", "a longer path under the base still matches")
        XCTAssertEqual(InferencePresets.preset(for: "https://api.anthropic.com/v1/")?.id, "anthropic", "trailing slash is ignored")
        XCTAssertEqual(InferencePresets.preset(for: "  HTTPS://API.OPENAI.COM/v1 ")?.id, "openai", "scheme and host compare case-insensitively")
        XCTAssertEqual(InferencePresets.preset(for: "https://api.z.ai/api/coding/paas/v4")?.id, "zai-coding")
        XCTAssertEqual(InferencePresets.preset(for: "https://api.z.ai/api/paas/v4")?.id, "zai")
        XCTAssertEqual(InferencePresets.preset(for: "http://localhost:11434/v1")?.id, "ollama")
    }

    func testPresetForBaseURLRejectsLookalikes() {
        XCTAssertNil(InferencePresets.preset(for: "https://api.openai.com/v1beta"), "a different path segment is not a prefix match")
        XCTAssertNil(InferencePresets.preset(for: "https://api.openai.com"), "shorter than the base is no match")
        XCTAssertNil(InferencePresets.preset(for: "http://gpu-box.local:8000/v1"))
        XCTAssertNil(InferencePresets.preset(for: ""))
        XCTAssertNil(InferencePresets.preset(for: "   "))
    }

    func testEveryPresetMatchesItsOwnBaseURL() {
        for p in InferencePresets.all {
            XCTAssertEqual(InferencePresets.preset(for: p.baseURL)?.id, p.id, "\(p.id): its own base URL should resolve to it")
            XCTAssertEqual(InferencePresets.preset(for: p.baseURL + "/")?.id, p.id, "\(p.id): with a trailing slash too")
        }
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(InferencePresets.all)
        let back = try JSONDecoder().decode([InferencePreset].self, from: data)
        XCTAssertEqual(back, InferencePresets.all)
    }
}
