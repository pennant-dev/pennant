import Foundation

/// A shell command line read as the simple commands in it, for the checks that judge commands (`SignOff`,
/// `GitHubGuard`).
enum ShellWords {
    /// The simple commands in a command line: split on unquoted `&&`, `||`, `;`, `|`, `&` and newlines, with the
    /// insides of `$(…)` and backticks judged as commands of their own.
    static func commands(_ line: String) -> [[String]] {
        var out: [[String]] = []
        var words: [String] = []
        var word = ""
        var quote: Character?
        var inner: [String] = []
        let chars = Array(line)
        var i = 0
        // A here-document's body (`<<'EOF'` … `EOF`) is text given to a command, not commands.
        var heredoc: String?
        func endWord() { if !word.isEmpty { words.append(word); word = "" } }
        func endCommand() { endWord(); if !words.isEmpty { out.append(words); words = [] } }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"", c == "\\", i + 1 < chars.count { word.append(chars[i + 1]); i += 2; continue }
                if c == q { quote = nil }
                else if q == "\"", c == "$", i + 1 < chars.count, chars[i + 1] == "(" , let close = matching(chars, from: i + 1) {
                    inner.append(String(chars[(i + 2)..<close])); i = close
                } else if q == "\"", c == "`", let close = chars[(i + 1)...].firstIndex(of: "`") {
                    inner.append(String(chars[(i + 1)..<close])); i = close
                } else { word.append(c) }
                i += 1; continue
            }
            switch c {
            case "'", "\"": quote = c
            case "\\": if i + 1 < chars.count { word.append(chars[i + 1]); i += 1 }
            case " ", "\t": endWord()
            case "\n" where heredoc != nil:
                endCommand()
                // Skip the body, up to the line that is just the delimiter.
                var j = i + 1
                while j < chars.count {
                    let end = chars[j...].firstIndex(of: "\n") ?? chars.count
                    let bodyLine = String(chars[j..<end]).trimmingCharacters(in: .whitespaces)
                    j = end + 1
                    if bodyLine == heredoc { break }
                }
                heredoc = nil
                i = j
                continue
            case "\n", ";", "&", "|": endCommand()
            case "(", ")", "{", "}": endWord()
            case "`":
                if let close = chars[(i + 1)...].firstIndex(of: "`") { inner.append(String(chars[(i + 1)..<close])); i = close }
            case "$" where i + 1 < chars.count && chars[i + 1] == "{":
                // ${name…}: a parameter expansion, part of the word.
                if let close = chars[(i + 1)...].firstIndex(of: "}") { word.append(contentsOf: chars[i...close]); i = close } else { word.append(c) }
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                if let close = matching(chars, from: i + 1) { inner.append(String(chars[(i + 2)..<close])); i = close } else { word.append(c) }
            case "<" where i + 1 < chars.count && chars[i + 1] == "<" && !(i + 2 < chars.count && chars[i + 2] == "<"):
                // <<EOF, <<-'EOF': a here-document; its delimiter ends the body.
                endWord()
                var j = i + 2
                if j < chars.count, chars[j] == "-" { j += 1 }
                while j < chars.count, chars[j] == " " { j += 1 }
                var delimiter = ""
                while j < chars.count, !" \n;&|<>()".contains(chars[j]) { if chars[j] != "'" && chars[j] != "\"" { delimiter.append(chars[j]) }; j += 1 }
                if !delimiter.isEmpty { heredoc = delimiter }
                i = j
                continue
            case ">", "<":
                // Redirection: the file after it isn't a command word.
                endWord()
                if i + 1 < chars.count, chars[i + 1] == ">" || chars[i + 1] == "&" { i += 1 }
            default: word.append(c)
            }
            i += 1
        }
        endCommand()
        return out + inner.flatMap(commands)
    }

    private static func matching(_ chars: [Character], from open: Int) -> Int? {
        var depth = 0
        for j in open..<chars.count {
            if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1; if depth == 0 { return j } }
        }
        return nil
    }

    /// Without leading assignments and loop or condition keywords, in any order.
    static func strippedLead(_ raw: [String]) -> [String] {
        var words = raw
        while let first = words.first {
            if ["do", "then", "else", "elif", "if", "while", "until", "!"].contains(first) { words.removeFirst(); continue }
            if first.contains("="), !first.hasPrefix("-"), first.first?.isLetter == true || first.first == "_" { words.removeFirst(); continue }
            break
        }
        return words
    }
}
