import PennantCore
import Foundation

/// The only things the owner signs off on before they happen; everything else an agent may simply do.
///   1. Publishing to a public page (LinkedIn, Reddit, YouTube, X…) or sending an email.
///   2. Deleting anything: files, branches, cloud resources, records, emails, posts.
///   3. Spending money: buying, subscribing, paying.
/// Pennant's own bookkeeping (memories, schedules, goal boards, tasks) isn't covered: agents tidy those freely.
public enum SignOff {
    public enum Reason: String, Sendable {
        case publishes, deletes, spends

        public var title: String {
            switch self {
            case .publishes: return "Publish or send"
            case .deletes: return "Delete"
            case .spends: return "Spend money"
            }
        }
        public var why: String {
            switch self {
            case .publishes: return "it publishes to a public page or sends an email"
            case .deletes: return "it deletes something"
            case .spends: return "it spends money"
            }
        }
    }

    // MARK: Tools

    static let socialNetworks = ["linkedin", "reddit", "youtube", "twitter", "x_com", "facebook", "instagram", "bluesky", "mastodon", "threads", "tiktok", "medium", "substack", "hubspot_social"]
    static let publishWords: Set<String> = ["post", "publish", "share", "submit", "comment", "reply", "upload", "tweet", "repost", "schedule"]
    static let deleteWords: Set<String> = ["delete", "remove", "destroy", "purge", "drop", "trash", "erase", "wipe", "uninstall", "unpublish"]
    static let spendWords: Set<String> = ["purchase", "buy", "pay", "payment", "charge", "subscribe", "order"]
    /// Pennant's own tools that delete its own bookkeeping, or that already come with an approval.
    static let exempt: Set<String> = ["request_approval", "ask_user", "post_report", "memory_forget", "forget_instruction", "cancel_schedule", "goal_update",
                                      "update_goal", "channel_send", "send_message", "list_contacts", "request_reviews", "link_reviewer", "approve_review_batch"]

    /// Why a tool call needs the owner's sign-off, or nil. Tools that take an `approval_id` check their approval themselves.
    public static func reason(tool name: String, arguments: JSONValue) -> Reason? {
        if exempt.contains(name) || arguments["approval_id"] != nil { return nil }
        if name == "shell" { return reason(command: arguments["command"]?.stringValue ?? "") }
        let lower = name.lowercased()
        let words = Set(lower.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).map(String.init))
        if !words.isDisjoint(with: spendWords) { return .spends }
        if !words.isDisjoint(with: deleteWords) { return .deletes }
        // Email out of the mailbox; drafts, reading and searching aren't sending.
        if lower.contains("mail"), !words.isDisjoint(with: ["send", "reply", "forward"]) { return .publishes }
        if socialNetworks.contains(where: lower.contains), !words.isDisjoint(with: publishWords.union(["create"])) {
            return words.contains("draft") ? nil : .publishes
        }
        return nil
    }

    // MARK: Shell

    /// Why a shell command needs the owner's sign-off, or nil: judged by every command in it (`&&`, `;`, pipes, `$(…)`).
    /// Deleting inside a temporary folder isn't deleting anything of anyone's, including a folder a variable or `cd`
    /// points at (`DEST=/tmp/x; rm -rf "$DEST"`, `D=$(mktemp -d)`, `cd "$D" && git clean -fd`).
    public static func reason(command: String) -> Reason? {
        if let reason = reasonByPattern(command) { return reason }
        var shell = ShellState(command: command)
        for words in ShellWords.commands(command) {
            let stripped = shell.read(words)
            guard let reason = reason(words: stripped) else { continue }
            if reason == .deletes, let deleted = shell.deletions(stripped), deleted.allSatisfy(\.isTemporary) { continue }
            return reason
        }
        return nil
    }

    /// What a shell command deletes, by path, so that what the owner signed off on in a thread can be remembered. Nil
    /// when any of it isn't a path that can be worked out: a branch, a cloud resource, a record, or a path from a loop
    /// or a folder that isn't known.
    public static func deletions(command: String) -> [Deletion]? {
        guard reasonByPattern(command) == nil else { return nil }
        var shell = ShellState(command: command)
        var deleted: [Deletion] = []
        for words in ShellWords.commands(command) {
            let stripped = shell.read(words)
            guard let reason = reason(words: stripped) else { continue }
            guard reason == .deletes, let these = shell.deletions(stripped) else { return nil }
            deleted += these
        }
        return deleted
    }

    /// What the command line as a whole shows: money spent, posts or email sent, records deleted through an API or a
    /// database client.
    static func reasonByPattern(_ command: String) -> Reason? {
        let line = command.lowercased()
        // Money, and email or posts sent straight through an API.
        if line.range(of: #"\b(purchase|reservations? create|payment_intents|charges create|checkout[_ ]sessions?|subscriptions? create)\b"#, options: .regularExpression) != nil { return .spends }
        if line.range(of: #"(graph\.microsoft\.com\S*/(sendmail|reply|forward))|api\.linkedin\.com|oauth\.reddit\.com/api/(submit|comment)|api\.(twitter|x)\.com|graph\.facebook\.com"#, options: .regularExpression) != nil,
           line.range(of: #"(-x|--request)\s*(post|put)|--data|-d\s|--json|-f\s"#, options: .regularExpression) != nil { return .publishes }
        if line.range(of: #"(-x|--request)\s*['"]?delete\b|--method[= ]delete\b"#, options: .regularExpression) != nil { return .deletes }
        if line.range(of: #"\b(drop\s+(table|database|schema|collection|index)|truncate\s+table|delete\s+from|flushall|flushdb)\b"#, options: .regularExpression) != nil
            || line.range(of: #"\.(drop|dropdatabase|deletemany|deleteone|remove)\("#, options: .regularExpression) != nil { return .deletes }
        return nil
    }

    static func reason(words raw: [String]) -> Reason? {
        guard let first = raw.first else { return nil }
        var words = raw
        let program = (first as NSString).lastPathComponent
        if ["sudo", "env", "time", "nice", "command", "exec", "xargs", "caffeinate"].contains(program) {
            words.removeFirst()
            while let f = words.first, f.hasPrefix("-") || Int(f) != nil { words.removeFirst() }
            return reason(words: words)
        }
        var args = Array(words.dropFirst())
        // git's own options come before its command: `git -C repo clean -fd` cleans.
        if program == "git" {
            while let option = args.first, option.hasPrefix("-") {
                args.removeFirst()
                if ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(option), !args.isEmpty { args.removeFirst() }
            }
        }
        let sub = args.first { !$0.hasPrefix("-") } ?? ""
        func has(_ flags: String...) -> Bool { args.contains { a in flags.contains { a == $0 || a.hasPrefix($0 + "=") } } }
        let rest = Set(args.map { $0.lowercased() })
        switch program {
        case "rm", "rmdir", "unlink", "shred", "srm", "trash":
            return .deletes
        case "mail", "mailx", "sendmail", "mutt", "msmtp": return .publishes
        case "find":
            if has("-delete") { return .deletes }
            if let i = args.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
                return reason(words: Array(args[(i + 1)...].prefix { $0 != ";" && $0 != "+" && $0 != "\\;" }))
            }
        case "git":
            switch sub {
            case "branch", "tag": if has("-d", "-D", "--delete") { return .deletes }
            case "push":
                if has("--delete", "-d", "--force", "-f", "--force-with-lease", "--mirror", "--prune") || args.contains(where: { $0.hasPrefix(":") || $0.hasPrefix("+") }) { return .deletes }
            case "reset": if has("--hard", "--merge", "--keep") { return .deletes }
            case "clean", "filter-branch", "filter-repo", "prune": return .deletes
            case "checkout", "restore": if args.contains("--") || args.contains(".") || has("-f", "--force", "--worktree") { return .deletes }
            case "stash": if rest.contains("drop") || rest.contains("clear") { return .deletes }
            case "worktree": if rest.contains("remove") || rest.contains("prune") { return .deletes }
            case "reflog": if rest.contains("delete") || rest.contains("expire") { return .deletes }
            default: break
            }
        case "gh":
            if rest.contains("delete") || rest.contains("delete-asset") { return .deletes }
            if args.first == "api", let i = args.firstIndex(where: { $0 == "-X" || $0 == "--method" }), i + 1 < args.count, args[i + 1].uppercased() == "DELETE" { return .deletes }
            if args.first == "api", args.contains(where: { $0.uppercased() == "-XDELETE" || $0.uppercased() == "--METHOD=DELETE" }) { return .deletes }
        case "kubectl", "oc":
            if rest.contains("delete") { return .deletes }
        case "helm": if ["uninstall", "delete", "del", "un"].contains(sub) { return .deletes }
        case "docker", "podman":
            if ["rm", "rmi", "prune"].contains(sub) || rest.contains("prune") || (rest.contains("volume") && rest.contains("rm")) || (sub == "compose" && rest.contains("down") && has("-v", "--volumes")) { return .deletes }
        case "terraform", "tofu", "terragrunt":
            // apply can destroy what it manages; destroy and state rm do.
            if ["destroy", "apply"].contains(sub) || (sub == "state" && (rest.contains("rm") || rest.contains("replace-provider"))) { return .deletes }
        case "az":
            if rest.contains(where: { ["delete", "purge", "remove"].contains($0) }) { return .deletes }
            if rest.contains("purchase") || rest.contains("reservations") { return .spends }
        case "aws":
            if rest.contains(where: { $0 == "rm" || $0 == "rb" || $0.hasPrefix("delete") || $0.hasPrefix("terminate") }) { return .deletes }
            if rest.contains(where: { $0.hasPrefix("purchase") }) { return .spends }
        case "gcloud":
            if rest.contains("delete") { return .deletes }
        case "npm", "pnpm", "yarn":
            if sub == "unpublish" || sub == "deprecate" { return .deletes }
        case "cargo": if sub == "yank" { return .deletes }
        case "diskutil": if rest.contains(where: { $0.hasPrefix("erase") || $0 == "zerodisk" || $0 == "secureerase" }) { return .deletes }
        case "dd": if args.contains(where: { $0.hasPrefix("of=") }) { return .deletes }
        case "mkfs", "newfs_apfs", "newfs_hfs": return .deletes
        case "launchctl": if ["remove", "bootout", "unload"].contains(sub) { return .deletes }
        case "security": if sub.hasPrefix("delete") { return .deletes }
        case "rsync": if args.contains(where: { $0.hasPrefix("--delete") || $0 == "--remove-source-files" }) { return .deletes }
        case "stripe": if rest.contains("create") && rest.contains(where: { ["charges", "payment_intents", "subscriptions", "invoices"].contains($0) }) { return .spends }
        default: break
        }
        return nil
    }

    // MARK: What a command deletes

    /// The card's second button on a delete whose places are known: approve it, and later deletes in the same place
    /// in this thread (`Deletion.isCovered`) go ahead without asking.
    public static let allowHereLabel = "Allow deletes here for this thread"

    /// Something a command deletes: a file, a folder with everything in it, or the changes git throws away in a folder.
    public enum Deletion: Hashable, Sendable {
        case file(String)
        case tree(String)
        case discard(String)

        public var path: String {
            switch self {
            case .file(let p), .tree(let p), .discard(let p): return p
            }
        }

        /// Inside a temporary folder: nobody's work.
        public var isTemporary: Bool {
            let temp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
            return ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", temp + "/"].contains { path.hasPrefix($0) }
        }

        /// Signed off on already in this thread: another file in the same folder as a file the owner let go, or anything
        /// inside a folder (or a checkout) they let go.
        public func isCovered(by approved: [Deletion]) -> Bool {
            approved.contains { done in
                switch (self, done) {
                case (.file(let p), .file(let q)): return Self.folder(of: p) == Self.folder(of: q)
                case (_, .tree(let t)): return Self.path(path, isInside: t)
                case (.discard(let d), .discard(let e)): return Self.path(d, isInside: e)
                default: return false
                }
            }
        }

        static func folder(of path: String) -> String { (path as NSString).deletingLastPathComponent }
        static func path(_ path: String, isInside folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
    }
}

/// What a command line has set up by the time each of its commands runs: the variables it assigned, and the folder it
/// changed to. Enough to tell where a deletion lands; anything it can't work out stays unknown.
struct ShellState {
    private var values: [String: String] = [:]
    /// Where `cd` went; nil while it's the folder the command started in, which isn't known here.
    private var directory: String?

    init(command: String) {
        values["TMPDIR"] = NSTemporaryDirectory()
        values["HOME"] = NSHomeDirectory()
        // NAME=$(mktemp …): a new temporary file or folder.
        let pattern = #"([A-Za-z_][A-Za-z0-9_]*)=["']?\$\(\s*mktemp\b"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(command.startIndex..., in: command)
        for match in regex?.matches(in: command, range: range) ?? [] {
            if let name = Range(match.range(at: 1), in: command).map({ String(command[$0]) }) {
                values[name] = NSTemporaryDirectory() + "mktemp-" + name
            }
        }
    }

    /// Takes in a command's assignments and `cd`, and returns the command without its leading assignments.
    mutating func read(_ words: [String]) -> [String] {
        var rest = words
        while let first = rest.first, Self.isAssignment(first) {
            assign(first)
            rest.removeFirst()
        }
        let command = ShellWords.strippedLead(rest)
        guard let first = command.first else { return command }
        let arguments = command.dropFirst().filter { !$0.hasPrefix("-") }
        switch (first as NSString).lastPathComponent {
        case "export", "local", "declare", "readonly", "typeset":
            for word in arguments where Self.isAssignment(word) { assign(word) }
        case "unset":
            for name in arguments { values[name] = nil }
        case "cd", "pushd":
            directory = arguments.first.map { resolve($0) } ?? NSHomeDirectory()
        default:
            break
        }
        return command
    }

    /// What `command` (one that deletes) deletes, or nil if that can't be told.
    func deletions(_ command: [String]) -> [SignOff.Deletion]? {
        guard let first = command.first else { return nil }
        let arguments = Array(command.dropFirst())
        switch (first as NSString).lastPathComponent {
        case "rm", "rmdir", "unlink", "shred", "srm", "trash":
            let flags = arguments.filter { $0.hasPrefix("-") }
            let recursive = first.hasSuffix("rmdir") || flags.contains { $0 == "--recursive" || (!$0.hasPrefix("--") && $0.contains(where: { "rR".contains($0) })) }
            let targets = arguments.filter { !$0.hasPrefix("-") }
            guard !targets.isEmpty else { return nil }
            var deleted: [SignOff.Deletion] = []
            for target in targets {
                guard let path = resolve(target) else { return nil }
                deleted.append(recursive ? .tree(path) : .file(path))
            }
            return deleted
        case "git":
            var folder = directory
            var rest = arguments
            while rest.count > 1, rest[0] == "-C" {
                folder = resolve(rest[1])
                rest.removeFirst(2)
            }
            guard let folder, let sub = rest.first(where: { !$0.hasPrefix("-") }),
                  ["checkout", "restore", "reset", "clean", "stash"].contains(sub) else { return nil }
            return [.discard(folder)]
        case "find":
            guard let start = arguments.first(where: { !$0.hasPrefix("-") }), let path = resolve(start) else { return nil }
            return [.tree(path)]
        default:
            return nil
        }
    }

    /// A path as a full one: variables filled in, relative to where `cd` went. Nil when part of it isn't known.
    func resolve(_ path: String) -> String? {
        guard var text = expand(path) else { return nil }
        if text.hasPrefix("~") { text = NSHomeDirectory() + text.dropFirst() }
        if !text.hasPrefix("/") {
            guard let directory else { return nil }
            text = directory + "/" + text
        }
        return URL(fileURLWithPath: text).standardizedFileURL.path
    }

    private func expand(_ text: String) -> String? {
        var out = ""
        var chars = Substring(text)
        while let dollar = chars.firstIndex(of: "$") {
            out += chars[..<dollar]
            var rest = chars[chars.index(after: dollar)...]
            let name: Substring
            if rest.first == "{" {
                guard let close = rest.firstIndex(of: "}") else { return nil }
                name = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
            } else {
                name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                rest = rest[name.endIndex...]
            }
            guard !name.isEmpty, let value = values[String(name)] else { return nil }
            out += value
            chars = rest
        }
        return out + chars
    }

    private mutating func assign(_ word: String) {
        guard let equals = word.firstIndex(of: "=") else { return }
        let name = String(word[..<equals])
        let value = String(word[word.index(after: equals)...])
        // An empty value is a substitution ShellWords took out: only a mktemp one, found up front, is known.
        if value.isEmpty {
            if values[name]?.hasPrefix(NSTemporaryDirectory() + "mktemp-") != true { values[name] = nil }
            return
        }
        values[name] = expand(value)
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && word.first.map { $0.isLetter || $0 == "_" } == true
    }
}
