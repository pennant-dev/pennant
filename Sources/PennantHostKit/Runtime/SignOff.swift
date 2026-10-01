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
    public static func reason(command: String) -> Reason? {
        let line = command.lowercased()
        // Money, and email or posts sent straight through an API.
        if line.range(of: #"\b(purchase|reservations? create|payment_intents|charges create|checkout[_ ]sessions?|subscriptions? create)\b"#, options: .regularExpression) != nil { return .spends }
        if line.range(of: #"(graph\.microsoft\.com\S*/(sendmail|reply|forward))|api\.linkedin\.com|oauth\.reddit\.com/api/(submit|comment)|api\.(twitter|x)\.com|graph\.facebook\.com"#, options: .regularExpression) != nil,
           line.range(of: #"(-x|--request)\s*(post|put)|--data|-d\s|--json|-f\s"#, options: .regularExpression) != nil { return .publishes }
        if line.range(of: #"(-x|--request)\s*['"]?delete\b|--method[= ]delete\b"#, options: .regularExpression) != nil { return .deletes }
        if line.range(of: #"\b(drop\s+(table|database|schema|collection|index)|truncate\s+table|delete\s+from|flushall|flushdb)\b"#, options: .regularExpression) != nil
            || line.range(of: #"\.(drop|dropdatabase|deletemany|deleteone|remove)\("#, options: .regularExpression) != nil { return .deletes }
        for words in ShellWords.commands(command) {
            if let r = reason(words: ShellWords.strippedLead(words)) { return r }
        }
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
        let args = Array(words.dropFirst())
        let sub = args.first { !$0.hasPrefix("-") } ?? ""
        func has(_ flags: String...) -> Bool { args.contains { a in flags.contains { a == $0 || a.hasPrefix($0 + "=") } } }
        let rest = Set(args.map { $0.lowercased() })
        switch program {
        case "rm", "rmdir", "unlink", "shred", "srm", "trash":
            // Tidying scratch files in the temporary folder isn't deleting anything of anyone's.
            let targets = args.filter { !$0.hasPrefix("-") }
            let temp = NSTemporaryDirectory()
            if !targets.isEmpty, targets.allSatisfy({ t in ["/tmp/", "/private/tmp/", temp, "$TMPDIR/", "${TMPDIR}/"].contains { t.hasPrefix($0) } && !t.contains("..") }) { return nil }
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
}
