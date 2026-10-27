import Foundation

/// Whether a shell command only looks: every command in it reads (listing, searching, showing, a GET) and nothing is
/// written to a file. A goal set to "Only propose" holds back what changes things; a command that only reads runs.
/// Anything not known to be a read counts as a change.
enum ShellReads {
    static func isReadOnly(_ command: String) -> Bool {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !writesToFile(command) else { return false }
        let commands = ShellWords.commands(command)
        return !commands.isEmpty && commands.allSatisfy { reads(ShellWords.strippedLead($0)) }
    }

    /// Programs that only read, whatever they're given.
    static let readers: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "rg", "grep", "egrep", "fgrep", "which", "whereis", "type", "tree", "pwd", "echo",
        "printf", "date", "cal", "du", "df", "stat", "file", "basename", "dirname", "realpath", "readlink", "sort", "uniq",
        "cut", "tr", "jq", "yq", "column", "nl", "diff", "cmp", "comm", "md5", "shasum", "sha256sum", "test", "[", "[[", "]]",
        "true", "false", ":", "id", "whoami", "hostname", "uname", "sw_vers", "printenv", "ps", "pgrep", "lsof", "mdfind",
        "mdls", "otool", "nm", "strings", "xxd", "hexdump", "od", "sleep", "cd", "pushd", "popd", "export", "local",
        "unset", "set", "read", "exit", "return", "done", "fi", "esac", "in", "for", "case", "then", "do", "else", "elif",
        "fold", "fmt", "rev", "expand", "seq", "bc", "expr", "less", "more", "fd", "ag", "tokei", "cloc",
    ]

    static func reads(_ words: [String]) -> Bool {
        guard let first = words.first else { return true }
        let program = (first as NSString).lastPathComponent
        let args = Array(words.dropFirst())
        let positional = args.filter { !$0.hasPrefix("-") }
        let sub = positional.first ?? ""
        func has(_ flags: String...) -> Bool { args.contains { a in flags.contains { a == $0 || a.hasPrefix($0 + "=") } } }
        if readers.contains(program) { return true }
        switch program {
        case "env", "time", "nice", "command", "xargs", "nohup":
            var rest = args
            while let f = rest.first, f.hasPrefix("-") || f.contains("=") { rest.removeFirst() }
            return rest.isEmpty ? program == "env" : reads(rest)
        case "find":
            return !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls"].contains($0) }
        case "sed":
            // -i edits in place; a `w file` command writes one.
            return !args.contains { $0.hasPrefix("-i") || $0.hasPrefix("--in-place") || $0.range(of: #"(^|[;/}\s])w\s+\S"#, options: .regularExpression) != nil }
        case "awk", "gawk":
            return !args.contains { $0.contains("system") || $0.contains(">") || $0.contains("|") }
        case "git":
            var rest = args
            while let option = rest.first, option.hasPrefix("-") {
                rest.removeFirst()
                if ["-C", "-c", "--git-dir", "--work-tree"].contains(option), !rest.isEmpty { rest.removeFirst() }
            }
            guard let verb = rest.first else { return true }
            let more = Array(rest.dropFirst())
            let named = more.filter { !$0.hasPrefix("-") }
            switch verb {
            case "status", "diff", "log", "show", "rev-parse", "ls-files", "ls-tree", "blame", "describe", "shortlog",
                 "cat-file", "grep", "rev-list", "merge-base", "whatchanged", "show-ref", "for-each-ref", "name-rev", "count-objects":
                return true
            case "branch", "tag":
                // Listing only: a name would make one.
                return named.isEmpty || more.contains { ["-l", "--list", "-a", "-r", "--contains", "--merged", "--no-merged", "--points-at"].contains($0) } && !more.contains { ["-d", "-D", "--delete", "-m", "-M", "-c", "-C", "-f", "--force"].contains($0) }
            case "remote": return named.isEmpty || named.first == "show" || named.first == "get-url"
            case "config": return more.contains { ["--get", "--get-all", "--list", "-l", "--get-regexp"].contains($0) }
            case "worktree", "stash": return named.first == "list"
            case "reflog": return named.isEmpty || named.first == "show"
            default: return false
            }
        case "gh":
            switch sub {
            case "pr", "issue", "run", "release", "repo", "workflow", "label", "gist", "cache", "ruleset":
                let verb = positional.dropFirst().first ?? ""
                return ["view", "list", "diff", "checks", "status"].contains(verb)
            case "search", "status": return true
            case "auth": return positional.dropFirst().first == "status"
            case "api":
                // A GET: no other method, and no fields (fields make it a POST).
                if let i = args.firstIndex(where: { $0 == "-X" || $0 == "--method" }), i + 1 < args.count, args[i + 1].uppercased() != "GET" { return false }
                if args.contains(where: { ($0.hasPrefix("-X") && $0.count > 2 && $0.uppercased() != "-XGET") || ($0.hasPrefix("--method=") && $0.uppercased() != "--METHOD=GET") }) { return false }
                return !has("-f", "-F", "--field", "--raw-field", "--input")
            default: return false
            }
        case "kubectl", "oc":
            return ["get", "describe", "logs", "top", "explain", "version", "api-resources", "api-versions", "cluster-info"].contains(sub)
                || (sub == "config" && ["view", "get-contexts", "current-context", "get-clusters"].contains(positional.dropFirst().first ?? ""))
                || (sub == "auth" && positional.dropFirst().first == "can-i")
        case "az":
            // The command is the words before the first option: `az aks nodepool list -g rg`.
            let verbs = Array(args.prefix { !$0.hasPrefix("-") })
            guard let last = verbs.last else { return false }
            return ["list", "show", "get", "query", "list-usage", "list-skus", "list-locations"].contains(last)
                || (verbs.first == "account" && ["show", "list"].contains(last)) || verbs == ["version"]
        case "aws":
            let verbs = Array(args.prefix { !$0.hasPrefix("-") })
            let sub = verbs.first ?? ""
            let verb = verbs.dropFirst().first ?? ""
            return verb.hasPrefix("describe-") || verb.hasPrefix("list-") || verb.hasPrefix("get-") || (sub == "s3" && verb == "ls")
                || (sub == "sts" && verb == "get-caller-identity")
        case "curl":
            if let i = args.firstIndex(where: { $0 == "-X" || $0 == "--request" }), i + 1 < args.count, !["GET", "HEAD"].contains(args[i + 1].uppercased()) { return false }
            return !args.contains { a in
                ["-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "-o", "--output", "-O", "--remote-name", "--json"].contains { a == $0 || a.hasPrefix($0 + "=") }
                    || (a.hasPrefix("-X") && a.count > 2 && !["-XGET", "-XHEAD"].contains(a.uppercased()))
            }
        case "terraform", "tofu":
            return ["show", "output", "validate", "version", "providers", "graph"].contains(sub) || (sub == "state" && ["list", "show"].contains(positional.dropFirst().first ?? ""))
        case "docker", "podman":
            return ["ps", "images", "logs", "inspect", "version", "info", "stats"].contains(sub)
        case "brew": return ["list", "info", "search", "outdated", "deps", "uses", "config", "--version"].contains(sub)
        case "npm", "pnpm", "yarn": return ["ls", "list", "view", "info", "outdated", "why", "explain"].contains(sub)
        case "defaults": return sub == "read" || sub == "domains"
        case "plutil": return has("-p", "-lint")
        case "security": return sub == "find-certificate" || sub == "list-keychains"
        default: return false
        }
    }

    /// An output redirection to a file (`>`, `>>`, `&>`, `tee`), outside quotes. Copies to standard error and
    /// /dev/null don't count.
    static func writesToFile(_ command: String) -> Bool {
        let chars = Array(command)
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"", c == "\\" { i += 2; continue }
                if c == q { quote = nil }
                i += 1
                continue
            }
            switch c {
            case "'", "\"": quote = c
            case "\\": i += 1
            case ">":
                var j = i + 1
                if j < chars.count, chars[j] == ">" { j += 1 }
                // >&2, 2>&1
                if j < chars.count, chars[j] == "&" { i = j + 1; continue }
                while j < chars.count, chars[j] == " " { j += 1 }
                let target = String(chars[j...].prefix { !" \t\n;&|)".contains($0) })
                if target != "/dev/null" && target != "/dev/stderr" && target != "/dev/stdout" { return true }
                i = j
                continue
            default: break
            }
            i += 1
        }
        return ShellWords.commands(command).contains { ($0.first as NSString?)?.lastPathComponent == "tee" }
    }
}
