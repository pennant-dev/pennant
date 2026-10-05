import Foundation

/// A reply as it's read aloud in Talk mode: whole sentences as they stream in, without the Markdown, links, code and
/// emoji that read badly.
public enum SpokenText {
    /// The complete sentences in `text` from `offset` on, and where the unfinished rest begins. A sentence is
    /// complete once its end mark (. ! ? …) is followed by a space, or at a line break; with `final`, the rest counts
    /// too.
    public static func sentences(in text: String, from offset: Int, final: Bool) -> (sentences: [String], offset: Int) {
        let characters = Array(text)
        guard offset < characters.count else { return ([], characters.count) }
        var found: [String] = []
        var start = offset
        var i = offset
        while i < characters.count {
            let c = characters[i]
            let next = i + 1 < characters.count ? characters[i + 1] : nil
            let endsSentence = ".!?…".contains(c) && (next == " " || next == "\n")
            if c == "\n" || endsSentence {
                let piece = String(characters[start ... i])
                if let spoken = clean(piece) { found.append(spoken) }
                start = i + 1
            }
            i += 1
        }
        if final, start < characters.count {
            if let spoken = clean(String(characters[start...])) { found.append(spoken) }
            start = characters.count
        }
        return (found, start)
    }

    /// Too long to read out as it is: a report, links, details for the screen. Talk mode says the gist instead.
    public static func isLong(_ text: String) -> Bool {
        text.count > 280
    }

    /// How a piece of a reply should be said, or nil when nothing in it is worth saying aloud.
    public static func clean(_ piece: String) -> String? {
        var s = piece
        // Code is for the screen.
        s = s.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        // [the words](address) reads as the words; a bare address isn't read.
        s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Headings, bullets, quotes and numbering at the start of a line; emphasis marks anywhere.
        s = s.replacingOccurrences(of: #"(?m)^\s*(#{1,6}\s+|[-*+•]\s+|>\s*|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|~~)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        // Table rules and pipes.
        s = s.replacingOccurrences(of: #"(?m)^\s*\|?[\s:|-]+\|[\s:|-]*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*\|\s*|\s*\|\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\|\s*"#, with: ", ", options: .regularExpression)
        s = String(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) })
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.rangeOfCharacter(from: .alphanumerics) == nil ? nil : s
    }

    /// Whether `heard` is only Pennant's own voice coming back through the microphone: every word of it is in what
    /// was just said.
    public static func isEcho(_ heard: String, of said: String) -> Bool {
        let heardWords = words(heard)
        guard !heardWords.isEmpty else { return true }
        let saidWords = Set(words(said))
        return heardWords.allSatisfy { saidWords.contains($0) }
    }

    /// How much of `heard` is words from what was just said, from 0 to 1.
    public static func echoShare(_ heard: String, of said: String) -> Double {
        let heardWords = words(heard)
        guard !heardWords.isEmpty else { return 1 }
        let saidWords = Set(words(said))
        return Double(heardWords.filter { saidWords.contains($0) }.count) / Double(heardWords.count)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
