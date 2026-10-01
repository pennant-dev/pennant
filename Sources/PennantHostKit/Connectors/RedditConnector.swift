import PennantCore
import Foundation
import MCP

/// Reddit as the signed-in user through Reddit's own OAuth API (an "installed app" registered by the user):
/// read subreddits and threads, search, submit posts, comment, and check the inbox. Reddit requires API access to
/// be approved for new apps; until it is, sign-in succeeds but calls may be refused.
struct RedditConnector: NativeConnector {
    static let id = "reddit"
    let displayName = "Reddit"
    private static let base = "https://oauth.reddit.com"

    var tools: [MCP.Tool] {
        [
            .make("whoami", "The signed-in Reddit account: name, karma, age.", readOnly: true),
            .make("list_posts", "Posts in a subreddit.", properties: [
                "subreddit": Prop.str("Subreddit name without r/"),
                "sort": Prop.oneOf("Order (default hot)", ["hot", "new", "top", "rising"]),
                "time": Prop.oneOf("For top: the period", ["hour", "day", "week", "month", "year", "all"]),
                "limit": Prop.int("How many (default 15, max 50)"),
            ], required: ["subreddit"], readOnly: true),
            .make("search", "Search posts, across Reddit or inside one subreddit.", properties: [
                "query": Prop.str("Search words"),
                "subreddit": Prop.str("Limit to this subreddit (optional)"),
                "sort": Prop.oneOf("Order (default relevance)", ["relevance", "new", "top", "comments"]),
                "limit": Prop.int("How many (default 15, max 50)"),
            ], required: ["query"], readOnly: true),
            .make("read_post", "A post with its top comments.", properties: [
                "post": Prop.str("Post id (e.g. 1abcde), fullname (t3_1abcde) or permalink URL"),
                "comments": Prop.int("How many top-level comments (default 20)"),
            ], required: ["post"], readOnly: true),
            .make("submit_post", "Submit a text or link post to a subreddit as the user. Check the subreddit's rules first.", properties: [
                "subreddit": Prop.str("Subreddit name without r/"),
                "title": Prop.str("Title"),
                "text": Prop.str("Body for a text post (Markdown)"),
                "url": Prop.str("Link for a link post (instead of text)"),
                "flair_id": Prop.str("Post flair id, when the subreddit requires one"),
            ], required: ["subreddit", "title"], readOnly: false, destructive: true),
            .make("comment", "Reply to a post or a comment as the user.", properties: [
                "parent": Prop.str("Fullname of the post (t3_…) or comment (t1_…) to reply to"),
                "text": Prop.str("Reply text (Markdown)"),
            ], required: ["parent", "text"], readOnly: false, destructive: true),
            .make("inbox", "Replies, mentions and messages to the user.", properties: [
                "unread_only": Prop.bool("Only unread items (default true)"),
                "limit": Prop.int("How many (default 20)"),
            ], readOnly: true),
        ]
    }

    /// Reddit throttles generic user agents; it asks for `<platform>:<app id>:<version> (by /u/<username>)`.
    static func userAgent(username: String?) -> String {
        "macos:dev.pennant.mac:v\(PennantVersion.string) (by /u/\(username ?? "pennant-user"))"
    }

    func call(_ tool: String, arguments a: [String: Value], api base: ConnectorAPI) async throws -> String {
        var api = base
        api.userAgent = Self.userAgent(username: base.settings["username"])
        switch tool {
        case "whoami":
            let me = try await get(api, "/api/v1/me")
            let created = (me["created_utc"] as? Double).map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "?"
            return "u/\(me["name"] as? String ?? "?") · \(me["link_karma"] as? Int ?? 0) post karma, \(me["comment_karma"] as? Int ?? 0) comment karma · since \(created)"

        case "list_posts":
            let sub = Self.subreddit(try a.require("subreddit"))
            let sort = a.string("sort") ?? "hot"
            var path = "/r/\(sub)/\(sort)?limit=\(min(max(a.int("limit") ?? 15, 1), 50))&raw_json=1"
            if sort == "top" { path += "&t=\(a.string("time") ?? "week")" }
            return render(listing: try await get(api, path))

        case "search":
            let q = ConnectorText.encodeQuery(try a.require("query"))
            let limit = min(max(a.int("limit") ?? 15, 1), 50)
            let sort = a.string("sort") ?? "relevance"
            let path: String
            if let sub = a.string("subreddit") {
                path = "/r/\(Self.subreddit(sub))/search?q=\(q)&restrict_sr=1&sort=\(sort)&limit=\(limit)&raw_json=1"
            } else {
                path = "/search?q=\(q)&sort=\(sort)&limit=\(limit)&raw_json=1"
            }
            return render(listing: try await get(api, path))

        case "read_post":
            let id = Self.postID(try a.require("post"))
            let n = min(max(a.int("comments") ?? 20, 1), 100)
            let (data, _) = try await api.send("GET", url("/comments/\(id)?limit=\(n)&depth=2&sort=top&raw_json=1"))
            guard let parts = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], parts.count >= 2 else {
                throw ConnectorAPI.Failure(status: 0, message: "Reddit returned no thread for \(id).")
            }
            let post = ((((parts[0]["data"] as? [String: Any])?["children"] as? [[String: Any]])?.first)?["data"] as? [String: Any]) ?? [:]
            var out = "\(post["title"] as? String ?? "") — r/\(post["subreddit"] as? String ?? "") by u/\(post["author"] as? String ?? "") · \(post["score"] as? Int ?? 0) points · \(post["num_comments"] as? Int ?? 0) comments\nfullname: \(post["name"] as? String ?? "")\n"
            if let body = post["selftext"] as? String, !body.isEmpty { out += "\n\(body)\n" }
            if let link = post["url"] as? String, post["is_self"] as? Bool == false { out += "\nLink: \(link)\n" }
            out += "\nComments:\n"
            let comments = ((parts[1]["data"] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
            for c in comments {
                guard c["kind"] as? String == "t1", let d = c["data"] as? [String: Any] else { continue }
                out += "• u/\(d["author"] as? String ?? "") (\(d["score"] as? Int ?? 0)): \(d["body"] as? String ?? "")\n  fullname: \(d["name"] as? String ?? "")\n"
            }
            return ConnectorText.clip(out, 16_000)

        case "submit_post":
            var form = [
                "sr": Self.subreddit(try a.require("subreddit")),
                "title": try a.require("title"),
                "api_type": "json",
                "resubmit": "true",
            ]
            if let link = a.string("url") {
                form["kind"] = "link"
                form["url"] = link
            } else {
                form["kind"] = "self"
                form["text"] = a.string("text") ?? ""
            }
            if let flair = a.string("flair_id") { form["flair_id"] = flair }
            let reply = try await api.json("POST", url("/api/submit"), form: form)
            let json = reply["json"] as? [String: Any] ?? [:]
            if let errors = json["errors"] as? [[Any]], !errors.isEmpty {
                throw ConnectorAPI.Failure(status: 0, message: "Reddit refused the post: " + errors.map { $0.map { "\($0)" }.joined(separator: " ") }.joined(separator: "; "))
            }
            let d = json["data"] as? [String: Any] ?? [:]
            return "Submitted. \(d["url"] as? String ?? "") (fullname \(d["name"] as? String ?? "?"))"

        case "comment":
            let reply = try await api.json("POST", url("/api/comment"), form: ["thing_id": try a.require("parent"), "text": try a.require("text"), "api_type": "json"])
            let json = reply["json"] as? [String: Any] ?? [:]
            if let errors = json["errors"] as? [[Any]], !errors.isEmpty {
                throw ConnectorAPI.Failure(status: 0, message: "Reddit refused the comment: " + errors.map { $0.map { "\($0)" }.joined(separator: " ") }.joined(separator: "; "))
            }
            let thing = ((json["data"] as? [String: Any])?["things"] as? [[String: Any]])?.first?["data"] as? [String: Any]
            return "Commented (fullname \(thing?["name"] as? String ?? "?"))."

        case "inbox":
            let which = a.bool("unread_only") == false ? "inbox" : "unread"
            let listing = try await get(api, "/message/\(which)?limit=\(min(max(a.int("limit") ?? 20, 1), 100))&raw_json=1")
            let children = ((listing["data"] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
            if children.isEmpty { return which == "unread" ? "No unread replies or messages." : "The inbox is empty." }
            return ConnectorText.clip(children.compactMap { c -> String? in
                guard let d = c["data"] as? [String: Any] else { return nil }
                let context = (d["context"] as? String).flatMap { $0.isEmpty ? nil : "https://www.reddit.com\($0)" } ?? ""
                return "• \(d["subject"] as? String ?? "") from u/\(d["author"] as? String ?? "?")\((d["subreddit"] as? String).map { " in r/\($0)" } ?? "")\n  \(d["body"] as? String ?? "")\n  fullname: \(d["name"] as? String ?? "") \(context)"
            }.joined(separator: "\n"))

        default:
            throw ConnectorAPI.Failure(status: 0, message: "Unknown tool \(tool).")
        }
    }

    // MARK: Helpers

    private func url(_ path: String) -> URL { URL(string: Self.base + path)! }

    private func get(_ api: ConnectorAPI, _ path: String) async throws -> [String: Any] {
        try await api.json("GET", url(path))
    }

    static func subreddit(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://www.reddit.com/r/", "/r/", "r/"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return s.split(separator: "/").first.map(String.init) ?? s
    }

    /// Accepts "1abcde", "t3_1abcde" or a permalink.
    static func postID(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let range = s.range(of: "/comments/") {
            return String(s[range.upperBound...].split(separator: "/").first ?? "")
        }
        return s.hasPrefix("t3_") ? String(s.dropFirst(3)) : s
    }

    private func render(listing: [String: Any]) -> String {
        let children = ((listing["data"] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
        if children.isEmpty { return "No posts." }
        return ConnectorText.clip(children.compactMap { c -> String? in
            guard let d = c["data"] as? [String: Any] else { return nil }
            let body = (d["selftext"] as? String).map { String($0.prefix(200)).replacingOccurrences(of: "\n", with: " ") } ?? ""
            return "• \(d["title"] as? String ?? "") — r/\(d["subreddit"] as? String ?? "") by u/\(d["author"] as? String ?? "") · \(d["score"] as? Int ?? 0) points · \(d["num_comments"] as? Int ?? 0) comments\n  \(body.isEmpty ? (d["url"] as? String ?? "") : body)\n  fullname: \(d["name"] as? String ?? "") https://www.reddit.com\(d["permalink"] as? String ?? "")"
        }.joined(separator: "\n"))
    }
}
