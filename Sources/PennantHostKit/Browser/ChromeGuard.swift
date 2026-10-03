import Foundation

/// AppleScript that drives the owner's Chrome takes over the window they're working in. That means bringing it
/// forward, opening tabs, changing pages, or running script in them. Pennant works there through tabs of its own
/// instead. Asking Chrome which page is open, or reading the page's text, only looks, and stays allowed.
enum ChromeGuard {
    private static let targets = #"(tell\s+(application|app)\s+(id\s+)?\\?["'](google chrome|com\.google\.chrome)|application\(\s*\\?["'](google chrome|com\.google\.chrome))"#
    /// Bringing Chrome forward, or opening, moving, reloading or closing its tabs and windows.
    private static let windowActions = [
        #"\bactivate\b"#, #"\bmake\s+new\b"#, #"\bset\s+(the\s+)?(url|active\s+tab|index)\b"#, #"\breload\b"#, #"\bopen\s+location\b"#,
        #"\bclose\b"#, #"\bgo\s+(back|forward)\b"#, #"\.url\s*="#, #"\.activate\(\)"#,
    ]
    /// Script run in their page that changes it: clicking, submitting, filling in, navigating.
    private static let pageChanges = [
        #"\.click\("#, #"\.submit\("#, #"requestsubmit"#, #"location(\.href)?\s*="#, #"location\.(assign|replace)\("#, #"\.value\s*="#,
        #"\.checked\s*="#, #"dispatchevent"#, #"\.focus\("#, #"history\.(back|forward|go)"#, #"window\.open"#,
    ]

    /// A shell command whose AppleScript (or JXA) does something in Chrome, rather than only reading what's open. A
    /// script osascript runs from a file is judged by what the file says; `directory` is where the command runs.
    static func drivesChrome(_ command: String, in directory: String = NSHomeDirectory()) -> Bool {
        var line = command.lowercased()
        guard line.contains("osascript") else { return false }
        for path in scriptFiles(in: command, from: directory) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count < 1_000_000 else { continue }
            if let text = String(data: data, encoding: .utf8) {
                line += "\n" + text.lowercased()
            } else if matches(String(decoding: data, as: Unicode.ASCII.self).lowercased(), [#"google chrome|com\.google\.chrome"#]) {
                // A compiled script keeps the names of the apps it talks to but not its words: one that names Chrome
                // is taken to drive it.
                return true
            }
        }
        guard matches(line, [targets]) else { return false }
        if matches(line, windowActions) { return true }
        return matches(line, [#"\bexecute\b"#, #"\.execute\("#]) && matches(line, pageChanges)
    }

    /// The script files osascript is given to run, as full paths: its first argument that isn't an option, unless the
    /// script came with -e. A `cd` earlier in the command moves where a relative path starts.
    static func scriptFiles(in command: String, from directory: String) -> [String] {
        var files: [String] = []
        var here = directory
        for words in ShellWords.commands(command) {
            let w = ShellWords.strippedLead(words)
            if w.first == "cd", w.count > 1 { here = PathResolver.resolve(w[1], base: here); continue }
            guard let first = w.first, (first as NSString).lastPathComponent == "osascript" else { continue }
            var i = 1
            while i < w.count {
                let word = w[i]
                if word == "-e" { break }
                if word == "-l" || word == "-s" { i += 2; continue }
                if word.hasPrefix("-") { i += 1; continue }
                files.append(PathResolver.resolve(word, base: here))
                break
            }
        }
        return files
    }

    private static func matches(_ line: String, _ patterns: [String]) -> Bool {
        patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }
}
