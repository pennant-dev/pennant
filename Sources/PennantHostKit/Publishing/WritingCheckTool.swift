import PennantCore
import Foundation

/// A deterministic check for the tells that make text read as machine-written. The model rewrites; this finds what
/// is left, so "humanize it several times" has a concrete stopping point: zero findings.
public struct WritingCheckTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "ai_writing_check",
            description: "Check a draft for the patterns that make writing sound AI-generated (stock phrases like \"unlock\" or \"in today's fast-paced world\", em-dashes, \"it's not X, it's Y\", rule-of-three lists, question hooks, generic closers, emoji bullets, hashtag walls, uniform sentence length). Returns each finding with the exact text and a score. Rewrite and check again until it reports no findings.",
            inputSchema: JSONSchema.object(["text": JSONSchema.string("The draft to check.")], required: ["text"]),
            isConsequential: false,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let findings = Self.check(try arguments.requireString("text"))
        if findings.isEmpty {
            return .text(ToolCallID("pending"), name: spec.name, "No findings. The draft passes the AI-writing check.")
        }
        let lines = findings.map { "- \($0.rule): \"\($0.excerpt)\" → \($0.fix)" }
        return .text(ToolCallID("pending"), name: spec.name, "\(findings.count) finding(s). Fix them and check again:\n" + lines.joined(separator: "\n"))
    }

    struct Finding: Equatable {
        var rule: String
        var excerpt: String
        var fix: String
    }

    static let stockPhrases = [
        "game-changer", "game changer", "unlock", "unleash", "supercharge", "leverage", "in today's", "fast-paced", "ever-evolving",
        "ever-changing", "let's dive", "dive into", "deep dive", "delve", "revolutionize", "revolutionise", "seamless", "seamlessly",
        "at the end of the day", "navigate the", "navigating the", "landscape", "realm", "tapestry", "testament to", "paradigm",
        "harness the power", "the power of", "cutting-edge", "state-of-the-art", "robust", "elevate", "empower", "transformative",
        "in conclusion", "moreover", "furthermore", "it's worth noting", "it is worth noting", "crucial", "pivotal", "embark",
        "journey", "buckle up", "here's the thing", "here's what", "the real question", "spoiler", "hot take", "unpopular opinion",
        "let that sink in", "read that again", "thoughts?", "agree?", "what do you think?", "drop a comment", "💡", "🚀", "🔥", "👇", "✅",
        "synergy", "holistic", "streamline", "actionable insights", "north star", "double-click", "move the needle", "at scale",
        "not just", "more than just", "whether you're",
    ]

    static func check(_ text: String) -> [Finding] {
        var out: [Finding] = []
        let lower = text.lowercased()
        for phrase in stockPhrases where lower.contains(phrase) {
            out.append(Finding(rule: "Stock phrase", excerpt: excerpt(text, around: phrase), fix: "say the specific thing instead of \"\(phrase)\""))
        }
        let dashes = text.components(separatedBy: "—").count - 1 + text.components(separatedBy: " – ").count - 1
        if dashes > 0 {
            out.append(Finding(rule: "Em-dash", excerpt: "\(dashes) dash(es)", fix: "use a full stop, comma or parentheses; em-dashes are the most recognisable AI tell"))
        }
        for pattern in ["it's not (just )?[^.,;]{2,40}[,;] it's", "it isn't [^.,;]{2,40}[,;] it's", "this isn't [^.,;]{2,40}[.,;] it's", "not because [^.]{2,60}, but because"] {
            if let r = lower.range(of: pattern, options: .regularExpression) {
                out.append(Finding(rule: "Contrast formula", excerpt: String(lower[r]).prefix(80).description, fix: "state the point directly"))
            }
        }
        // Rule of three: "X, Y, and Z" lists stacked as rhetoric.
        let triads = lower.matches(of: /\b\w+(?: \w+)?, \w+(?: \w+)?,? and \w+(?: \w+)?\b/).count
        if triads >= 2 {
            out.append(Finding(rule: "Rule of three", excerpt: "\(triads) three-item lists", fix: "keep one list at most; use two items or four, or a plain sentence"))
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        if firstLine.hasSuffix("?") {
            out.append(Finding(rule: "Question hook", excerpt: firstLine.prefix(80).description, fix: "open with the observation or the fact, not a question"))
        }
        let lastLine = text.split(separator: "\n").last.map(String.init)?.lowercased() ?? ""
        if lastLine.hasSuffix("?") || ["curious", "let me know", "would love to hear", "share your"].contains(where: lastLine.contains) {
            out.append(Finding(rule: "Engagement-bait closer", excerpt: lastLine.prefix(80).description, fix: "end on the point or a concrete next step, not a prompt for comments"))
        }
        let bulletEmoji = text.split(separator: "\n").filter { line in line.first.map { $0.unicodeScalars.first?.properties.isEmojiPresentation == true } ?? false }
        if bulletEmoji.count >= 2 {
            out.append(Finding(rule: "Emoji bullets", excerpt: bulletEmoji.first.map(String.init)?.prefix(60).description ?? "", fix: "use plain lines or numbers"))
        }
        // Markdown shows up literally on LinkedIn, X, Reddit titles and most social sites.
        if let md = text.firstMatch(of: /`[^`\n]+`|\*\*[^*\n]+\*\*|__[^_\n]+__|^#{1,6} |\[[^\]\n]+\]\(http/.anchorsMatchLineEndings()) {
            out.append(Finding(rule: "Markdown syntax", excerpt: String(md.output).prefix(60).description, fix: "social posts show backticks, asterisks and [links](…) literally; write plain text (names in plain words, URLs bare)"))
        }
        let hashtags = text.matches(of: /#\w+/).count
        if hashtags > 3 {
            out.append(Finding(rule: "Hashtag wall", excerpt: "\(hashtags) hashtags", fix: "keep 0 to 3"))
        }
        let sentences = text.split(whereSeparator: { ".!?\n".contains($0) }).map { $0.split(separator: " ").count }.filter { $0 >= 3 }
        if sentences.count >= 6 {
            let mean = Double(sentences.reduce(0, +)) / Double(sentences.count)
            let variance = sentences.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(sentences.count)
            if sqrt(variance) < 3.5 {
                out.append(Finding(rule: "Uniform rhythm", excerpt: String(format: "sentences average %.0f words and barely vary", mean), fix: "mix very short sentences with longer ones, the way people write"))
            }
        }
        let oneLiners = text.split(separator: "\n", omittingEmptySubsequences: true).filter { $0.split(separator: " ").count <= 6 }.count
        if oneLiners >= 6 {
            out.append(Finding(rule: "Line-per-thought formatting", excerpt: "\(oneLiners) very short lines", fix: "write in paragraphs; the broetry format reads as templated"))
        }
        return out
    }

    static func excerpt(_ text: String, around phrase: String) -> String {
        guard let r = text.range(of: phrase, options: .caseInsensitive) else { return phrase }
        let start = text.index(r.lowerBound, offsetBy: -25, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 25, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start ..< end]).replacingOccurrences(of: "\n", with: " ")
    }
}
