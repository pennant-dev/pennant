@testable import PennantHostKit
import PennantCore
import XCTest

/// Cards only for what can't be undone: a plain `rm` goes to the Trash, a propose-only goal still looks, the owner can
/// turn each sign-off off, and Dismiss closes a card without waking the agent.
final class FewerCardsTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider, asking: Bool = true) async throws -> HostService {
        var config = asking ? HostConfig.asking : HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    private func waitFor(_ s: HostService, _ id: TaskID, _ state: TaskState) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await s.store.task(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("task never reached \(state)")
    }

    // MARK: Deleting

    func testAPlainRmInPennantsShellGoesToTheTrashAndDoesntAsk() {
        let free = ["rm -rf ~/Documents/Harbor/renders/tmp", "cd ~/Documents/Harbor && rm -f review/*.png", "for f in a b; do rm \"$f\"; done",
                    "R=~/Documents/Harbor; rm -rf \"$R/_scratch\"", "rmdir empty", "trash old.txt"]
        for c in free { XCTAssertNil(SignOff.reason(command: c, rmGoesToTrash: true), c) }
        // The real rm, and what the shell function can't catch, still ask.
        let real = ["command rm -rf ~/Documents/Harbor", "/bin/rm notes.txt", "sudo rm notes.txt", "ls | xargs rm", "find . -exec rm {} +", "exec rm x",
                    "env rm x", "rm x && git push --force origin main", "git clean -fd"]
        for c in real { XCTAssertEqual(SignOff.reason(command: c, rmGoesToTrash: true), .deletes, c) }
        // Elsewhere (a Claude Code run's own shell) rm is the real one.
        XCTAssertEqual(SignOff.reason(command: "rm -rf ~/Documents/Harbor/renders"), .deletes)
    }

    func testTheTrashRmKeepsRmsBehaviourAndLeavesHighFoldersAlone() async throws {
        try XCTSkipUnless(ShellTrash.isAvailable, "this Mac has no trash command")
        let dir = paths.root.appendingPathComponent("trash-test")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("sub/a.txt"))
        func run(_ command: String) async throws -> ShellRunner.Result {
            let wrapped = ShellTrash.wrap(command)
            return try await ShellRunner.run(wrapped.command, workingDirectory: dir.path, environment: wrapped.environment, timeout: 20)
        }
        let kind = try await run("whence -w rm")
        XCTAssertTrue(kind.stdout.contains("function"), kind.stdout)
        let folder = try await run("rm sub")
        XCTAssertNotEqual(folder.exitCode, 0)
        XCTAssertTrue(folder.stderr.contains("is a directory"), folder.stderr)
        let missing = try await run("rm -f nothing-here && rm nothing-here")
        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertTrue(missing.stderr.contains("No such file"), missing.stderr)
        // A temporary folder is removed as usual, not trashed.
        let temp = try await run("rm -rf sub")
        XCTAssertEqual(temp.exitCode, 0, temp.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sub").path))
        // A folder high up is left alone, and the message says how to ask.
        let high = try await run("rm -rf ~/Library")
        XCTAssertNotEqual(high.exitCode, 0)
        XCTAssertTrue(high.stderr.contains("command rm"), high.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library"))
    }

    // MARK: Looking

    func testCommandsThatOnlyReadAreToldApart() {
        let reads = ["rg -n Maya ~/Documents/Harbor | head -20", "cd ~/Documents/Harbor && git log --oneline -5 && git status --short",
                     "gh pr list -R harbor/app --json number,title", "gh api repos/harbor/app/pulls", "ls -la; cat notes.md 2>/dev/null",
                     "find . -name '*.md' | wc -l", "kubectl get pods -n dana", "sed -n '1,40p' README.md", "curl -s https://harbor.example/api/status",
                     "az aks list -o table", "for r in a b; do git -C \"$r\" log -1; done", "echo $(date +%F)", "git branch -a"]
        for c in reads { XCTAssertTrue(ShellReads.isReadOnly(c), c) }
        let changes = ["echo idea >> ideas.md", "sed -i '' s/a/b/ notes.md", "git commit -m wip", "git branch maya-draft", "gh api repos/harbor/app/issues -f title=x",
                       "curl -X POST https://harbor.example/api", "python3 publish.py", "rg Maya | tee found.txt", "kubectl delete pod web", "mkdir drafts",
                       "npm install", "bash -c 'ls'", ""]
        for c in changes { XCTAssertFalse(ShellReads.isReadOnly(c), c) }
    }

    // MARK: Ask me before…

    func testEachSignOffIsOffUntilTheOwnerTurnsItOn() throws {
        var askFirst = HostConfig.AskFirst()
        for reason in [SignOff.Reason.publishes, .spends, .deletes] { XCTAssertFalse(SignOff.asks(reason, askFirst)) }
        XCTAssertTrue(SignOff.asks(.changes, askFirst), "a tool its maker marked asksFirst always asks")
        askFirst.spends = true
        XCTAssertTrue(SignOff.asks(.spends, askFirst))
        XCTAssertFalse(SignOff.asks(.publishes, askFirst))
        // A config from before the switches asks for none.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HostConfig())) as! [String: Any]
        json.removeValue(forKey: "askFirst")
        let old = try JSONDecoder().decode(HostConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.askFirst, HostConfig.AskFirst())
    }

    // MARK: Without cards

    func testWithSendsUnaskedACardGoesAheadWithoutShowing() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "LinkedIn post: Harbor 2.0", "destination": "LinkedIn · Harbor", "text": "Harbor 2.0 is live."])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Posted.")])
        let s = try await service(provider, asking: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Post the Harbor launch", attachments: [])
        try await waitFor(s, taskID, .completed)
        let pending = try await s.runtime.pendingApprovals()
        XCTAssertTrue(pending.isEmpty, "nothing waits")
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 100)
        let card = try XCTUnwrap(messages.flatMap(\.parts).compactMap { part -> ApprovalRequest? in if case .approval(let a) = part { return a }; return nil }.first)
        XCTAssertEqual(card.state, .approved)
        XCTAssertTrue(card.isUnasked, "kept for its approval_id, but not a card in the chat")
        let records = try await s.store.toolRecords(taskID: taskID)
        XCTAssertTrue(records.first { $0.call.id == ToolCallID("a1") }?.resultSummary.contains("APPROVED") ?? false)
        await s.stop()
    }

    func testCardsNobodyAnswersGoAwayAfterADayAndAHeldCallOutlivesItsWork() async throws {
        let delete = ToolCall(id: ToolCallID("d1"), name: "shell", arguments: ["command": "command rm -rf ~/Documents/harbor/old-site"])
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "Harbor newsletter", "destination": "LinkedIn", "text": "Draft."])
        let provider = ScriptedProvider([.init(toolCalls: [delete]), .init(text: "The old site goes once Maya says yes."), .init(toolCalls: [ask]), .init(text: "Never asked for.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        // A thread doesn't wait at the check before one command: it finishes, and the call waits on its card.
        let (_, conversationID, deleting) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Clear out the old Harbor site", attachments: [])
        try await waitFor(s, deleting, .completed)
        // A card someone may still answer, from work that waits on it.
        let (_, _, waiting) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "Draft the newsletter post", attachments: [])
        try await waitFor(s, waiting, .waitingForUser)
        let before = try await s.runtime.pendingApprovals().count
        XCTAssertEqual(before, 2)
        let now = await s.runtime.retireStaleCards()
        XCTAssertEqual(now, 0, "a held call stays for the owner after its work ended")
        // A day on, both go, and the work waiting on its card stops without a model call.
        var asked = provider.requests.count
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(50))
            if provider.requests.count == asked { break }
            asked = provider.requests.count
        }
        let later = await s.runtime.retireStaleCards(now: Date().addingTimeInterval(TaskRuntime.cardLifetime + 60))
        XCTAssertEqual(later, 2)
        try await waitFor(s, waiting, .cancelled)
        let left = try await s.runtime.pendingApprovals()
        XCTAssertTrue(left.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.requests.count, asked, "nobody was woken")
        await s.stop()
    }

    func testAThreadCarriesOnPastACardAndTheCallRunsWhenApproved() async throws {
        actor Counter { var n = 0; func add() { n += 1 } }
        struct Send: Tool {
            let sent: Counter
            var spec: ToolSpec { ToolSpec(name: "mail__mail_send", description: "send", inputSchema: JSONSchema.object([:]), isConsequential: true, source: "mcp:mail") }
            func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
                await sent.add()
                return .text(ToolCallID("x"), name: spec.name, "Sent to Dana.")
            }
        }
        let send = ToolCall(id: ToolCallID("m1"), name: "mail__mail_send", arguments: ["to": "dana@harbor.test", "body": "The Harbor deck is ready."])
        let provider = ScriptedProvider([.init(toolCalls: [send]), .init(text: "The email to Dana waits on your OK."), .init(text: "Dana has the deck.")])
        let s = try await service(provider)
        let sent = Counter()
        await s.broker.register([Send(sent: sent)])
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Send Dana the Harbor deck", attachments: [])
        // The thread finishes without waiting; the card holds the call.
        try await waitFor(s, task, .completed)
        let none = await sent.n
        XCTAssertEqual(none, 0, "nothing sent before the OK")
        let cards = try await s.runtime.pendingApprovals()
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.request.heldCall?.id, ToolCallID("m1"))
        let records = try await s.store.toolRecords(taskID: task)
        XCTAssertEqual(records.first { $0.call.id == ToolCallID("m1") }?.status, .cancelled)

        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve), by: nil)
        let once = await sent.n
        XCTAssertEqual(once, 1, "approving runs it, once")
        let settled = try await s.store.toolRecords(taskID: task)
        XCTAssertEqual(settled.first { $0.call.id == ToolCallID("m1") }?.status, .succeeded)
        // The thread hears how it went, as a new message in it.
        let deadline = Date().addingTimeInterval(5)
        var told = false
        while !told, Date() < deadline {
            told = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 100).contains { $0.role == .user && $0.text.contains("approved") && $0.text.contains("Sent to Dana.") }
            if !told { try await Task.sleep(for: .milliseconds(30)) }
        }
        XCTAssertTrue(told)
        await s.stop()
    }

    // MARK: Dismiss

    func testDismissingACardStopsTheWorkWaitingOnItWithoutAModelCall() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "Harbor newsletter", "destination": "LinkedIn", "text": "Draft."])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "This reply should never be asked for.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Draft the newsletter post", attachments: [])
        try await waitFor(s, taskID, .waitingForUser)
        let waiting = try await s.runtime.pendingApprovals()
        let card = try XCTUnwrap(waiting.first?.request)
        // The chat words the card's news for the owner when it goes up; that call isn't the dismissal's.
        var asked = provider.requests.count
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(50))
            if provider.requests.count == asked { break }
            asked = provider.requests.count
        }
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .dismiss), by: nil)
        try await waitFor(s, taskID, .cancelled)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.requests.count, asked, "nobody wrote a reply to a dismissed card")
        let found = try await s.runtime.findApproval(card.id)
        let decided = try XCTUnwrap(found?.request)
        XCTAssertEqual(decided.state, .rejected, "older clients read it as rejected")
        XCTAssertTrue(decided.isDismissed)
        let pending = try await s.runtime.pendingApprovals()
        XCTAssertTrue(pending.isEmpty)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 100)
        XCTAssertFalse(messages.contains { $0.role == .user && $0.text.contains("Decision") }, "nothing went back to the agent")
        await s.stop()
    }

    func testDismissingACardWhoseWorkHasEndedSendsNothing() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "Reply to Dana", "destination": "Email", "text": "Thanks Dana."])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "This reply should never be asked for.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Reply to Dana", attachments: [])
        try await waitFor(s, taskID, .waitingForUser)
        let waiting = try await s.runtime.pendingApprovals()
        let card = try XCTUnwrap(waiting.first?.request)
        try await s.runtime.cancelTask(taskID, reason: "moved on")
        try await waitFor(s, taskID, .cancelled)
        let asked = provider.requests.count
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .dismiss), by: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(provider.requests.count, asked)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 100)
        XCTAssertFalse(messages.contains { $0.role == .user && $0.text.contains("Decision") })
        await s.stop()
    }

    func testADismissedCardSaysSoAndOldCardsStillDecode() throws {
        var card = ApprovalRequest(taskID: TaskID(), title: "Post", destination: "LinkedIn", text: "Draft.")
        card.state = .rejected
        card.dismissed = true
        let back = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(card))
        XCTAssertTrue(back.isDismissed)
        XCTAssertEqual(TaskRuntime.outcome(of: back), "Dismissed")
        card.dismissed = nil
        let old = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(card))
        XCTAssertFalse(old.isDismissed)
        XCTAssertEqual(try JSONDecoder().decode(ApprovalDecision.Verdict.self, from: Data("\"dismiss\"".utf8)), .dismiss)
    }
}
