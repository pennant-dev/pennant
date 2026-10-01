import PennantCore
import Foundation

/// Splits what was said into passages of about 140 words, as Binders does: whole paragraphs first, sentences when
/// a paragraph is too long, word windows when a sentence is. Each passage keeps who spoke first and when.
enum MemoryChunker {
    struct Block {
        var speaker: String
        var text: String
        var at: Date
        var messageID: MessageID?
    }

    struct Chunk {
        var text: String
        var speaker: String
        var at: Date
        var messageID: MessageID?
    }

    static let maxWords = 140

    static func chunks(_ blocks: [Block], maxWords: Int = maxWords) -> [Chunk] {
        var output: [Chunk] = []
        var lines: [String] = []
        var count = 0
        var start: Block?
        func flush() {
            guard !lines.isEmpty, let s = start else { return }
            output.append(Chunk(text: lines.joined(separator: "\n"), speaker: s.speaker, at: s.at, messageID: s.messageID))
            lines = []
            count = 0
            start = nil
        }
        for block in blocks {
            var first = true
            for piece in pieces(block.text, maxWords: maxWords) {
                let words = wordCount(piece)
                if count + words > maxWords { flush() }
                if lines.isEmpty { start = block }
                lines.append(first || lines.isEmpty ? "\(block.speaker): \(piece)" : piece)
                first = false
                count += words
            }
        }
        flush()
        return output
    }

    /// Paragraphs; over-long paragraphs become sentences, over-long sentences become word windows.
    static func pieces(_ text: String, maxWords: Int) -> [String] {
        var result: [String] = []
        for paragraph in text.components(separatedBy: .newlines) {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if wordCount(trimmed) <= maxWords {
                result.append(trimmed)
                continue
            }
            let sentences = trimmed.replacingOccurrences(of: "([.!?])\\s+", with: "$1\n", options: .regularExpression).components(separatedBy: "\n")
            for sentence in sentences {
                let words = sentence.split(whereSeparator: \.isWhitespace)
                if words.count <= maxWords {
                    if !words.isEmpty { result.append(sentence) }
                } else {
                    for s in stride(from: 0, to: words.count, by: maxWords) {
                        result.append(words[s ..< min(s + maxWords, words.count)].joined(separator: " "))
                    }
                }
            }
        }
        return result
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
}
