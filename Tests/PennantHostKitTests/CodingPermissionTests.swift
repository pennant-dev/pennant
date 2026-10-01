import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// What a coding run may do without asking: only the owner's sign-offs ask (or everything, in "Ask for everything"),
/// "Allow for the rest of this task" stops the asking for that task only, and on GitHub it never acts as the owner.
final class CodingPermissionTests: XCTestCase {
    func testAllowingTheRestOfATaskStopsTheAskingForThatTaskOnly() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let provider = ScriptedProvider([.init(text: "Working…", blockUntilReleased: true), .init(text: "Working…", blockUntilReleased: true)])
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Fix it", attachments: [])
        let (_, _, other) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Something else", attachments: [])
        let runtime = await s.runtime

        // Local work: no card.
        let local = try await runtime.coderPermission(taskID: task, tool: "Bash", input: ["command": "cd x && swift test"])
        XCTAssertTrue(local.allow)
        let noCards = try await runtime.pendingApprovals()
        XCTAssertTrue(noCards.isEmpty)

        // Committing doesn't ask; a push without an identity of its own is refused (it would go out as the owner);
        // a delete asks, and the card offers the rest of the task.
        let commit = try await runtime.coderPermission(taskID: task, tool: "Bash", input: ["command": "git commit -am 'Fix it'"])
        XCTAssertTrue(commit.allow)
        let push = try await runtime.coderPermission(taskID: task, tool: "Bash", input: ["command": "git push origin feature"])
        XCTAssertFalse(push.allow)
        XCTAssertTrue(push.message?.contains("no GitHub identity") ?? false, push.message ?? "")
        let asked = Task { try await runtime.coderPermission(taskID: task, tool: "Bash", input: ["command": "git branch -D old-feature"]) }
        var card: PendingApproval?
        let deadline = Date().addingTimeInterval(5)
        while card == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            card = try await runtime.pendingApprovals().first
        }
        let pending = try XCTUnwrap(card)
        XCTAssertEqual(pending.request.allowRestLabel, "Allow for the rest of this task")
        try await runtime.decideApproval(ApprovalDecision(approvalID: pending.id, verdict: .approveRest), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        let answer = try await asked.value
        XCTAssertTrue(answer.allow)

        // The rest of this task runs without cards…
        let later = try await runtime.coderPermission(taskID: task, tool: "Bash", input: ["command": "rm -rf build"])
        XCTAssertTrue(later.allow)
        let stillNone = try await runtime.pendingApprovals()
        XCTAssertTrue(stillNone.isEmpty)
        // …but another task still asks.
        let otherAsk = Task { try await runtime.coderPermission(taskID: other, tool: "Bash", input: ["command": "rm -rf build"]) }
        var otherCard: PendingApproval?
        let deadline2 = Date().addingTimeInterval(5)
        while otherCard == nil, Date() < deadline2 {
            try await Task.sleep(for: .milliseconds(30))
            otherCard = try await runtime.pendingApprovals().first
        }
        XCTAssertNotNil(otherCard, "another task still asks")
        if let otherCard { try await runtime.decideApproval(ApprovalDecision(approvalID: otherCard.id, verdict: .reject), by: nil) }
        _ = try? await otherAsk.value
        provider.release()
        await s.stop()
    }

    func testAskForEverythingStillAsksForEverything() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let provider = ScriptedProvider([.init(text: "Working…", blockUntilReleased: true)])
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Fix it", attachments: [])
        let stored = try await s.store.conversation(conversationID)
        var conversation = try XCTUnwrap(stored)
        conversation.engineMode = .manual
        try await s.store.upsertConversation(conversation)
        let runtime = await s.runtime
        let asked = Task { try await runtime.coderPermission(taskID: task, tool: "Bash", input: ["command": "ls"]) }
        var card: PendingApproval?
        let deadline = Date().addingTimeInterval(5)
        while card == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            card = try await runtime.pendingApprovals().first
        }
        let pending = try XCTUnwrap(card, "even ls asks in manual mode")
        XCTAssertNil(pending.request.allowRestLabel, "and there's no allow-the-rest button")
        try await runtime.decideApproval(ApprovalDecision(approvalID: pending.id, verdict: .approve), by: nil)
        _ = try await asked.value
        provider.release()
        await s.stop()
    }

    func testTheNewCardFieldsSurviveTheWire() throws {
        var card = ApprovalRequest(taskID: TaskID(), title: "Run a command", destination: "Coder", text: "git push")
        card.allowRestLabel = "Allow for the rest of this task"
        card.approvedForRest = true
        let back = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(back.allowRestLabel, "Allow for the rest of this task")
        XCTAssertEqual(back.approvedForRest, true)
    }

    /// A person's sign-off, which agents never give with the owner's account.
    func testSigningOffIsForPeople() {
        for command in ["gh pr review 28 --repo harbor-labs/x --approve", "gh pr review 5 -a -b ok", "echo; gh pr review 28 --approve && gh pr merge 28",
                        "gh api -X POST repos/o/r/pulls/5/reviews -f event=APPROVE", "gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: \"x\"}) { thread { isResolved } } }'",
                        "gh api graphql -f query='mutation { addPullRequestReview(input:{pullRequestId:\"x\", event: APPROVE}) { clientMutationId } }'",
                        "gh api -X POST repos/o/r/actions/runs/1/pending_deployments -f state=approved"] {
            XCTAssertTrue(GitHubGuard.signsOff(command), command)
        }
        for command in ["gh pr review 5 --comment -b 'looks off'", "gh pr review 5 --request-changes -b no", "gh pr view 28 --json reviews", "gh pr merge 28 --squash",
                        "gh api repos/o/r/pulls/5/reviews"] {
            XCTAssertFalse(GitHubGuard.signsOff(command), command)
        }
        // As the GitHub App, under its own name: fine.
        XCTAssertFalse(GitHubGuard.signsOff("\"$SKILL/scripts/ghapp.sh\" gh pr review 28 -R harbor-labs/x --approve"))
    }

    /// The owner's setting is how a new run asks; a request may ask for a plan, but "Ask for everything" can't be
    /// loosened.
    func testTheOwnersModeSetsHowRunsAsk() {
        XCTAssertNil(HostConfig.Coding().mode(asked: nil), "only sign-offs ask by default")
        XCTAssertEqual(HostConfig.Coding().mode(asked: .plan), .plan)
        XCTAssertEqual(HostConfig.Coding(mode: .plan).mode(asked: nil), .plan)
        XCTAssertEqual(HostConfig.Coding(mode: .manual).mode(asked: nil), .manual)
        XCTAssertEqual(HostConfig.Coding(mode: .manual).mode(asked: .acceptEdits), .manual)
        XCTAssertEqual(HostConfig.Coding(mode: .manual).mode(asked: .plan), .manual)
    }
}
