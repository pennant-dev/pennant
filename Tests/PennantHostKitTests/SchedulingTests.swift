import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class CronScheduleTests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/Lisbon")!
    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    func text(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm EEE"
        return f.string(from: d)
    }

    func testIntervalsAndPhrases() throws {
        let now = date("2026-09-22 10:07")
        XCTAssertEqual(text(try CronSchedule.parse("every 15m", timeZone: tz).next(after: now)!), "2026-09-22 10:22 Tue")
        XCTAssertEqual(text(try CronSchedule.parse("every 2 hours", timeZone: tz).next(after: now)!), "2026-09-22 12:07 Tue")
        XCTAssertEqual(text(try CronSchedule.parse("hourly", timeZone: tz).next(after: now)!), "2026-09-22 11:00 Tue")
        XCTAssertEqual(text(try CronSchedule.parse("daily at 09:00", timeZone: tz).next(after: now)!), "2026-09-23 09:00 Wed")
        XCTAssertEqual(text(try CronSchedule.parse("weekdays at 08:30", timeZone: tz).next(after: date("2026-09-25 09:00"))!), "2026-09-28 08:30 Mon")
        XCTAssertEqual(text(try CronSchedule.parse("weekly on mon,thu at 18:00", timeZone: tz).next(after: now)!), "2026-09-24 18:00 Thu")
        XCTAssertEqual(text(try CronSchedule.parse("monthly on 1 at 07:00", timeZone: tz).next(after: now)!), "2026-10-01 07:00 Thu")
        XCTAssertEqual(text(try CronSchedule.parse("once at 2026-10-01 09:00", timeZone: tz).next(after: now)!), "2026-10-01 09:00 Thu")
        XCTAssertNil(try CronSchedule.parse("once at 2026-01-01 09:00", timeZone: tz).next(after: now))
    }

    func testCronFields() throws {
        let now = date("2026-09-22 10:07")
        XCTAssertEqual(text(try CronSchedule.parse("0 9 * * 1-5", timeZone: tz).next(after: now)!), "2026-09-23 09:00 Wed")
        XCTAssertEqual(text(try CronSchedule.parse("*/20 * * * *", timeZone: tz).next(after: now)!), "2026-09-22 10:20 Tue")
        XCTAssertEqual(text(try CronSchedule.parse("30 6 1,15 * *", timeZone: tz).next(after: now)!), "2026-10-01 06:30 Thu")
        XCTAssertEqual(text(try CronSchedule.parse("0 12 * jan mon", timeZone: tz).next(after: now)!), "2027-01-04 12:00 Mon")
        XCTAssertThrowsError(try CronSchedule.parse("0 25 * * *", timeZone: tz))
        XCTAssertThrowsError(try CronSchedule.parse("whenever", timeZone: tz))
        XCTAssertThrowsError(try CronSchedule.parse("daily at 9", timeZone: tz))
        let preview = try CronSchedule.parse("daily at 09:00", timeZone: tz).preview(after: now, count: 3).map(text)
        XCTAssertEqual(preview, ["2026-09-23 09:00 Wed", "2026-09-24 09:00 Thu", "2026-09-25 09:00 Fri"])
    }

    /// A skill's report card is for its scheduled run, not for someone asking the same thing in a chat.
    func testOnlyScheduledRunsAreSentBackForAReportCard() {
        XCTAssertTrue(Scheduler.isScheduledRun("Scheduled job \"Architecture · weekly review\":\nReview the code."))
        XCTAssertTrue(Scheduler.isScheduledRun("A work session on the goal \"Platform feature proposals\".\n\nFollow the skill \"architecture-review\" (id x, v4): call use_skill first."))
        XCTAssertFalse(Scheduler.isScheduledRun("Which service runs OpenTofu for a deployment?"))
        XCTAssertFalse(Scheduler.isScheduledRun("Follow the skill \"architecture-review\" and tell me how deploys work"))
    }
}

final class SkillImporterTests: XCTestCase {
    func testImportsSkillFoldersWithFrontMatterStepsAndScripts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        let a = root.appendingPathComponent("deploy-site")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try """
        ---
        name: Deploy the site
        description: Build and publish the marketing site.
        allowed-tools: Bash(npm:*)
        ---
        # Deploy

        Use this when the site changed.

        1. Run `npm run build`.
        2. Run `scripts/publish.sh`.
        3. Check the live URL.
        """.write(to: a.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho publish\n".write(to: a.appendingPathComponent("scripts/publish.sh"), atomically: true, encoding: .utf8)
        let b = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try "No front matter here.\n\nJust prose instructions for taking notes.".write(to: b.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        let store = try SQLiteStore(paths: paths)
        let bus = EventBus()
        let first = await SkillImporter.importAll(path: root.path, store: store, eventBus: bus, workingDirectory: root.path)
        XCTAssertEqual(first.skills.count, 2, first.warnings.joined(separator: "; "))
        let deploy = try XCTUnwrap(first.skills.first { $0.name == "Deploy the site" })
        XCTAssertEqual(deploy.origin, "imported")
        XCTAssertEqual(deploy.purpose, "Build and publish the marketing site.")
        XCTAssertEqual(deploy.steps.map(\.instruction), ["Run `npm run build`.", "Run `scripts/publish.sh`.", "Check the live URL."])
        XCTAssertEqual(deploy.scripts["scripts/publish.sh"], "#!/bin/sh\necho publish\n", "keys: \(deploy.scripts.keys.sorted())")
        XCTAssertTrue(deploy.body.contains("Use this when the site changed."))
        XCTAssertTrue(deploy.prerequisites.first?.contains("Bash(npm:*)") ?? false)
        let notes = try XCTUnwrap(first.skills.first { $0.name == "notes" })
        XCTAssertEqual(notes.purpose, "No front matter here.")
        XCTAssertEqual(notes.steps.count, 1)
        // Re-import: unchanged skills are skipped; a changed one becomes a new version.
        let again = await SkillImporter.importAll(path: root.path, store: store, eventBus: bus, workingDirectory: root.path)
        XCTAssertEqual(again.skills.count, 0)
        XCTAssertEqual(again.warnings.count, 2)
        try "---\nname: Deploy the site\ndescription: v2\n---\n1. New step.".write(to: a.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let third = await SkillImporter.importAll(path: a.path, store: store, eventBus: bus, workingDirectory: root.path)
        XCTAssertEqual(third.skills.first?.version, 2)
        XCTAssertEqual(third.skills.first?.previousVersionID, deploy.id)
        let found = try await store.searchSkills(text: "publish marketing site", limit: 5)
        XCTAssertFalse(found.isEmpty)
        await store.close()
    }
}

final class SchedulerTests: XCTestCase {
    func testJobFiresCreatesTaskAndRecordsOutcome() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let provider = ScriptedProvider([.init(text: "Checked the inbox: nothing new."), .init(text: "Second run done.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let service = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await service.start(startAPI: false)
        let agents = try await service.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        // Built-in skills were seeded.
        let skills = try await service.store.listSkills(includeDisabled: true)
        XCTAssertGreaterThanOrEqual(skills.filter { $0.origin == "builtin" }.count, 5)
        let job = try await service.scheduler.upsert(ScheduledJob(name: "Inbox check", agentID: agent.id, prompt: "Check the inbox and report.", schedule: "every 15m"))
        XCTAssertNotNil(job.nextRunAt)
        XCTAssertGreaterThan(job.nextRunAt!, Date().addingTimeInterval(14 * 60))
        // Run it now: a task starts in the job's own conversation.
        let ran = try await service.scheduler.runNow(job.id)
        XCTAssertEqual(ran.runCount, 1)
        let taskID = try XCTUnwrap(ran.lastTaskID)
        let conversationID = try XCTUnwrap(ran.conversationID)
        let deadline = Date().addingTimeInterval(10)
        var done: TaskRecord?
        while Date() < deadline { if let t = try await service.store.task(taskID), t.state.isTerminal { done = t; break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(done?.state, .completed)
        let convo = try await service.store.conversation(conversationID)
        XCTAssertTrue(convo?.title.hasPrefix("⏰ Inbox check · ") ?? false, "each run has a thread of its own, named with when it ran: \(convo?.title ?? "nil")")
        let kickoff = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 5).first
        XCTAssertTrue(kickoff?.text.contains("Scheduled job \"Inbox check\"") ?? false)
        // The outcome is recorded from the task's result.
        var recorded: ScheduledJob?
        let deadline2 = Date().addingTimeInterval(5)
        while Date() < deadline2 { if let j = try await service.store.schedule(job.id), j.lastOutcome?.hasPrefix("completed") == true { recorded = j; break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(recorded?.lastOutcome?.contains("nothing new") ?? false, recorded?.lastOutcome ?? "nil")
        // Nothing but a line of text: the run's thread closes itself.
        var closedAt: Date?
        for _ in 0..<400 { closedAt = try await service.store.conversation(conversationID)?.closedAt; if closedAt != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(closedAt, "a quiet run tidies itself away")
        // Due detection: a job whose next run is in the past is picked up by the tick.
        let stored = try await service.store.schedule(job.id)
        var due = try XCTUnwrap(stored)
        due.nextRunAt = Date().addingTimeInterval(-1)
        try await service.store.upsertSchedule(due)
        let dueJobs = try await service.store.dueSchedules(before: Date())
        XCTAssertEqual(dueJobs.map(\.id), [job.id])
        // Invalid expressions are rejected at upsert.
        do { _ = try await service.scheduler.upsert(ScheduledJob(name: "bad", agentID: agent.id, prompt: "x", schedule: "sometimes")); XCTFail("expected an error") } catch {}
        // Deleting removes it.
        try await service.scheduler.delete(job.id)
        let remaining = try await service.store.listSchedules()
        XCTAssertTrue(remaining.isEmpty)
        await service.stop()
    }

    /// A run with something to read (a report card) keeps its thread in the list.
    func testARunWithAReportStaysOpen() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let post = ToolCall(id: ToolCallID("r1"), name: "post_report", arguments: ["title": "Stage dispatcher fixed", "verdict": "Fixed", "status": "warning",
                                                                                   "sections": .array([.object(["stats": .array([.object(["label": "Restarts", "value": "6"])])])])])
        let provider = ScriptedProvider([.init(toolCalls: [post]), .init(text: "Fixed and reported.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let service = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await service.start(startAPI: false)
        let agents = try await service.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let job = try await service.scheduler.upsert(ScheduledJob(name: "Hourly check", agentID: agent.id, prompt: "Check the clusters.", schedule: "every 60m"))
        let ran = try await service.scheduler.runNow(job.id)
        let taskID = try XCTUnwrap(ran.lastTaskID), conversationID = try XCTUnwrap(ran.conversationID)
        for _ in 0..<400 { if let j = try await service.store.schedule(job.id), j.lastOutcome?.hasPrefix("completed") == true { break }; try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        let state = try await service.store.task(taskID)?.state
        XCTAssertEqual(state, .completed)
        let closedAt = try await service.store.conversation(conversationID)?.closedAt
        XCTAssertNil(closedAt, "a run with a report stays in the list")
        await service.stop()
    }

    func testTheScheduleToolMakesAJobOfItsOwn() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let schedule = ToolCall(id: ToolCallID("s1"), name: "schedule_job", arguments: ["name": "Morning brief", "schedule": "weekdays at 08:00", "prompt": "Summarise overnight news."])
        let provider = ScriptedProvider([.init(toolCalls: [schedule]), .init(text: "Set up a morning brief.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let service = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await service.start(startAPI: false)
        let agents = try await service.store.listAgents(includeRetired: false)
        let pennant = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "Brief me every weekday morning.", attachments: [])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if let t = try await service.store.task(taskID), t.state.isTerminal { break }; try await Task.sleep(for: .milliseconds(30)) }
        let jobs = try await service.store.listSchedules()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.agentID, pennant.id)
        XCTAssertEqual(jobs.first?.createdByAgentID, pennant.id)
        XCTAssertEqual(jobs.first?.schedule, "weekdays at 08:00")
        let records = try await service.store.toolRecords(taskID: taskID)
        XCTAssertEqual(records.map { $0.status }, [.succeeded])
        await service.stop()
    }
}
