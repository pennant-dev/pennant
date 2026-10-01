import PennantCore
import Foundation

/// Pull request reviews where the reviewers already are: a batch of PRs goes to a chat (iMessage, Teams) and to the
/// owner's Pennant app, and "approve all" or "approve 1 3" there approves them on GitHub **as the person who said
/// it**, with their own GitHub sign-in (linked once, with GitHub's device code). An approval covers the commit that
/// was listed: a PR that changed since, or the person's own PR, is skipped. Every approval is logged (who, where, which
/// commit, when), and the agent that asked hears as approvals land, to merge what's ready.
public actor ReviewService {
    public struct Reviewer: Codable, Sendable, Hashable {
        public var id: String = UUID().uuidString
        public var name: String
        public var login: String
        /// Who they are in chats: `contact:<id>` (their own thread), `imessage:<handle>`, `teams:<Entra id>`, or a
        /// Pennant person's id (the owner).
        public var keys: Set<String>
        public var linkedAt = Date()
    }

    public struct PullRequest: Codable, Sendable, Hashable {
        public var repo: String
        public var number: Int
        public var title: String
        public var author: String
        public var head: String
        public var url: String
        public var label: String { "\(repo.split(separator: "/").last.map(String.init) ?? repo) #\(number)" }
    }

    public struct Approval: Codable, Sendable, Hashable {
        public var pr: Int
        public var reviewer: String
        public var login: String
        public var commit: String
        public var via: String
        public var at = Date()
    }

    public struct Batch: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var prs: [PullRequest]
        /// The chat it was posted to (a channel contact), if any.
        public var placeID: String?
        public var agentID: AgentID
        public var conversationID: ConversationID
        public var merge: Bool
        public var approvals: [Approval] = []
        public var createdAt = Date()
        public var closedAt: Date?

        /// Approved by someone other than its author.
        public func isApproved(_ index: Int) -> Bool {
            approvals.contains { $0.pr == index && $0.login.lowercased() != prs[index].author.lowercased() }
        }
        public var waiting: [Int] { prs.indices.filter { !isApproved($0) } }
    }

    struct State: Codable {
        var clientID: String?
        var reviewers: [Reviewer] = []
        var batches: [Batch] = []
    }

    /// The seam for GitHub: a request in, the body and status out. Tests answer it themselves.
    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, Int)

    public struct Dependencies: Sendable {
        /// Posts to a chat (a channel contact), from Pennant.
        public var post: @Sendable (_ contactID: String, _ text: String, _ buttons: [String]) async throws -> Void
        /// Tells the agent that asked for a batch how it's going, in its conversation.
        public var notify: @Sendable (_ agentID: AgentID, _ conversationID: ConversationID, _ text: String) async -> Void
        public init(post: @escaping @Sendable (String, String, [String]) async throws -> Void,
                    notify: @escaping @Sendable (AgentID, ConversationID, String) async -> Void) {
            self.post = post; self.notify = notify
        }
    }

    private let fileURL: URL
    private let auditURL: URL
    private let keychain: KeychainStore
    private let http: HTTP
    private var state: State
    private var deps: Dependencies?

    public init(paths: HostPaths, keychain: KeychainStore, http: HTTP? = nil) {
        fileURL = paths.root.appendingPathComponent("reviews.json")
        auditURL = paths.root.appendingPathComponent("review-audit.jsonl")
        self.keychain = keychain
        self.http = http ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        state = (try? Data(contentsOf: fileURL)).flatMap { try? JSONCodec.decode(State.self, from: $0) } ?? State()
    }

    public func start(_ deps: Dependencies) { self.deps = deps }

    /// A word to an agent's conversation (a link finished, say).
    public func announce(_ agentID: AgentID, _ conversationID: ConversationID, _ text: String) async {
        await deps?.notify(agentID, conversationID, text)
    }

    private func save() throws { try JSONCodec.encode(state).write(to: fileURL, options: [.atomic]) }

    // MARK: Setup

    /// The GitHub app (or OAuth app) whose device code people sign in with. Its client secret, when given, lets
    /// expiring sign-ins renew themselves; without it, someone whose sign-in expired is asked to link again.
    public func configure(clientID: String, secret: String?) throws {
        state.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let secret, !secret.isEmpty { try keychain.set(account: "client-secret", value: secret) }
        try save()
    }

    public var reviewers: [Reviewer] { state.reviewers }
    public var openBatches: [Batch] { state.batches.filter { $0.closedAt == nil } }

    /// Whether a chat has a batch waiting on answers there (so a bare "approve all" is for Pennant).
    public func hasOpenBatch(in contactID: String) -> Bool { openBatches.contains { $0.placeID == contactID } }

    struct Token: Codable { var access: String; var refresh: String?; var expiresAt: Date? }

    /// Starts linking someone's GitHub: the code and address to give them, and a task that finishes the link once
    /// they've entered it (or gives up when the code expires).
    public func startLink(name: String, keys: Set<String>) async throws -> (code: String, url: String, finished: Task<Reviewer, Error>) {
        guard let clientID = state.clientID, !clientID.isEmpty else {
            throw ToolError.failed("GitHub reviews aren't set up yet: the owner runs `pennant github client-id <id>` with the GitHub app's client id (device flow on).")
        }
        let start = try await form("https://github.com/login/device/code", ["client_id": clientID, "scope": "repo"])
        guard let device = start["device_code"] as? String, let code = start["user_code"] as? String, let url = start["verification_uri"] as? String else {
            throw ToolError.failed((start["error_description"] as? String) ?? "GitHub didn't start the sign-in. Is device flow enabled on the GitHub app?")
        }
        let interval = (start["interval"] as? Double) ?? 5
        let until = Date().addingTimeInterval((start["expires_in"] as? Double) ?? 900)
        let finished = Task { () throws -> Reviewer in
            var wait = max(interval, 5)
            while true {
                guard Date() < until else { throw ToolError.failed("The GitHub code expired before \(name) entered it.") }
                try await Task.sleep(for: .seconds(wait))
                let json = try await self.form("https://github.com/login/oauth/access_token", [
                    "client_id": clientID, "device_code": device, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
                if let access = json["access_token"] as? String {
                    return try await self.finishLink(name: name, keys: keys, token: Token(access: access, refresh: json["refresh_token"] as? String,
                                                                                         expiresAt: (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }))
                }
                switch json["error"] as? String {
                case "authorization_pending": continue
                case "slow_down": wait += 5
                case "access_denied": throw ToolError.failed("\(name) declined the GitHub sign-in.")
                default: throw ToolError.failed((json["error_description"] as? String) ?? "GitHub sign-in failed.")
                }
            }
        }
        return (code, url, finished)
    }

    func finishLink(name: String, keys: Set<String>, token: Token) async throws -> Reviewer {
        let user = try await api("GET", "/user", token: token.access)
        guard let login = user["login"] as? String else { throw ToolError.failed("GitHub didn't say who signed in.") }
        // One reviewer per GitHub account: linking again (another chat, a new sign-in) adds to it.
        var reviewer = state.reviewers.first { $0.login.lowercased() == login.lowercased() } ?? Reviewer(name: name, login: login, keys: [])
        reviewer.keys.formUnion(keys)
        reviewer.linkedAt = Date()
        state.reviewers.removeAll { $0.id == reviewer.id }
        state.reviewers.append(reviewer)
        try keychain.set(account: "reviewer.\(reviewer.id)", value: String(decoding: try JSONEncoder().encode(token), as: UTF8.self))
        try save()
        return reviewer
    }

    /// The reviewer someone in a chat is, from who said it.
    public func reviewer(forKeys keys: [String]) -> Reviewer? {
        state.reviewers.first { !$0.keys.isDisjoint(with: keys) }
    }

    // MARK: Batches

    /// Looks the PRs up on GitHub (with a linked reviewer's sign-in) and opens a batch: posted to the chat, if any.
    public func open(title: String, prs refs: [(repo: String, number: Int)], placeID: String?,
                     agentID: AgentID, conversationID: ConversationID, merge: Bool) async throws -> Batch {
        guard let reader = state.reviewers.first else {
            throw ToolError.failed("Nobody has linked GitHub for reviews yet: use link_reviewer for each person first.")
        }
        let token = try await accessToken(reader)
        var prs: [PullRequest] = []
        for ref in refs {
            let pr = try await api("GET", "/repos/\(ref.repo)/pulls/\(ref.number)", token: token)
            guard (pr["state"] as? String) == "open" else { throw ToolError.failed("\(ref.repo) #\(ref.number) isn't open.") }
            prs.append(PullRequest(repo: ref.repo, number: ref.number, title: pr["title"] as? String ?? "",
                                   author: (pr["user"] as? [String: Any])?["login"] as? String ?? "",
                                   head: (pr["head"] as? [String: Any])?["sha"] as? String ?? "", url: pr["html_url"] as? String ?? ""))
        }
        let batch = Batch(id: String(UUID().uuidString.prefix(4)).uppercased(), title: title, prs: prs, placeID: placeID,
                          agentID: agentID, conversationID: conversationID, merge: merge)
        state.batches.append(batch)
        try save()
        if let placeID { try await deps?.post(placeID, Self.announcement(batch), ["Approve all"]) }
        return batch
    }

    static func announcement(_ b: Batch) -> String {
        var lines = ["Reviews needed: \(b.title)"]
        for (i, pr) in b.prs.enumerated() { lines.append("\(i + 1). \(pr.label) \(pr.title) (\(pr.author)) \(pr.url)") }
        lines.append("")
        lines.append("Reply “approve all”, or “approve 1 3” for some: Pennant approves them on GitHub as you, on the commits listed. Your own PRs are skipped.")
        return lines.joined(separator: "\n")
    }

    /// What someone said, as an approval: all of them, or which (by their place in the list, or a PR number). Nil when
    /// it isn't an approval.
    static func intent(_ text: String) -> [Int]?? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"^pennant[\s,:;!.\-–—]*"#, with: "", options: .regularExpression)
        guard let match = t.range(of: #"^(approve|approved|lgtm)\b"#, options: .regularExpression) else { return nil }
        let rest = t[match.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if rest.isEmpty || rest.hasPrefix("all") || rest == "them" || rest == "everything" { return .some(nil) }
        let numbers = rest.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        return numbers.isEmpty ? nil : .some(numbers)
    }

    /// Someone in a chat said something: when it's an approval from a linked reviewer for a batch open there (or,
    /// in their own thread, their newest open batch), approve on GitHub and say what happened. Nil: not for this.
    public func heard(_ text: String, in contactID: String, isGroup: Bool, keys: [String], via: String) async -> String? {
        guard let which = Self.intent(text) else { return nil }
        // In a group, only its own batch; in someone's own thread, their newest one anywhere.
        guard let batch = openBatches.last(where: { $0.placeID == contactID }) ?? (isGroup ? nil : openBatches.last) else { return nil }
        guard let reviewer = reviewer(forKeys: keys) else {
            return "To approve from here, link your GitHub first: ask Pennant to link you for reviews."
        }
        return await approve(batchID: batch.id, reviewer: reviewer, which: which, via: via)
    }

    /// Approves a batch's PRs (all, or those listed) as this reviewer, and says how it went.
    public func approve(batchID: String, reviewer: Reviewer, which: [Int]?, via: String) async -> String {
        guard var batch = state.batches.first(where: { $0.id == batchID }) else { return "That review batch is gone." }
        let indices: [Int] = which.map { list in list.compactMap { n in
            if (1...batch.prs.count).contains(n) { return n - 1 }
            return batch.prs.firstIndex { $0.number == n }
        } } ?? Array(batch.prs.indices)
        let token: String
        do { token = try await accessToken(reviewer) } catch { return "\(reviewer.name): \(error)" }

        var done: [String] = [], skipped: [String] = []
        for i in Set(indices).sorted() {
            let pr = batch.prs[i]
            if pr.author.lowercased() == reviewer.login.lowercased() { skipped.append("\(pr.label) (your own)"); continue }
            if batch.approvals.contains(where: { $0.pr == i && $0.reviewer == reviewer.id }) { skipped.append("\(pr.label) (already approved)"); continue }
            do {
                let now = try await api("GET", "/repos/\(pr.repo)/pulls/\(pr.number)", token: token)
                guard (now["state"] as? String) == "open" else { skipped.append("\(pr.label) (no longer open)"); continue }
                guard ((now["head"] as? [String: Any])?["sha"] as? String) == pr.head else { skipped.append("\(pr.label) (changed since it was listed)"); continue }
                let body = "Approved via Pennant (batch \(batch.id), from \(via))."
                _ = try await api("POST", "/repos/\(pr.repo)/pulls/\(pr.number)/reviews", token: token,
                                  body: ["event": "APPROVE", "commit_id": pr.head, "body": body])
                let approval = Approval(pr: i, reviewer: reviewer.id, login: reviewer.login, commit: pr.head, via: via)
                batch.approvals.append(approval)
                audit(batch, pr, approval)
                done.append(pr.label)
            } catch {
                skipped.append("\(pr.label) (\(error))")
            }
        }
        let waiting = batch.waiting
        if waiting.isEmpty { batch.closedAt = Date() }
        if let i = state.batches.firstIndex(where: { $0.id == batch.id }) { state.batches[i] = batch }
        try? save()

        var reply = done.isEmpty ? "\(reviewer.name) approved nothing new." : "\(reviewer.name) approved on GitHub: \(done.joined(separator: ", "))."
        if !skipped.isEmpty { reply += " Skipped: \(skipped.joined(separator: ", "))." }
        reply += waiting.isEmpty ? " Every PR in the batch is approved." : " Still needs a reviewer: \(waiting.map { batch.prs[$0].label }.joined(separator: ", "))."
        if !done.isEmpty {
            let ready = batch.prs.indices.filter(batch.isApproved).map { batch.prs[$0].label }
            await deps?.notify(batch.agentID, batch.conversationID, """
                Review batch \(batch.id) (\(batch.title)): \(reviewer.name) (\(reviewer.login)) approved \(done.joined(separator: ", ")) from \(via).
                Approved so far: \(ready.joined(separator: ", ")). \(waiting.isEmpty ? "All approved." : "Still waiting: \(waiting.map { batch.prs[$0].label }.joined(separator: ", ")).")
                \(batch.merge ? "Merge what's ready, in the release's order (hold a PR whose earlier ones aren't merged yet), then report." : "Merging wasn't asked for.")
                """)
        }
        return reply
    }

    private func audit(_ batch: Batch, _ pr: PullRequest, _ a: Approval) {
        let line: [String: String] = ["at": ISO8601DateFormatter().string(from: a.at), "batch": batch.id, "repo": pr.repo, "pr": String(pr.number),
                                      "commit": a.commit, "reviewer": a.login, "via": a.via]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        if let handle = try? FileHandle(forWritingTo: auditURL) {
            handle.seekToEndOfFile(); handle.write(data + Data("\n".utf8)); try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: auditURL)
        }
    }

    public func status() -> String {
        guard !openBatches.isEmpty else { return "No review batches waiting." }
        return openBatches.map { b in
            let lines = b.prs.indices.map { i in
                let who = b.approvals.filter { $0.pr == i }.map(\.login)
                return "  \(i + 1). \(b.prs[i].label) \(b.prs[i].title): \(b.isApproved(i) ? "approved by \(who.joined(separator: ", "))" : "waiting")"
            }
            return "Batch \(b.id): \(b.title)\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: GitHub

    private func accessToken(_ reviewer: Reviewer) async throws -> String {
        guard let raw = keychain.get(account: "reviewer.\(reviewer.id)"), var token = try? JSONDecoder().decode(Token.self, from: Data(raw.utf8)) else {
            throw ToolError.failed("\(reviewer.name)'s GitHub link is missing: link them again.")
        }
        if let expires = token.expiresAt, expires < Date().addingTimeInterval(60) {
            guard let refresh = token.refresh, let clientID = state.clientID, let secret = keychain.get(account: "client-secret") else {
                throw ToolError.failed("\(reviewer.name)'s GitHub sign-in expired: link them again.")
            }
            let json = try await form("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "client_secret": secret, "grant_type": "refresh_token", "refresh_token": refresh])
            guard let access = json["access_token"] as? String else { throw ToolError.failed("\(reviewer.name)'s GitHub sign-in expired: link them again.") }
            token = Token(access: access, refresh: json["refresh_token"] as? String ?? refresh, expiresAt: (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) })
            try keychain.set(account: "reviewer.\(reviewer.id)", value: String(decoding: try JSONEncoder().encode(token), as: UTF8.self))
        }
        return token.access
    }

    private func form(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await http(request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func api(_ method: String, _ path: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, status) = try await http(request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            throw ToolError.failed("GitHub said \(status)\((json["message"] as? String).map { ": \($0)" } ?? "")")
        }
        return json
    }
}
