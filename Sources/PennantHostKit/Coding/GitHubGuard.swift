import Foundation

/// Coding runs on GitHub: they act as their own GitHub App or not at all, never as the owner, and never give a person's
/// sign-off (approving a pull request, resolving a review thread) with the owner's account.
enum GitHubGuard {
    /// A command that approves a pull request (a GitHub review, `gh pr review --approve`, or the API's APPROVE event) or
    /// resolves someone's review thread with the owner's account: a person's sign-off, which an agent never gives as
    /// them. Through `ghapp.sh` (a GitHub App's own token) it's the App's approval, under its own name: allowed.
    static func signsOff(_ command: String) -> Bool {
        if command.contains("ghapp.sh") { return false }
        let line = command.lowercased()
        for words in ShellWords.commands(command) {
            guard let first = words.first, (first as NSString).lastPathComponent == "gh" else { continue }
            let args = Array(words.dropFirst())
            if args.first == "pr", args.dropFirst().first == "review",
               args.contains(where: { $0 == "--approve" || $0 == "-a" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("a")) }) { return true }
        }
        if line.contains("/reviews"), line.contains("approve") { return true }
        if line.contains("addpullrequestreview") && line.contains("approve") { return true }
        if line.contains("submitpullrequestreview") && line.contains("approve") { return true }
        if line.contains("resolvereviewthread") { return true }
        if line.contains("pending_deployments") && line.contains("approved") { return true }
        return false
    }

    /// Why a coding run's command is refused on identity grounds, or nil. `identity` is the GitHub bot the session
    /// acts as (nil: it has none).
    /// - Always: signing in as someone, or changing who commits or which token is used. The session's identity is set
    ///   by Pennant, not by the agent.
    /// - Without an identity: anything that writes to GitHub (push, open or change a PR or issue, release, API
    ///   writes), since it would go out under the owner's login.
    static func refusal(_ command: String, identity: String?) -> String? {
        let line = command.lowercased()
        let tampers = ["gh_token=", "github_token=", "unset gh_token", "unset github_token", "git_author_", "git_committer_", "git_config_"]
        var changesIdentity = tampers.contains { line.contains($0) }
        var writes = false
        // Redirections (`2>&1`, `> out`, `< in`) aren't arguments: the splitter keeps their parts as words.
        let unredirected = command.replacingOccurrences(of: #"(\d?>{1,2}|&>)\s*(&\d|[^\s;&|)]+)|<\s*[^\s;&|)]+"#, with: " ", options: .regularExpression)
        for words in ShellWords.commands(unredirected) {
            let w = ShellWords.strippedLead(words)
            guard let first = w.first else { continue }
            let program = (first as NSString).lastPathComponent
            let args = Array(w.dropFirst())
            let sub = args.first ?? "", action = args.dropFirst().first ?? ""
            if program == "gh" {
                if sub == "auth", ["login", "logout", "switch", "setup-git", "refresh"].contains(action) { changesIdentity = true }
                if ["pr", "issue"].contains(sub), ["create", "merge", "close", "reopen", "comment", "edit", "review", "ready", "lock"].contains(action) { writes = true }
                if sub == "release" || sub == "repo" && ["create", "edit", "fork", "rename"].contains(action) { writes = true }
                if sub == "api", args.contains(where: { ["-X", "--method", "-f", "-F", "--field", "--raw-field", "--input"].contains($0) || $0.hasPrefix("-X") || $0.hasPrefix("--method=") }) {
                    let method = args.firstIndex(where: { $0 == "-X" || $0 == "--method" }).flatMap { $0 + 1 < args.count ? args[$0 + 1].uppercased() : nil }
                    if method != "GET" { writes = true }
                }
            }
            if program == "git" {
                if sub == "push" { writes = true }
                func touchesIdentity(_ key: String) -> Bool { ["user.", "credential", "url."].contains { key.lowercased().hasPrefix($0) } }
                // `git -c key=value …` for one command.
                for (i, a) in args.enumerated() where a == "-c" && i + 1 < args.count && touchesIdentity(args[i + 1]) { changesIdentity = true }
                // `git config key value` (or --unset/--add/--replace-all key) sets it; `git config key` only reads it.
                if sub == "config" {
                    let rest = args.dropFirst()
                    let plain = rest.filter { !$0.hasPrefix("-") }
                    let edits = rest.contains { ["--unset", "--unset-all", "--add", "--replace-all", "--remove-section", "--rename-section"].contains($0) }
                    if let key = plain.first, touchesIdentity(key), plain.count >= 2 || edits { changesIdentity = true }
                }
            }
        }
        if changesIdentity {
            return "Refused: on GitHub you act as \(identity ?? "your own identity"), set up by Pennant. Don't sign in as anyone else or change who commits or which token is used."
        }
        if writes, identity == nil {
            return "Refused: you have no GitHub identity of your own yet, and pushing or opening a pull request here would go out under the owner's login. Leave the work committed on a local branch and say it's ready to push; the owner can give coding runs an identity with `pennant coding github …`."
        }
        return nil
    }
}
