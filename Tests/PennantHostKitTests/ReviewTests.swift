@testable import PennantHostKit
import PennantCore
import XCTest

final class ReviewTests: XCTestCase {
    /// GitHub, as far as reviews go: three PRs (Maya's #65 and #122, Jonas's #38), who each token is, and the
    /// reviews posted, with the token that posted them.
    final class FakeGitHub: @unchecked Sendable {
        let lock = NSLock()
        var heads = ["harbor-labs/harbor-api#65": "aaa", "harbor-labs/harbor-web#122": "bbb", "harbor-labs/harbor-agent#38": "ccc"]
        let authors = ["harbor-labs/harbor-api#65": "maya-okafor", "harbor-labs/harbor-web#122": "maya-okafor", "harbor-labs/harbor-agent#38": "jonas-lindqvist"]
        let users = ["token-jonas": "jonas-lindqvist", "token-maya": "maya-okafor"]
        var reviews: [(pr: String, login: String, commit: String, body: String)] = []

        func answer(_ r: URLRequest) -> (Data, Int) {
            lock.lock(); defer { lock.unlock() }
            let token = (r.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
            let path = r.url!.path
            func json(_ o: Any, _ status: Int = 200) -> (Data, Int) { ((try? JSONSerialization.data(withJSONObject: o)) ?? Data(), status) }
            guard let login = users[token] else { return json(["message": "Bad credentials"], 401) }
            if path == "/user" { return json(["login": login]) }
            let parts = path.split(separator: "/")   // repos, owner, repo, pulls, n[, reviews]
            guard parts.count >= 5, parts[0] == "repos", parts[3] == "pulls" else { return json(["message": "Not Found"], 404) }
            let key = "\(parts[1])/\(parts[2])#\(parts[4])"
            guard let head = heads[key] else { return json(["message": "Not Found"], 404) }
            if parts.count == 6, r.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]) ?? [:]
                if authors[key] == login { return json(["message": "Can not approve your own pull request"], 422) }
                reviews.append((key, login, body["commit_id"] as? String ?? "", body["body"] as? String ?? ""))
                return json(["id": 1, "state": "APPROVED"])
            }
            return json(["state": "open", "title": "PR \(parts[4])", "user": ["login": authors[key]!], "head": ["sha": head],
                         "html_url": "https://github.com/\(parts[1])/\(parts[2])/pull/\(parts[4])"])
        }
    }

    final class Box: @unchecked Sendable { var posts: [(String, String, [String])] = []; var notes: [String] = [] }

    private func service(_ github: FakeGitHub, box: Box) async throws -> (ReviewService, HostPaths) {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        let keychain = KeychainStore(service: "test.reviews", fallbackFileURL: paths.root.appendingPathComponent("kc.json"), preferFile: true)
        let reviews = ReviewService(paths: paths, keychain: keychain, http: { github.answer($0) })
        await reviews.start(.init(post: { id, text, buttons in box.posts.append((id, text, buttons)) }, notify: { _, _, text in box.notes.append(text) }))
        try await reviews.configure(clientID: "Iv1.test", secret: nil)
        return (reviews, paths)
    }

    func testApprovalsInAChatArePostedOnGitHubAsWhoeverSaidThem() async throws {
        let github = FakeGitHub(), box = Box()
        let (reviews, paths) = try await service(github, box: box)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let jonas = try await reviews.finishLink(name: "Jonas", keys: ["imessage:jonas@example.com", "contact:A"], token: .init(access: "token-jonas"))
        XCTAssertEqual(jonas.login, "jonas-lindqvist")
        _ = try await reviews.finishLink(name: "Maya", keys: ["owner-person"], token: .init(access: "token-maya"))

        let batch = try await reviews.open(title: "Release 0.1.15", prs: [("harbor-labs/harbor-api", 65), ("harbor-labs/harbor-web", 122), ("harbor-labs/harbor-agent", 38)],
                                           placeID: "group", agentID: AgentID(), conversationID: ConversationID(), merge: true)
        XCTAssertEqual(box.posts.first?.0, "group")
        XCTAssertTrue(box.posts.first?.1.contains("1. harbor-api #65") ?? false, box.posts.first?.1 ?? "")
        XCTAssertEqual(box.posts.first?.2, ["Approve all"])
        let open = await reviews.hasOpenBatch(in: "group")
        XCTAssertTrue(open)

        // Someone not linked can't approve; chatter isn't an approval.
        let stranger = await reviews.heard("approve all", in: "group", isGroup: true, keys: ["imessage:someone"], via: "iMessage · Harbor")
        XCTAssertTrue(stranger?.contains("link your GitHub") ?? false)
        let chatter = await reviews.heard("I'll look after lunch", in: "group", isGroup: true, keys: ["imessage:jonas@example.com"], via: "iMessage · Harbor")
        XCTAssertNil(chatter)

        // Maya's #122 changes before Jonas gets to it.
        github.heads["harbor-labs/harbor-web#122"] = "bbb2"
        let said = await reviews.heard("Approve all", in: "group", isGroup: true, keys: ["imessage:jonas@example.com"], via: "iMessage · Harbor")
        XCTAssertEqual(github.reviews.map(\.pr), ["harbor-labs/harbor-api#65"], "as Jonas, on the listed commit only")
        XCTAssertEqual(github.reviews.first?.login, "jonas-lindqvist")
        XCTAssertEqual(github.reviews.first?.commit, "aaa")
        XCTAssertTrue(github.reviews.first?.body.contains("batch \(batch.id)") ?? false)
        XCTAssertTrue(said?.contains("harbor-web #122 (changed since it was listed)") ?? false, said ?? "")
        XCTAssertTrue(said?.contains("harbor-agent #38 (your own)") ?? false, said ?? "")
        XCTAssertTrue(box.notes.last?.contains("Merge what's ready") ?? false, box.notes.last ?? "")

        // Maya (from the app, say) approves #38 by its PR number; his own are skipped.
        let maya = await reviews.reviewer(forKeys: ["owner-person"])!
        _ = await reviews.approve(batchID: batch.id, reviewer: maya, which: [38], via: "the Pennant app")
        XCTAssertEqual(github.reviews.last?.login, "maya-okafor")
        XCTAssertEqual(github.reviews.last?.pr, "harbor-labs/harbor-agent#38")
        let status = await reviews.status()
        XCTAssertTrue(status.contains("harbor-web #122 PR 122: waiting"), status)

        let audit = try String(contentsOf: paths.root.appendingPathComponent("review-audit.jsonl"), encoding: .utf8)
        XCTAssertEqual(audit.split(separator: "\n").count, 2)
        XCTAssertTrue(audit.contains("\"reviewer\":\"jonas-lindqvist\"") && audit.contains("\"via\":\"iMessage · Harbor\""), audit)
    }

    func testWhatCountsAsAnApproval() {
        XCTAssertEqual(ReviewService.intent("approve all"), .some(nil), "approves everything")
        XCTAssertEqual(ReviewService.intent("Pennant, approved"), .some(nil), "approves everything")
        XCTAssertEqual(ReviewService.intent("LGTM"), .some(nil), "approves everything")
        XCTAssertEqual(ReviewService.intent("approve 1 3")!, [1, 3])
        XCTAssertEqual(ReviewService.intent("approve 1, 3 and #65")!, [1, 3, 65])
        XCTAssertTrue(ReviewService.intent("approve the design first") == nil)
        XCTAssertTrue(ReviewService.intent("I don't approve") == nil)
        XCTAssertTrue(ReviewService.intent("approvals are slow") == nil)
    }
}
