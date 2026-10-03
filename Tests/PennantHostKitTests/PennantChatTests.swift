import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// The Pennant chat: one conversation people have with Pennant. Pennant starts threads from it, and what comes of
/// every thread (its result, a question, a card) comes back to it as an update.
final class PennantChatTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    private func wait(_ s: HostService, _ id: TaskID, _ state: TaskState, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await s.store.task(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let now = try await s.store.task(id)?.state
        XCTFail("task never reached \(state) (it's \(String(describing: now)))", file: file, line: line)
    }

    private func updates(_ s: HostService) async throws -> [WorkUpdate] {
        let chat = try await s.runtime.ensureMainChat()
        let messages = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 500)
        return messages.flatMap(\.parts).compactMap { if case .update(let u) = $0 { return u }; return nil }
    }

    private func until(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("never: \(what)", file: file, line: line)
    }

    func testTheHostKeepsOnePennantChatThatDoesntClose() async throws {
        var s = try await service(ScriptedProvider([]))
        let chat = try await s.runtime.ensureMainChat()
        XCTAssertTrue(chat.isMain)
        let again = try await s.runtime.ensureMainChat()
        XCTAssertEqual(again.id, chat.id)
        try await s.runtime.closeConversation(chat.id, closed: true)
        let stored = try await s.store.conversation(chat.id)
        XCTAssertNil(stored?.closedAt, "the chat closed")
        await s.stop()

        // After a restart, the same chat.
        s = try await service(ScriptedProvider([]))
        let agents = try await s.store.listAgents(includeRetired: false)
        let lead = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let chats = try await s.store.listConversations(agentID: lead.id).filter(\.isMain)
        XCTAssertEqual(chats.map(\.id), [chat.id])
        await s.stop()
    }

    func testAThreadStartedFromTheChatRunsOnItsOwnAndItsResultComesBack() async throws {
        let start = ToolCall(id: ToolCallID("t1"), name: "start_thread", arguments: ["title": "README summary", "instructions": "Read the README and summarise it in two lines."])
        let provider = ScriptedProvider([.init(text: "The README covers setup and the CLI.")])
        provider.chatTurns = [.init(toolCalls: [start]), .init(text: "Started it; I'll let you know.")]
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Summarise the README", attachments: [])
        try await wait(s, ask, .completed)

        let conversations = try await s.store.listConversations(agentID: chat.agentID)
        let thread = try XCTUnwrap(conversations.first { $0.parentID == chat.id })
        XCTAssertEqual(thread.title, "README summary")
        let threadMessages = try await s.store.messagesAfter(conversationID: thread.id, after: nil, limit: 10)
        let kickoff = try XCTUnwrap(threadMessages.first)
        XCTAssertEqual(kickoff.text, "Read the README and summarise it in two lines.")
        XCTAssertEqual(kickoff.author?.name, HostService.defaultAgentName)

        try await until("the thread's result reached the chat") { try await self.updates(s).contains { $0.kind == .finished } }
        let afterRun = try await updates(s)
        let update = try XCTUnwrap(afterRun.first { $0.kind == .finished })
        XCTAssertEqual(update.threadID, thread.id)
        XCTAssertEqual(update.thread, "README summary")
        XCTAssertTrue(update.text.contains("README covers setup"), update.text)

        // The chat's turns carry the thread tools and don't work the screen; the thread's work it and start no threads.
        let chatRequest = try XCTUnwrap(provider.requests.first { $0.messages.first?.text.contains("## The Pennant chat") == true })
        let chatTools = Set(chatRequest.tools.map(\.name))
        XCTAssertTrue(chatTools.isSuperset(of: ["start_thread", "message_thread", "read_thread", "stop_thread"]), "\(chatTools.sorted())")
        // A look at the screen is a quick answer; working it (clicking, typing) is a thread's.
        XCTAssertFalse(chatTools.contains("click") || chatTools.contains("type_text") || chatTools.contains("delegate_task") || chatTools.contains("await_task"), "\(chatTools.sorted())")
        let threadRequest = try XCTUnwrap(provider.requests.first { r in
            let system = r.messages.first?.text ?? ""
            return !system.contains("## The Pennant chat") && !system.contains("writing in your chat with them") && !r.jsonMode
        })
        let threadTools = Set(threadRequest.tools.map(\.name))
        XCTAssertTrue(threadTools.contains("click"))
        XCTAssertFalse(threadTools.contains("start_thread"))
        // What's going on sits in the chat's turn note.
        XCTAssertTrue(chatRequest.messages.last?.text.contains("## What's going on") == true)
        // The chat talks like a person, under its own rules instead of the task house rules; the thread it started
        // follows the house rules and ends with a plain note for the chat.
        let chatPrompt = chatRequest.messages.first?.text ?? ""
        XCTAssertTrue(chatPrompt.contains("How you talk:") && chatPrompt.contains("Like a person, not an AI") && !chatPrompt.contains("## How to work"), chatPrompt)
        // Asked to do something, the chat briefs a thread to do it (cards catch what needs the owner), not to stop at research.
        XCTAssertTrue(chatPrompt.contains("brief the thread to do it, not to research it and stop"))
        let threadPrompt = threadRequest.messages.first?.text ?? ""
        XCTAssertTrue(threadPrompt.contains("## How to work") && threadPrompt.contains("## Your last message"), threadPrompt)
        await s.stop()
    }

    func testAThreadsQuestionAndCardComeToTheChatAndTheCardSaysHowItWasDecided() async throws {
        let ask = ToolCall(id: ToolCallID("q1"), name: "ask_user", arguments: ["question": "Which colour for the banner?"])
        let card = ToolCall(id: ToolCallID("c1"), name: "request_approval", arguments: ["title": "LinkedIn post: banner", "destination": "LinkedIn · Harbor", "text": "New banner, in blue."])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(toolCalls: [card]), .init(text: "Posted.")])
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, thread, task) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: nil, text: "Make a new banner", attachments: [])
        try await wait(s, task, .waitingForUser)
        try await until("the question reached the chat") { try await self.updates(s).contains { $0.kind == .question } }
        let asked = try await updates(s)
        let question = try XCTUnwrap(asked.first { $0.kind == .question })
        XCTAssertEqual(question.threadID, thread)
        XCTAssertEqual(question.text, "Which colour for the banner?")
        let board = await s.runtime.workBoard()
        XCTAssertTrue(board.contains("Make a new banner") && board.contains("waiting for their answer"), board)
        // Written in directly, not asked by the chat, not a job or a goal: its last message isn't for the chat.
        XCTAssertFalse(provider.requests.contains { $0.messages.first?.text.contains("## Your last message") == true })

        // The owner answers in the chat; Pennant passes it on, by the thread's short id.
        let sent = try await s.runtime.messageThread(from: task, thread: String(thread.rawValue.prefix(8)), text: "Blue.")
        XCTAssertTrue(sent.contains("goes on"), sent)
        try await until("the card reached the chat") { try await self.updates(s).contains { $0.kind == .approval } }
        let carded = try await updates(s)
        let cardUpdate = try XCTUnwrap(carded.first { $0.kind == .approval })
        XCTAssertEqual(cardUpdate.text, "LinkedIn post: banner")
        let waiting = try await s.runtime.pendingApprovals()
        let pending = try XCTUnwrap(waiting.first)
        XCTAssertEqual(cardUpdate.approvalID, pending.request.id)

        // Decided from the chat (by id, as the card there does): the update says how.
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: pending.request.id, verdict: .approve), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        try await wait(s, task, .completed)
        try await until("the update shows the decision") { try await self.updates(s).first { $0.kind == .approval }?.outcome == "Approved" }
        // Not asked for in the chat, and nothing to look at: no result update on top.
        let finished = try await updates(s).filter { $0.kind == .finished }
        XCTAssertTrue(finished.isEmpty, "\(finished)")
        await s.stop()
    }

    func testPennantAsksAThreadsQuestionInItsOwnWords() async throws {
        let ask = ToolCall(id: ToolCallID("q1"), name: "ask_user", arguments: ["question": "Two rulings so I don't guess: mark the goal achieved (3 nights, €2,340, 10 min from the office)? And open the dinner venue as its own goal?"])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Marked it done.")])
        provider.wordingTurns = [.init(text: "The offsite's booked: three nights for eight, €2,340 all in, ten minutes from the office. Shall I call that done? And do you want me to find a place for the team dinner too?")]
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, thread, task) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: nil, text: "Book the team offsite", attachments: [])
        try await wait(s, task, .waitingForUser)

        // One message from Pennant: its own words, with the thread's question under it as where it came from.
        var asked: Message?
        try await until("Pennant asked in the chat") {
            asked = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 50).first { $0.parts.contains { if case .update = $0 { return true }; return false } }
            return asked != nil
        }
        let message = try XCTUnwrap(asked)
        XCTAssertTrue(message.text.hasPrefix("The offsite's booked"), message.text)
        let update = try XCTUnwrap(message.parts.compactMap { if case .update(let u) = $0 { return u }; return nil }.first)
        XCTAssertEqual(update.kind, .question)
        XCTAssertEqual(update.threadID, thread)
        XCTAssertTrue(update.text.hasPrefix("Two rulings"))
        // Worded from the thread's question, in Pennant's voice.
        let wording = try XCTUnwrap(provider.requests.first { $0.messages.first?.text.contains("writing in your chat with them") == true })
        XCTAssertTrue(wording.messages.last?.text.contains("Two rulings so I don't guess") == true)
        XCTAssertTrue(wording.tools.isEmpty || wording.disableTools)

        // The owner answers in the chat; Pennant passes it on.
        _ = try await s.runtime.messageThread(from: task, thread: String(thread.rawValue.prefix(8)), text: "Yes, mark it done. No dinner goal for now.")
        try await wait(s, task, .completed)
        await s.stop()
    }

    func testAThreadTheChatStartedWrapsUpAtItsLimitAndSaysWhatItHas() async throws {
        let look = ToolCall(id: ToolCallID("l"), name: "list_directory", arguments: ["path": .string(paths.root.path)])
        // It keeps looking: more of the same, step after step.
        // Sixteen steps of it (the limit set below), then the wrap-up it's asked for.
        let provider = ScriptedProvider(Array(repeating: ScriptedProvider.Turn(toolCalls: [look]), count: 16) + [.init(text: "Found three venues so far; two more to check if you want.")])
        provider.chatTurns = [.init(text: "On it.")]
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Find venues", attachments: [])
        try await wait(s, ask, .completed)
        let (task, _) = try await s.runtime.startThread(from: ask, title: "Venues", instructions: "Find venues near the office.")
        let started = try await s.store.task(task)
        XCTAssertEqual(started?.budget.maxSteps, 30, "a chat thread gets a smaller allowance")
        // Small for the test: at its limit it's told to wrap up, once, instead of pausing.
        try await s.runtime.updateTask(task) { $0.budget.maxSteps = 16 }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, try await s.store.task(task)?.state.isTerminal != true { try await Task.sleep(for: .milliseconds(50)) }
        let notes = provider.requests.compactMap { $0.messages.last?.text }
        XCTAssertTrue(notes.contains { $0.contains("Check-in, 15 steps in") }, "long work takes stock")
        XCTAssertTrue(notes.contains { $0.contains("the limit for this piece of work") }, "at the limit it wraps up")
        try await until("the wrap-up reached the chat") { try await self.updates(s).contains { $0.kind == .finished } }
        await s.stop()
    }

    func testPennantTellsWhatCameOfItsWorkInItsOwnWordsOrKeepsQuiet() async throws {
        let provider = ScriptedProvider([.init(text: "Marked the booking done and verified both checks are stopped. No new commitments were made."),
                                         .init(text: "Venues: Casa do Largo (8 beds, EUR 2,340), Lumiares (EUR 2,980), Rua Nova loft (EUR 1,900).")])
        provider.chatTurns = [.init(text: "On it.")]
        provider.wordingTurns = [.init(text: "(nothing)"), .init(text: "I found three good places near the office; the cheapest is a loft for €1,900. Want the details?")]
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Close out the booking and find venues", attachments: [])
        try await wait(s, ask, .completed)

        // They already knew: Pennant keeps it to itself, and it's kept for Pennant only.
        let (first, _) = try await s.runtime.startThread(from: ask, title: "Close out the booking", instructions: "Mark the booking done.")
        try await wait(s, first, .completed)
        try await until("the first result was kept quiet") { try await self.updates(s).contains { $0.taskID == first && $0.silent == true } }
        let quiet = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 100).first { m in
            m.parts.contains { if case .update(let u) = $0 { return u.taskID == first }; return false }
        }
        XCTAssertEqual(quiet?.text, "", "no words of its own")

        // News worth telling: in Pennant's words, with where it came from.
        let (second, _) = try await s.runtime.startThread(from: ask, title: "Venues", instructions: "Find venues near the office.")
        try await wait(s, second, .completed)
        var told: Message?
        try await until("Pennant told them about the venues") {
            told = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 100).first { m in
                m.parts.contains { if case .update(let u) = $0 { return u.taskID == second }; return false }
            }
            return told != nil
        }
        XCTAssertTrue(told?.text.hasPrefix("I found three good places") == true, told?.text ?? "")
        let telling = try XCTUnwrap(provider.requests.last { $0.messages.first?.text.contains("writing in your chat with them") == true })
        XCTAssertTrue(telling.messages.first?.text.contains("Like a person, not an AI") == true, "the same voice as the chat")
        await s.stop()
    }

    func testPennantIntroducesADraftAndTheCardShowsUnderItsWords() async throws {
        let card = ToolCall(id: ToolCallID("c1"), name: "request_approval", arguments: ["title": "LinkedIn post: banner", "destination": "LinkedIn · Harbor", "text": "New banner, in blue."])
        let provider = ScriptedProvider([.init(toolCalls: [card]), .init(text: "Posted.")])
        provider.wordingTurns = [.init(text: "The new banner post is ready; it's short and in blue. Have a look before it goes out.")]
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: nil, text: "Post the new banner", attachments: [])
        try await wait(s, task, .waitingForUser)
        var introduced: Message?
        try await until("Pennant introduced the draft") {
            introduced = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 50).first { m in
                m.parts.contains { if case .update(let u) = $0 { return u.kind == .approval }; return false }
            }
            return introduced != nil
        }
        XCTAssertTrue(introduced?.text.hasPrefix("The new banner post is ready") == true)
        let wording = try XCTUnwrap(provider.requests.first { $0.messages.first?.text.contains("writing in your chat with them") == true })
        XCTAssertTrue(wording.messages.last?.text.contains("New banner, in blue.") == true, "Pennant sees the draft it introduces")
        await s.stop()
    }

    /// A thread the chat started brings in a helper that runs to its limit. `obedient`: it wraps up when told to.
    private func helperAtItsLimit(obedient: Bool) async throws -> (HostService, ScriptedProvider, thread: TaskID) {
        let look = ToolCall(id: ToolCallID("l"), name: "list_directory", arguments: ["path": .string(paths.root.path)])
        let delegate = ToolCall(id: ToolCallID("d1"), name: "delegate_task", arguments: ["title": "Prerequisites", "objective": "List what an organization needs", "completion_criteria": "A list"])
        let storeBox = Locked<SQLiteStore?>(nil)
        let parentBox = Locked<TaskID?>(nil)
        let provider = ScriptedProvider([
            .init(toolCalls: [delegate]),
            .init(dynamicToolCalls: {
                var childID = "missing"
                for _ in 0 ..< 200 {
                    if let store = storeBox.get(), let parent = parentBox.get(), let child = try? await store.childTasks(parentTaskID: parent).first { childID = child.id.rawValue; break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return [ToolCall(id: ToolCallID("a1"), name: "await_task", arguments: ["task_id": .string(childID), "timeout_seconds": 60])]
            }),
            .init(text: "The prerequisites are in."),
        ])
        // The helper's allowance is half the thread's 30: 15 steps of looking, then (if it obeys) its report.
        provider.workerTurns = Array(repeating: ScriptedProvider.Turn(toolCalls: [look]), count: obedient ? 15 : 30) + [.init(text: "Found them: billing, a root email per account, MFA.")]
        provider.chatTurns = [.init(text: "On it.")]
        let s = try await service(provider)
        storeBox.set(await s.store)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Set up the accounts", attachments: [])
        try await wait(s, ask, .completed)
        let (thread, _) = try await s.runtime.startThread(from: ask, title: "Accounts", instructions: "Work out what the accounts need.")
        parentBox.set(thread)
        return (s, provider, thread)
    }

    func testAHelperAtItsLimitReportsToItsThreadInsteadOfAskingTheOwner() async throws {
        let (s, provider, thread) = try await helperAtItsLimit(obedient: true)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, try await s.store.task(thread)?.state.isTerminal != true { try await Task.sleep(for: .milliseconds(50)) }
        let done = try await s.store.task(thread)
        XCTAssertEqual(done?.state, .completed, "the thread got its helper's answer instead of waiting forever")
        let children = try await s.store.childTasks(parentTaskID: thread)
        let helper = try XCTUnwrap(children.first)
        XCTAssertEqual(helper.state, .completed)
        XCTAssertTrue(helper.resultSummary?.contains("Found them") == true, helper.resultSummary ?? "")
        let helperRequests = provider.requests.filter { $0.messages.first?.text.contains("task-scoped worker") == true }
        XCTAssertTrue(helperRequests.contains { $0.messages.last?.text.contains("for the task that asked you") == true }, "told to wrap up for its parent")
        XCTAssertFalse(helperRequests.contains { $0.tools.contains { $0.name == "ask_user" } }, "a helper can't ask the owner")
        let questions = try await updates(s).filter { $0.kind == .question }
        XCTAssertTrue(questions.isEmpty, "nothing was asked of the owner: \(questions.map(\.text))")
        await s.stop()
    }

    func testAHelperThatKeepsGoingPastItsWrapUpFinishesWithWhatItHas() async throws {
        let (s, _, thread) = try await helperAtItsLimit(obedient: false)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, try await s.store.task(thread)?.state.isTerminal != true { try await Task.sleep(for: .milliseconds(50)) }
        let children = try await s.store.childTasks(parentTaskID: thread)
        let helper = try XCTUnwrap(children.first)
        XCTAssertEqual(helper.state, .completed)
        XCTAssertTrue(helper.resultSummary?.hasPrefix("Stopped at its limit") == true, helper.resultSummary ?? "")
        let done = try await s.store.task(thread)
        XCTAssertEqual(done?.state, .completed)
        await s.stop()
    }

    func testAThreadAtItsLimitCollectsItsHelperInsteadOfStoppingItMidway() async throws {
        let look = ToolCall(id: ToolCallID("l"), name: "list_directory", arguments: ["path": .string(paths.root.path)])
        let delegate = ToolCall(id: ToolCallID("d1"), name: "delegate_task", arguments: ["title": "Make the mailbox", "objective": "Create the shared mailbox", "completion_criteria": "It exists"])
        let storeBox = Locked<SQLiteStore?>(nil)
        let parentBox = Locked<TaskID?>(nil)
        let providerBox = Locked<ScriptedProvider?>(nil)
        let provider = ScriptedProvider([
            .init(toolCalls: [delegate]), .init(toolCalls: [look]), .init(toolCalls: [look]),
            // At its limit, told to collect its helper: it waits for it (and the helper, held till now, finishes).
            .init(before: { providerBox.get()?.release() }, dynamicToolCalls: {
                var childID = "missing"
                if let store = storeBox.get(), let parent = parentBox.get(), let child = try? await store.childTasks(parentTaskID: parent).first { childID = child.id.rawValue }
                return [ToolCall(id: ToolCallID("a1"), name: "await_task", arguments: ["task_id": .string(childID), "timeout_seconds": 60])]
            }),
            .init(text: "The mailbox is made; that's as far as this run goes."),
        ])
        providerBox.set(provider)
        provider.workerTurns = [.init(text: "Made the mailbox.", blockUntilReleased: true)]
        provider.chatTurns = [.init(text: "On it.")]
        let s = try await service(provider)
        storeBox.set(await s.store)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Make the mailboxes", attachments: [])
        try await wait(s, ask, .completed)
        let (thread, _) = try await s.runtime.startThread(from: ask, title: "Mailboxes", instructions: "Make the shared mailboxes.")
        parentBox.set(thread)
        try await s.runtime.updateTask(thread) { $0.budget.maxSteps = 3 }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, try await s.store.task(thread)?.state.isTerminal != true { try await Task.sleep(for: .milliseconds(50)) }
        let children = try await s.store.childTasks(parentTaskID: thread)
        let helper = try XCTUnwrap(children.first)
        XCTAssertEqual(helper.state, .completed, "the helper finished instead of being stopped midway")
        let notes = provider.requests.compactMap { $0.messages.last?.text }
        XCTAssertTrue(notes.contains { $0.contains("collect your helpers still at work") && $0.contains("Make the mailbox") })
        await s.stop()
    }

    func testACardDecidedTheMomentItGoesUpStillReachesItsTask() async throws {
        let card = ToolCall(id: ToolCallID("c1"), name: "request_approval", arguments: ["title": "Post: launch", "destination": "LinkedIn", "text": "We're live."])
        let s = try await service(ScriptedProvider([.init(toolCalls: [card]), .init(text: "Left it.")]))
        let chat = try await s.runtime.ensureMainChat()
        // Decide as soon as the card shows, while the task is still posting its update to the chat.
        let events = await s.eventBus.subscribe()
        let decider = Task {
            for await event in events {
                guard case .messageAppended(let m) = event.payload else { continue }
                for case .approval(let a) in m.parts {
                    try? await s.runtime.decideApproval(ApprovalDecision(approvalID: a.id, verdict: .reject), by: nil)
                    return
                }
            }
        }
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: nil, text: "Draft the launch post", attachments: [])
        try await wait(s, task, .completed)
        decider.cancel()
        await s.stop()
    }

    func testCardsFromTwoThreadsTheChatStartedAreSeparateDecisions() async throws {
        let provider = ScriptedProvider([.init(text: "First done."), .init(text: "Second done.")])
        provider.chatTurns = [.init(text: "On it.")]
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Two things", attachments: [])
        try await wait(s, ask, .completed)
        let (one, _) = try await s.runtime.startThread(from: ask, title: "Reply to Jonas", instructions: "Draft the reply to Jonas.")
        let (two, _) = try await s.runtime.startThread(from: ask, title: "Reply to Priya", instructions: "Draft the reply to Priya.")
        try await wait(s, one, .completed)
        try await wait(s, two, .completed)

        func reply(_ task: TaskID, _ title: String) -> ApprovalRequest {
            var card = ApprovalRequest(taskID: task, title: title, destination: "Outlook", text: "Draft")
            card.action = ApprovalAction(tool: "mail_reply", arguments: .object([:]), textField: "body", label: "Approve & send")
            return card
        }
        let first = reply(one, "Reply to Jonas")
        _ = try await s.runtime.makeRoom(for: first, taskID: one, replaces: [], alongside: false)
        try await s.runtime.postApproval(taskID: one, first)
        // Each thread is its own source: the chat that started both isn't one decision.
        _ = try await s.runtime.makeRoom(for: reply(two, "Reply to Priya"), taskID: two, replaces: [], alongside: false)
        await s.stop()
    }

    func testTheChatAnswersWhileThreadsFillEverySlot() async throws {
        let provider = ScriptedProvider([.init(text: "Slow work.", blockUntilReleased: true)])
        provider.chatTurns = [.init(text: "Hello!")]
        let s = try await service(provider)
        await s.runtime.setMaxConcurrentTasks(1)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, slow) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: nil, text: "A long job", attachments: [])
        try await wait(s, slow, .running)
        let (_, _, hello) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Hi", attachments: [])
        try await wait(s, hello, .completed)
        provider.release()
        try await wait(s, slow, .completed)
        await s.stop()
    }

    func testStoppingAThreadFromTheChat() async throws {
        let provider = ScriptedProvider([.init(text: "Never finishes.", blockUntilReleased: true)])
        let s = try await service(provider)
        let chat = try await s.runtime.ensureMainChat()
        let (_, thread, task) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: nil, text: "Watch the inbox all day", attachments: [])
        try await wait(s, task, .running)
        let stopped = try await s.runtime.stopThread("Watch the inbox")
        XCTAssertTrue(stopped.contains("Stopped"), stopped)
        try await wait(s, task, .cancelled)
        let read = try await s.runtime.readThread(thread.rawValue, limit: 10)
        XCTAssertTrue(read.contains("stopped") && read.contains("Watch the inbox all day"), read)
        // Stopped on purpose: no update.
        let all = try await updates(s)
        XCTAssertTrue(all.isEmpty, "\(all)")
        await s.stop()
    }
}
