import Darwin
import Foundation
import HuggingFace
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXEmbedders
@preconcurrency import MLXLMCommon
import Tokenizers

/// Meaning search for Pennant's memory, on the Mac's GPU: `Pennant Voice embed` loads an embedding model (Qwen3-Embedding
/// unless `--model` names another), downloading it the first time, then answers requests from the host, one JSON line
/// each way:
///
///   (once loaded)                    → {"event":"ready","model":"mlx-community/Qwen3-Embedding-0.6B-8bit","dimensions":1024}
///   {"id":1,"texts":["…","…"]}       → {"id":1,"vectors":[[…],[…]]}   (unit length, one per text, in order)
///                                    → {"id":1,"error":"…"}           when a request fails
///
/// It exits when the host closes its end of the pipe.
enum Embedder {
    static let defaultModel = "mlx-community/Qwen3-Embedding-0.6B-8bit"
    /// Most of a text that's read; past it the rest is cut (memory passages are far shorter).
    static let maxTokens = 2048
    /// Texts in one pass on the GPU, by padded size: a batch of long passages goes through a few at a time.
    static let tokensPerPass = 16_384

    struct Request: Decodable {
        var id: Int
        var texts: [String]
    }

    static func serve(_ options: [String: String]) async -> Int32 {
        Memory.cacheLimit = 128 * 1024 * 1024
        let name = options["model"] ?? defaultModel
        let container: EmbedderModelContainer
        do {
            guard let repo = Repo.ID(rawValue: name) else { throw EmbedderError.badModel(name) }
            let directory = try await ModelUtils.resolveOrDownloadModel(repoID: repo, requiredExtension: "safetensors", additionalMatchingPatterns: ["*.json", "merges.txt"])
            container = try await EmbedderModelFactory.shared.loadContainer(from: directory, using: TokenizerBridge.Loader())
        } catch {
            Events.shared.send(["event": "error", "message": "The embedding model didn't load: \(error.localizedDescription)"])
            return 1
        }
        let dimensions = (try? await embed(["ready"], with: container).first?.count) ?? 0
        Events.shared.send(["event": "ready", "model": name, "dimensions": dimensions])

        let decoder = JSONDecoder()
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else {
                    log("unreadable embedding request")
                    continue
                }
                do {
                    let vectors = try await embed(request.texts, with: container)
                    Events.shared.send(["id": request.id, "vectors": vectors.map { $0.map { Double($0) } }])
                } catch {
                    Events.shared.send(["id": request.id, "error": error.localizedDescription])
                }
                Memory.clearCache()
            }
        } catch {
            log("stdin: \(error.localizedDescription)")
        }
        return 0
    }

    /// One unit vector per text, in order.
    static func embed(_ texts: [String], with container: EmbedderModelContainer) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await container.perform { context in
            // Qwen3's embedder reads each text's vector off its closing <|endoftext|>, which its tokenizer file asks for in
            // a form swift-transformers doesn't apply: it's added here.
            let closing = context.pooling.strategy == .last ? context.tokenizer.convertTokenToId("<|endoftext|>") : nil
            let padID = closing ?? context.tokenizer.convertTokenToId("<pad>") ?? 0
            let tokens = texts.map { text in
                var ids = Array(context.tokenizer.encode(text: text, addSpecialTokens: true).prefix(maxTokens - 1))
                if let closing, ids.last != closing { ids.append(closing) }
                return ids
            }
            // Shortest first, so each pass pads its texts to a similar length.
            let order = tokens.indices.sorted { tokens[$0].count < tokens[$1].count }
            var vectors = [[Float]](repeating: [], count: texts.count)
            var start = 0
            while start < order.count {
                var end = start + 1
                while end < order.count, (end - start + 1) * tokens[order[end]].count <= tokensPerPass { end += 1 }
                let pass = order[start ..< end]
                let width = max(1, tokens[order[end - 1]].count)
                let ids = pass.flatMap { i in tokens[i].map(Int32.init) + Array(repeating: Int32(padID), count: width - tokens[i].count) }
                // Which places hold a text and which padding, from the lengths: a model's padding token can also be the
                // one its texts end with (Qwen3's <|endoftext|>).
                let filled = pass.flatMap { i in Array(repeating: Float(1), count: tokens[i].count) + Array(repeating: Float(0), count: width - tokens[i].count) }
                let input = MLXArray(ids, [pass.count, width])
                let mask = MLXArray(filled, [pass.count, width])
                let output = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: mask .> 0)
                // A model with its own head pools itself; the rest pool as the model says (Qwen3: its last token).
                let pooled = output.pooledOutput ?? context.pooling(output, mask: mask)
                let unit = pooled / MLX.maximum(MLX.sqrt((pooled * pooled).sum(axis: -1, keepDims: true)), MLXArray(Float(1e-12)))
                eval(unit)
                for (row, i) in pass.enumerated() { vectors[i] = unit[row].asArray(Float.self) }
                start = end
            }
            return vectors
        }
    }
}

enum EmbedderError: LocalizedError {
    case badModel(String)
    var errorDescription: String? {
        switch self {
        case .badModel(let name): return "\(name) isn't a model name (owner/name)"
        }
    }
}

/// The tokenizer from swift-transformers, as MLX's embedders take it.
struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

    struct Loader: TokenizerLoader {
        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
        }
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}
