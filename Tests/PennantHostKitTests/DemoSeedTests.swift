import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class DemoSeedTests: XCTestCase {
    func testSeedsOneAgentAndItsJobsIntoAnEmptyFolderOnly() async throws {
        let paths = HostPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try await DemoSeed.run(paths: paths)

        let config = ConfigLoader.load(from: paths.configURL)
        XCTAssertEqual(config.api.port, DemoSeed.port)
        XCTAssertFalse(config.api.listenOnNetwork, "the demo host stays on this Mac")
        XCTAssertFalse(config.api.advertiseBonjour)
        XCTAssertEqual(config.coding?.engine, .claudeCode)

        let store = try SQLiteStore(paths: paths)
        let agents = try await store.listAgents(includeRetired: true)
        XCTAssertEqual(agents.filter { $0.kind == .persistent }.map(\.name), ["Pennant"], "one agent; helpers are workers")
        let tasks = try await store.listTasks(agentID: nil, includeFinished: true)
        XCTAssertFalse(tasks.contains { $0.state.isActive }, "nothing the host would pick up and run at start")
        let schedules = try await store.listSchedules()
        let plain = schedules.filter { $0.goalID == nil }
        XCTAssertEqual(Set(plain.map(\.name)), ["Morning brief", "Inbox drafts", "Company post", "Product demo", "Service check"])
        XCTAssertTrue(plain.allSatisfy { $0.skillID != nil }, "every job follows a skill")
        XCTAssertTrue(schedules.allSatisfy { $0.nextRunAt.map { $0 > Date().addingTimeInterval(20 * 60) } == true }, "none fires while pictures are taken")
        for job in schedules { XCTAssertNoThrow(try Scheduler.parse(job), job.schedule) }

        // A goal at work, with its two jobs and its board, and one proposed on a card.
        let goals = try await store.listGoals()
        let working = try XCTUnwrap(goals.first { $0.status == .active })
        XCTAssertNotNil(working.conversationID)
        XCTAssertEqual(Set(schedules.filter { $0.goalID == working.id }.compactMap(\.goalRun)), ["work", "review"])
        let board = try await store.goalItems(working.id)
        XCTAssertEqual(Set(board.map(\.state)), [.waiting, .doing, .next, .idea, .done])
        let proposed = try XCTUnwrap(goals.first { $0.status == .proposed })
        XCTAssertTrue(schedules.allSatisfy { $0.goalID != proposed.id }, "a proposed goal has no jobs yet")

        // Maya's Pennant chat, with a coding run it started waiting on a card that says Allow.
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let conversations = try await store.listConversations(agentID: pennant.id)
        let chat = try XCTUnwrap(conversations.first { $0.isMain })
        XCTAssertEqual(conversations.filter(\.isMain).count, 1)
        let coding = try XCTUnwrap(conversations.first { $0.isCodingRun })
        XCTAssertEqual(coding.parentID, chat.id)
        let cards = try await store.messagesAfter(conversationID: coding.id, after: nil, limit: 500).flatMap(\.parts).compactMap { part -> ApprovalRequest? in
            if case .approval(let a) = part { return a }; return nil
        }
        XCTAssertEqual(cards.map(\.approveLabel), ["Allow"])

        // What the threads did, in the chat: their cards (yesterday's decided), and the results worth seeing.
        let updates = try await store.messagesAfter(conversationID: chat.id, after: nil, limit: 500).flatMap(\.parts).compactMap { part -> WorkUpdate? in
            if case .update(let u) = part { return u }; return nil
        }
        XCTAssertEqual(Set(updates.filter { $0.kind == .approval }.map(\.text)),
                       ["Delete: run a command", "LinkedIn post: launch teaser", "LinkedIn post: Harbor 2.0 is live", "Reply to Jonas Lindqvist"])
        XCTAssertEqual(updates.first { $0.text == "LinkedIn post: launch teaser" }?.outcome, "Approved and published")
        XCTAssertEqual(updates.filter { $0.kind == .finished }.count, 2)
        // A thread's question, asked in Pennant's own words.
        let asked = try await store.messagesAfter(conversationID: chat.id, after: nil, limit: 500).first { m in
            m.parts.contains { if case .update(let u) = $0 { return u.kind == .question }; return false }
        }
        XCTAssertTrue(asked?.text.hasPrefix("For Lisbon") == true)

        // Spend by job: a job's runs, coding runs, helpers under the run that started them, a thread by its title.
        let rows = try await store.usage(from: .distantPast, to: .distantFuture)
        let jobs = await UsageJobs.resolve(Set(rows.map(\.taskID)), store: store)
        XCTAssertEqual(Set(jobs.values), ["Pennant", "Coding runs", "Company post", "Inbox drafts", "Morning brief", "Product demo", "Service check", "Team offsite in Lisbon"])
        await store.close()

        do {
            try await DemoSeed.run(paths: paths)
            XCTFail("a folder with data is never seeded over")
        } catch {}
    }
}

final class UsageJobsTests: XCTestCase {
    func testNamesAScheduledRunByItsJobAndAThreadWithoutTheRunDate() {
        XCTAssertEqual(UsageJobs.scheduledName("Scheduled job \"Inbox drafts\" (run now):\nSort the mail."), "Inbox drafts")
        XCTAssertNil(UsageJobs.scheduledName("Can you fix checkout?"))
        XCTAssertEqual(UsageJobs.threadName("⏰ Service check · Sep 30, 9:00 AM"), "Service check")
        XCTAssertEqual(UsageJobs.threadName("🎯 Grow the newsletter · Sep 30, 7:00 AM"), "Grow the newsletter")
        XCTAssertEqual(UsageJobs.threadName("Plans · Q4"), "Plans · Q4", "only the scheduler's own marks lose their date")
    }
}

final class DecisionNoteTests: XCTestCase {
    func testReadsTheHostsDecisionMessagesAndNothingElse() {
        let approved = DecisionNote(text: "Decision on \"LinkedIn post: Harbor 2.0 is live\": APPROVED (approval_id X). Publish with this approval_id.")
        XCTAssertEqual(approved?.title, "LinkedIn post: Harbor 2.0 is live")
        XCTAssertEqual(approved?.verdict, .approved)
        XCTAssertEqual(DecisionNote(text: "Decision on \"Post\": REJECTED (approval_id X). Do not publish.")?.verdict, .rejected)
        XCTAssertEqual(DecisionNote(text: "Changes requested on \"Post\" (approval_id X): shorter. Revise the draft.")?.verdict, .changesRequested)
        XCTAssertNil(DecisionNote(text: "Decision on the launch: let's wait"), "what a person writes stays a message")
        XCTAssertNil(DecisionNote(text: "Hello"))
    }
}

final class ApproveLabelTests: XCTestCase {
    func testTheButtonSaysWhatApprovingDoes() {
        func card(_ title: String, _ destination: String) -> ApprovalRequest { ApprovalRequest(taskID: TaskID(), title: title, destination: destination, text: "x") }
        XCTAssertEqual(card("LinkedIn post: launch", "LinkedIn · Harbor company page").approveButtonLabel, "Approve & post")
        XCTAssertEqual(card("Reply to Jonas", "Outlook · reply to Jonas").approveButtonLabel, "Approve & send")
        XCTAssertEqual(card("Message Sam on Telegram", "Telegram · Sam").approveButtonLabel, "Approve & send")
        XCTAssertEqual(card("Reconnect Cloudflare WARP to restore cluster visibility", "Infrastructure change (AKS, Cloudflare)").approveButtonLabel, "Approve")
        XCTAssertEqual(card("Scale the API to 3 replicas", "AKS · prod").approveButtonLabel, "Approve")
        var own = card("Deploy 2.3", "prod"); own.approveLabel = "Approve & deploy"
        XCTAssertEqual(own.approveButtonLabel, "Approve & deploy")
        var withImages = card("Carousel", "Somewhere"); withImages.images = [ImageRef(artifactID: ArtifactID())]
        XCTAssertEqual(withImages.approveButtonLabel, "Approve & post")
    }
}
