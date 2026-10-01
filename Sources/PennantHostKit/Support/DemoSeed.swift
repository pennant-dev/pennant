import PennantCore
import Foundation

/// A fictional host for screenshots, the site and demo films: `pennant-host --root <empty folder> --seed-demo`.
/// One agent, Pennant, and the jobs it runs for Maya Okafor in the week Harbor 2.0 launches (the same invented company
/// as the Binders demo): scheduled jobs that each run in a thread of their own, a coding run under the thread that
/// asked for it, helpers on a product demo, cards waiting, reports, memory and the usage ledger.
/// The seeded host listens on 127.0.0.1:7431 only, doesn't advertise itself, and has no reachable model, so nothing
/// in it runs on its own: work shown in progress is paused mid-task, exactly as the app draws it while it works.
public enum DemoSeed {
    public static let port = 7431

    public static func run(paths: HostPaths, now: Date = Date()) async throws {
        try paths.ensureDirectories()
        guard (try? FileManager.default.contentsOfDirectory(atPath: paths.root.path).filter { !["artifacts", "skills", "logs", "host.lock"].contains($0) }.isEmpty) ?? true,
              !FileManager.default.fileExists(atPath: paths.databaseURL.path) else {
            throw DemoSeedError.notEmpty(paths.root.path)
        }

        let codeFolder = (NSHomeDirectory() as NSString).appendingPathComponent("code/harbor-web")
        let gitHubApp = GitHubAppIdentity(appID: 1_000_001, installationID: 2_000_002, vaultEntry: "harbor-pennant-app", slug: "harbor-pennant")
        var config = HostConfig()
        config.api = .init(port: port, listenOnNetwork: false, advertiseBonjour: false, tlsPort: port + 1)
        config.inference.baseURL = "http://127.0.0.1:9/v1"
        config.inference.model = "deepseek-v4.1-flash"
        let apiFolder = (NSHomeDirectory() as NSString).appendingPathComponent("code/harbor-api")
        config.coding = HostConfig.Coding(engine: .claudeCode, projects: [CodingProject(path: codeFolder), CodingProject(path: apiFolder)], gitHubApp: gitHubApp)
        try ConfigLoader.save(config, to: paths.configURL)

        let people = PeopleService(paths: paths)
        let owner = try await people.ownerAccount(defaultName: "Maya Okafor")
        let me = MessageAuthor(id: owner.id, name: owner.name)

        let store = try SQLiteStore(paths: paths)
        defer { Task { await store.close() } }
        let calendar = Calendar.current
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        /// The latest time a job set for `hour:minute` fired, at least ten minutes ago (weekdays only for weekday jobs).
        func lastFire(_ hour: Int, _ minute: Int = 0, weekdays: Bool = true, weekday: Int? = nil) -> Date {
            var day = now.addingTimeInterval(-600)
            for _ in 0 ..< 14 {
                if let d = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), d <= now.addingTimeInterval(-600) {
                    let wd = calendar.component(.weekday, from: d)
                    if let weekday { if wd == weekday { return d } } else if !weekdays || !(wd == 1 || wd == 7) { return d }
                }
                day = calendar.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86_400)
            }
            return now.addingTimeInterval(-86_400)
        }
        /// The first time after the pictures are taken: nothing fires while they are.
        func nextFire(_ hour: Int, _ minute: Int = 0) -> Date {
            var d = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            while d <= now.addingTimeInterval(1800) { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400) }
            return d
        }
        func runTitle(_ job: String, _ fired: Date) -> String { "⏰ \(job) · \(fired.formatted(.dateTime.month(.abbreviated).day().hour().minute()))" }

        // MARK: Pennant, the one agent

        let pennant = AgentProfile(name: HostService.defaultAgentName, role: HostService.defaultAgentRole, style: "calm, concise, and precise; says what was verified",
                                   instructions: "Each job has a skill: follow it. Code changes go to a coding run (the code tool) in ~/code/harbor-web.",
                                   avatar: "flag:compass", accentColorHex: "#2F80ED")
        try await store.upsertAgent(pennant)

        // MARK: Helpers

        func thread(_ title: String, preview: String = "", created: Date, updated: Date, closed: Date? = nil, parent: ConversationID? = nil) async throws -> Conversation {
            var c = Conversation(agentID: pennant.id, title: title, preview: preview, createdAt: created, updatedAt: updated)
            c.closedAt = closed
            c.parentID = parent
            try await store.upsertConversation(c)
            return c
        }
        func say(_ c: Conversation, _ task: TaskRecord?, _ role: MessageRole, _ parts: [ContentPart], _ when: Date, author: MessageAuthor? = nil) async throws {
            try await store.appendMessage(Message(conversationID: c.id, agentID: pennant.id, taskID: task?.id, role: role, parts: parts, createdAt: when, author: author))
        }
        func ask(_ c: Conversation, _ task: TaskRecord?, _ text: String, _ when: Date) async throws { try await say(c, task, .user, [.text(text)], when, author: me) }
        /// A tool call and its result, as the runtime writes them (with its record, so the step shows its time).
        func tool(_ c: Conversation, _ task: TaskRecord, _ name: String, _ arguments: [String: JSONValue], result: String, at when: Date, seconds: Double = 2, text: String? = nil) async throws {
            let call = ToolCall(name: name, arguments: .object(arguments))
            try await say(c, task, .assistant, (text.map { [ContentPart.text($0)] } ?? []) + [.toolCall(call)], when)
            try await say(c, task, .tool, [.toolResult(ToolResult.text(call.id, name: name, result))], when.addingTimeInterval(seconds))
            try await store.upsertToolRecord(ToolRecord(taskID: task.id, agentID: task.agentID, call: call, status: .succeeded, resultSummary: String(result.prefix(200)),
                                                        startedAt: when, finishedAt: when.addingTimeInterval(seconds)))
        }
        func task(_ c: Conversation, _ title: String, objective: String? = nil, agent: AgentProfile? = nil, state: TaskState, reason: String = "", started: Date, finished: Date? = nil,
                  steps: Int, input: Int, output: Int, summary: String? = nil, parent: TaskID? = nil, requestedBy: TaskID? = nil) async throws -> TaskRecord {
            var t = TaskRecord(agentID: (agent ?? pennant).id, conversationID: c.id, parentTaskID: parent, title: title, objective: objective ?? title,
                               usage: TaskUsage(steps: steps, inputTokens: input, outputTokens: output, startedAt: started),
                               state: state, stateReason: reason, resultSummary: summary, createdAt: started, updatedAt: finished ?? now, finishedAt: finished)
            t.requestedByTaskID = requestedBy
            t.usage.startedAt = started
            try await store.upsertTask(t)
            return t
        }
        /// What a run cost, in the ledger: Pennant's own model, the helpers' local model, or Claude Code.
        enum Model { case lead, helper, coding }
        func spend(_ t: TaskRecord, _ model: Model, at when: Date, input: Int, cached: Int, output: Int, calls: Int = 1) async throws {
            for i in 0 ..< max(1, calls) {
                let share = Double(1) / Double(max(1, calls))
                let inp = Int(Double(input) * share), cach = Int(Double(cached) * share), out = Int(Double(output) * share)
                let at = when.addingTimeInterval(Double(i - calls) * 20)
                let record: UsageRecord
                switch model {
                case .lead:
                    let cost = (Double(inp - cach) * 0.30 + Double(cach) * 0.03 + Double(out) * 1.20) / 1_000_000
                    record = UsageRecord(at: at, agentID: t.agentID, taskID: t.id, conversationID: t.conversationID, profileID: nil, modelLabel: "DeepSeek V4.1 Flash",
                                         provider: "Azure AI Foundry", model: "deepseek-v4.1-flash", inputTokens: inp, cachedInputTokens: cach, outputTokens: out, cost: cost, estimated: false)
                case .helper:
                    record = UsageRecord(at: at, agentID: t.agentID, taskID: t.id, conversationID: t.conversationID, profileID: nil, modelLabel: "Gemma 4 · this Mac",
                                         provider: "Ollama", model: "gemma4:e2b-it-qat", inputTokens: inp, cachedInputTokens: cach, outputTokens: out, cost: 0, estimated: false)
                case .coding:
                    let cost = (Double(inp - cach) * 3.0 + Double(cach) * 0.30 + Double(out) * 15.0) / 1_000_000
                    record = UsageRecord(at: at, agentID: t.agentID, taskID: t.id, conversationID: t.conversationID, profileID: nil, modelLabel: "Claude Code",
                                         provider: "claude-code", model: "claude-code", inputTokens: inp, cachedInputTokens: cach, outputTokens: out, cost: cost, estimated: false)
                }
                try await store.appendUsage(record)
            }
        }
        func scheduled(_ job: String, _ prompt: String, manual: Bool = false) -> String { "Scheduled job \"\(job)\"\(manual ? " (run now)" : ""):\n\(prompt)" }

        // MARK: Skills: a folder each in Maya's skills repository

        func skill(_ name: String, _ purpose: String, _ steps: [String], runs: [TaskID] = []) async throws -> Skill {
            let body = "# \(name)\n\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let s = Skill(name: name, version: 3, purpose: purpose, steps: steps.map { SkillStep(instruction: $0) }, status: .validated,
                          outcomes: runs.map { SkillOutcome(taskID: $0, succeeded: true) }, createdAt: ago(60 * 24 * 21), updatedAt: ago(60 * 24 * 2),
                          origin: "imported", body: body)
            try await store.upsertSkill(s)
            return s
        }
        let briefSkill = try await skill("morning-brief", "Tell Maya what needs her today: calendar, inbox and open threads.", [
            "Read today's calendar and anything new in the inbox since yesterday evening.", "List the open threads that wait on Maya.", "Finish with the report: what needs her, in order."])
        let inboxSkill = try await skill("inbox-drafts", "Triage the inbox and draft a reply to everything a person wrote.", [
            "Read unread mail from the last 24 hours.", "Archive newsletters and receipts.", "Draft a reply in Maya's voice and put it up as a card; never send without her yes.", "Finish with the report."])
        let postSkill = try await skill("company-post", "Write the day's post for the Harbor company page and ask before publishing.", [
            "Pick one thing Harbor does that the last three posts didn't cover.", "Write the post: the reader's problem first, then what Harbor does. Under 120 words, two hashtags at most.",
            "Put it up as a card; publish only once Maya approves."])
        let demoSkill = try await skill("product-demo", "Script, record, narrate and cut a product demo, then fill in every upload field.", [
            "Write the storyboard and the narration.", "Record each scene in the demo workspace.", "Narrate, cut and caption.", "Put the upload up as a card."])
        let checkSkill = try await skill("service-check", "Check the API, the web app and the import queue, and report only what changed.", [
            "Check each service's health and latency.", "Compare with the last run.", "If something is off, report it with the numbers; otherwise say so in one line."])

        // MARK: Harbor launch: Maya's own thread with Pennant

        let harbor = try await thread("Harbor 2.0 launch", preview: "I've started a coding run in harbor-web.", created: ago(6 * 60), updated: ago(20))
        let planTask = try await task(harbor, "Run the Harbor 2.0 launch", state: .completed, started: ago(6 * 60), finished: ago(6 * 60 - 4), steps: 6, input: 64_000, output: 2_900,
                                      summary: "Launch plan set: the post, the beta list, the checks and the flaky test.")
        try await ask(harbor, planTask, "Harbor 2.0 goes live today. Get the post out on the company page, answer the beta list, keep an eye on the services, and tell me if anything breaks.", ago(6 * 60))
        try await say(harbor, planTask, .assistant, [.text("""
        On it. Here's the day:

        1. **Company post** drafts the launch post for the Harbor page at 9:30. It waits for your approval before anything is published.
        2. **Inbox drafts** answers the 38 beta sign-ups and drafts a reply to Jonas about the partner rollout for you to check.
        3. **Service check** watches the API, the web app and the import queue every hour, and I'll tell you if anything is off.
        4. The flaky 50k import test gets a coding run once the launch is out.
        """)], ago(6 * 60 - 3))
        try await spend(planTask, .lead, at: ago(6 * 60 - 3), input: 64_000, cached: 41_000, output: 2_900, calls: 3)

        let recallTask = try await task(harbor, "What did I promise Jonas, and by when?", state: .completed, started: ago(95), finished: ago(94), steps: 2, input: 38_000, output: 700,
                                        summary: "The final launch checklist, by Friday.")
        try await ask(harbor, recallTask, "What did I promise Jonas, and by when?", ago(95))
        try await tool(harbor, recallTask, "memory_search", ["query": .string("promise Jonas Lindqvist")], result: """
        Facts:
        [1] Jonas Lindqvist (person): Head of Partnerships at Northwind. Maya promised him the final launch checklist by Friday. Asserted by Maya.
        [2] Northwind (organization): Harbor's largest partner.
        Passages:
        [3] Maya, in Teams, Tue: "Jonas, the final launch checklist is yours by Friday, with Tomás's import numbers in it."
        [4] Northwind sync notes, Mon: "Action: send Jonas the launch checklist before go-live."
        """, at: ago(95), seconds: 0.4)
        try await say(harbor, recallTask, .assistant, [.text("You promised Jonas the final launch checklist **by Friday**, with Tomás's import numbers in it. You told him in Teams on Tuesday, and it's an action from Monday's Northwind sync.")], ago(94))
        try await spend(recallTask, .lead, at: ago(94), input: 38_000, cached: 30_000, output: 700, calls: 2)

        let request = "Checkout has failed in Safari since this morning's 9:05 release. Find the cause in harbor-web, fix it with a test, and open a pull request; don't merge."
        let fixTask = try await task(harbor, "Checkout has failed in Safari since this morning's release", objective: "Checkout has failed in Safari since this morning's release. Can you fix it? Open a pull request, don't merge.",
                                     state: .completed, started: ago(24), finished: ago(22), steps: 2, input: 29_000, output: 900, summary: "Started a coding run in harbor-web.")
        try await ask(harbor, fixTask, "Checkout has failed in Safari since this morning's release. Can you fix it? Open a pull request, don't merge.", ago(24))

        // The coding run: its own thread under this one, handed to Claude Code in harbor-web, the default project.
        var coding = Conversation(agentID: pennant.id, title: TaskRuntime.title(from: request), preview: "Pull request #412 is up.", createdAt: ago(23), updatedAt: ago(4))
        coding.engine = .claudeCode
        coding.parentID = harbor.id
        coding.workingDirectory = codeFolder
        coding.engineSessionID = "5b0e7c2a-demo-4c1e-9a55-harbor000412"
        try await store.upsertConversation(coding)
        let codeTask = try await task(coding, TaskRuntime.title(from: request), objective: request, state: .waitingForUser, reason: "Waiting for your approval: Delete: run a command",
                                      started: ago(23), steps: 14, input: 612_000, output: 21_400, requestedBy: fixTask.id)
        let startCall = ToolCall(name: "code", arguments: .object(["request": .string(request), "folder": .string("~/code/harbor-web")]))
        try await say(harbor, fixTask, .assistant, [.toolCall(startCall)], ago(23.5))
        try await say(harbor, fixTask, .tool, [.toolResult(ToolResult.text(startCall.id, name: "code",
            "Coding run started (task \(codeTask.id.rawValue), thread \(coding.id.rawValue)). Call await_task with the task id for the result; pass the thread id to follow up."))], ago(23))
        try await store.upsertToolRecord(ToolRecord(taskID: fixTask.id, agentID: pennant.id, call: startCall, status: .succeeded, resultSummary: "Coding run started", startedAt: ago(23.5), finishedAt: ago(23)))
        try await say(harbor, fixTask, .assistant, [.text("I've started a coding run in harbor-web. It works in its own thread under this one; I'll bring you the pull request when it's up.")], ago(22))
        try await spend(fixTask, .lead, at: ago(22), input: 29_000, cached: 24_000, output: 900, calls: 2)

        let file = codeFolder + "/src/checkout/PayButton.tsx"
        try await say(coding, codeTask, .user, [.text(request)], ago(23))
        try await tool(coding, codeTask, "Grep", ["pattern": .string("window.open"), "path": .string("src/checkout")],
                       result: "src/checkout/PayButton.tsx:41:    const popup = window.open(session.url, \"harbor-pay\")", at: ago(22.5), seconds: 1, text: "Starting with how the pay button opens the payment page.")
        try await tool(coding, codeTask, "Read", ["file_path": .string(file)], result: """
            36  async function onPay() {
            37    setBusy(true)
            38    const session = await createCheckoutSession(cart)
            39    // Opened after the await: Safari no longer counts it as coming from the click.
            41    const popup = window.open(session.url, "harbor-pay")
            """, at: ago(21.5), seconds: 1)
        try await tool(coding, codeTask, "Edit", ["file_path": .string(file), "old_string": .string("const popup = window.open(session.url, \"harbor-pay\")"),
                                                  "new_string": .string("window.location.assign(session.url)")],
                       result: "The file \(file) has been updated.", at: ago(19), seconds: 1,
                       text: "Found it. Since 9:05 the button creates the checkout session first and opens the payment page after that await, so Safari blocks it as a pop-up. Opening it in the same tab fixes it.")
        try await tool(coding, codeTask, "Write", ["file_path": .string(codeFolder + "/e2e/checkout-safari.spec.ts")],
                       result: "File created successfully at: \(codeFolder)/e2e/checkout-safari.spec.ts", at: ago(17), seconds: 1)
        try await tool(coding, codeTask, "Bash", ["command": .string("npm test -- checkout && npx playwright test e2e/checkout-safari.spec.ts --project=webkit"), "description": .string("Run the checkout tests, and the new one in WebKit")],
                       result: "Tests: 48 passed, 48 total\n\nRunning 1 test using 1 worker\n  ✓ checkout-safari.spec.ts › pay opens the payment page (4.1s)\n  1 passed", at: ago(15), seconds: 38)
        try await tool(coding, codeTask, "Bash", ["command": .string("git switch -c fix/safari-pay-button && git commit -am \"Open the payment page in the same tab so Safari doesn't block it\" && git push -u origin fix/safari-pay-button"),
                                                  "description": .string("Commit and push the fix as harbor-pennant")],
                       result: "branch 'fix/safari-pay-button' set up to track 'origin/fix/safari-pay-button'.", at: ago(11), seconds: 4)
        try await tool(coding, codeTask, "Bash", ["command": .string("gh pr create --fill --base main"), "description": .string("Open the pull request")],
                       result: "https://github.com/harbor-example/harbor-web/pull/412", at: ago(9), seconds: 3)
        try await say(coding, codeTask, .assistant, [.text("Pull request #412 is up as harbor-pennant[bot]: the pay button opens the payment page in the same tab, with a WebKit test for it. The branch from the old pop-up workaround (#398, closed) is stale now, so I'd like to delete it.")], ago(5))
        var cleanup = ApprovalRequest(taskID: codeTask.id, title: "Delete: run a command", destination: "Coding · ~/code/harbor-web", text: "git push origin --delete fix/safari-popup-workaround",
                                      notes: "Delete the stale branch of the old pop-up workaround; its pull request #398 was closed in favour of #412.", createdAt: ago(4))
        cleanup.details = [ApprovalDetail(label: "Tool", value: "Bash")]
        cleanup.approveLabel = "Allow"
        cleanup.allowRestLabel = "Allow for the rest of this task"
        try await say(coding, codeTask, .assistant, [.approval(cleanup)], ago(4))
        try await spend(codeTask, .coding, at: ago(5), input: 612_000, cached: 540_000, output: 21_400, calls: 6)

        // MARK: Company post: today's launch post, waiting for approval; yesterday's teaser, posted

        let postFired = lastFire(9, 30)
        let dayBefore = lastFire(9, 30).addingTimeInterval(-86_400)
        let teaserThread = try await thread(runTitle("Company post", dayBefore), preview: "Posted", created: dayBefore, updated: dayBefore.addingTimeInterval(1800))
        let teaserTask = try await task(teaserThread, "Company post", objective: scheduled("Company post", "Draft today's post for the Harbor company page."), state: .completed,
                                        started: dayBefore, finished: dayBefore.addingTimeInterval(1700), steps: 7, input: 30_000, output: 1_600, summary: "Teaser posted after approval.")
        var teaser = ApprovalRequest(taskID: teaserTask.id, title: "LinkedIn post: launch teaser", destination: "Harbor · LinkedIn company page",
                                     text: "Tomorrow, imports get fast. Really fast. Harbor 2.0 lands at 9 AM Pacific.", headline: "Tomorrow, imports get fast",
                                     state: .approved, createdAt: dayBefore.addingTimeInterval(600), decidedAt: dayBefore.addingTimeInterval(1500),
                                     publishedURL: "https://www.linkedin.com/company/harbor-example/")
        teaser.decidedBy = me
        try await say(teaserThread, teaserTask, .user, [.text(scheduled("Company post", "Draft today's post for the Harbor company page."))], dayBefore)
        try await say(teaserThread, teaserTask, .assistant, [.text("A one-line teaser for tomorrow's launch:"), .approval(teaser)], dayBefore.addingTimeInterval(600))
        try await spend(teaserTask, .lead, at: dayBefore.addingTimeInterval(600), input: 30_000, cached: 21_000, output: 1_600, calls: 3)

        let postThread = try await thread(runTitle("Company post", postFired), preview: "Waiting for your approval", created: postFired, updated: postFired.addingTimeInterval(420))
        let postTask = try await task(postThread, "Company post", objective: scheduled("Company post", "Draft today's post for the Harbor company page."), state: .completed,
                                      started: postFired, finished: postFired.addingTimeInterval(420), steps: 9, input: 41_000, output: 2_100, summary: "The launch post is up for approval.")
        try await say(postThread, postTask, .user, [.text(scheduled("Company post", "Draft today's post for the Harbor company page."))], postFired)
        try await tool(postThread, postTask, "use_skill", ["skill_id": .string("company-post")], result: "Following company-post v3: 3 steps.", at: postFired.addingTimeInterval(20), seconds: 0.2)
        try await tool(postThread, postTask, "read_file", ["path": .string("~/Harbor/release-notes/2.0.md")], result: "Harbor 2.0: imports rebuilt (50k rows in 4 min), shared views, annual plans.", at: postFired.addingTimeInterval(60), seconds: 0.3)
        try await say(postThread, postTask, .assistant, [.text("Launch day, so the post leads with the import speed-up. It goes out as soon as you approve it."),
            .approval(ApprovalRequest(taskID: postTask.id, title: "LinkedIn post: Harbor 2.0 is live", destination: "Harbor · LinkedIn company page",
                text: """
                Harbor 2.0 is live. 🚢

                Imports that took an afternoon now take four minutes. We rebuilt the pipeline from the ground up, so 50,000 rows arrive while your coffee is still hot.

                Also new: shared views for your whole team, and a pricing page with annual plans.

                Thank you to the 400 beta testers who broke it before you could. Release notes: harbor.example/2-0
                """,
                headline: "Harbor 2.0 is live", tags: ["#launch", "#productupdate"],
                details: [ApprovalDetail(label: "When", value: "As soon as you approve"), ApprovalDetail(label: "Length", value: "74 words")],
                notes: "Kept to two hashtags and under 120 words, as you prefer.", createdAt: postFired.addingTimeInterval(400)))], postFired.addingTimeInterval(400))
        try await spend(postTask, .lead, at: postFired.addingTimeInterval(400), input: 41_000, cached: 29_000, output: 2_100, calls: 4)

        // MARK: Inbox drafts: the latest run has a reply waiting and a report; the one before was all handled

        let inboxTimes = [(8, 30), (12, 30), (17, 30)].map { lastFire($0.0, $0.1) }.sorted(by: >)
        let inboxFired = inboxTimes[0], inboxEarlier = inboxTimes[1]
        let mailThread = try await thread(runTitle("Inbox drafts", inboxFired), preview: "One reply needs you", created: inboxFired, updated: inboxFired.addingTimeInterval(540))
        let mailTask = try await task(mailThread, "Inbox drafts", objective: scheduled("Inbox drafts", "Sort the new mail, archive the noise and draft the replies that need Maya."), state: .completed,
                                      started: inboxFired, finished: inboxFired.addingTimeInterval(540), steps: 14, input: 96_000, output: 7_800, summary: "14 read, 36 beta replies sent from the approved template, 1 reply waiting.")
        try await say(mailThread, mailTask, .user, [.text(scheduled("Inbox drafts", "Sort the new mail, archive the noise and draft the replies that need Maya."))], inboxFired)
        try await tool(mailThread, mailTask, "use_skill", ["skill_id": .string("inbox-drafts")], result: "Following inbox-drafts v3: 4 steps.", at: inboxFired.addingTimeInterval(15), seconds: 0.2)
        try await tool(mailThread, mailTask, "microsoft_365__mail_search", ["folder": .string("inbox"), "unread": .bool(true)], result: "14 messages: Jonas Lindqvist (Northwind), 38 beta sign-ups (one thread), 11 newsletters, 2 receipts.", at: inboxFired.addingTimeInterval(40), seconds: 3)
        try await say(mailThread, mailTask, .assistant, [.text("Jonas asked when Northwind can switch on shared views. Here's a reply for you to check:"),
            .approval(ApprovalRequest(taskID: mailTask.id, title: "Reply to Jonas Lindqvist", destination: "Outlook · reply to Jonas Lindqvist (Northwind)",
                text: """
                Hi Jonas,

                Shared views are live for every Northwind workspace from today. Priya's team can turn them on under Settings › Views; nothing to install.

                I'll send the final launch checklist on Friday, as promised. Shall we walk through the partner rollout on Thursday at 3?

                Best,
                Maya
                """,
                details: [ApprovalDetail(label: "Subject", value: "Re: Shared views for Northwind")],
                notes: "Mentions the Friday checklist you promised him in Teams on Tuesday.", createdAt: inboxFired.addingTimeInterval(420)))], inboxFired.addingTimeInterval(420))
        try await say(mailThread, mailTask, .assistant, [.report(ReportCard(
            title: "Inbox · \(inboxFired.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))", subtitle: "Outlook · since the last run",
            verdict: "One reply needs you.", status: .watch,
            sections: [
                ReportSection(stats: [ReportStat(label: "Read", value: "14"), ReportStat(label: "Drafted", value: "1", status: .watch), ReportStat(label: "Archived", value: "13", status: .good)]),
                ReportSection(table: ReportTable(columns: ["From", "Subject", "Status"], rows: [
                    [ReportCell("Jonas Lindqvist"), ReportCell("Shared views for Northwind"), ReportCell("Waiting for you", status: .watch)],
                    [ReportCell("Beta sign-ups (38)"), ReportCell("Harbor 2.0 beta"), ReportCell("Answered with the launch note", status: .good)],
                ])),
            ], createdAt: inboxFired.addingTimeInterval(540)))], inboxFired.addingTimeInterval(540))
        try await spend(mailTask, .lead, at: inboxFired.addingTimeInterval(540), input: 96_000, cached: 71_000, output: 7_800, calls: 6)

        let earlierThread = try await thread(runTitle("Inbox drafts", inboxEarlier), preview: "All handled", created: inboxEarlier, updated: inboxEarlier.addingTimeInterval(300))
        let earlierTask = try await task(earlierThread, "Inbox drafts", objective: scheduled("Inbox drafts", "Sort the new mail, archive the noise and draft the replies that need Maya."), state: .completed,
                                         started: inboxEarlier, finished: inboxEarlier.addingTimeInterval(300), steps: 8, input: 52_000, output: 2_400, summary: "9 read, 9 archived.")
        try await say(earlierThread, earlierTask, .user, [.text(scheduled("Inbox drafts", "Sort the new mail, archive the noise and draft the replies that need Maya."))], inboxEarlier)
        try await say(earlierThread, earlierTask, .assistant, [.report(ReportCard(
            title: "Inbox · \(inboxEarlier.formatted(.dateTime.weekday(.abbreviated).hour().minute()))", verdict: "Nothing needs you: 9 newsletters and receipts archived.", status: .good,
            sections: [ReportSection(stats: [ReportStat(label: "Read", value: "9"), ReportStat(label: "Drafted", value: "0"), ReportStat(label: "Archived", value: "9", status: .good)])],
            createdAt: inboxEarlier.addingTimeInterval(300)))], inboxEarlier.addingTimeInterval(300))
        try await spend(earlierTask, .lead, at: inboxEarlier.addingTimeInterval(300), input: 52_000, cached: 40_000, output: 2_400, calls: 4)

        // MARK: Morning brief

        let briefFired = lastFire(7, 30)
        let briefThread = try await thread(runTitle("Morning brief", briefFired), preview: "Three things need you today", created: briefFired, updated: briefFired.addingTimeInterval(240))
        let briefTask = try await task(briefThread, "Morning brief", objective: scheduled("Morning brief", "Tell Maya what needs her today."), state: .completed,
                                       started: briefFired, finished: briefFired.addingTimeInterval(240), steps: 6, input: 48_000, output: 2_200, summary: "Three things need Maya today.")
        try await say(briefThread, briefTask, .user, [.text(scheduled("Morning brief", "Tell Maya what needs her today."))], briefFired)
        try await say(briefThread, briefTask, .assistant, [.report(ReportCard(
            title: "Morning brief · \(briefFired.formatted(.dateTime.weekday(.wide)))", subtitle: "Calendar, inbox and open threads",
            verdict: "Launch day. Three things need you.", status: .watch,
            sections: [
                ReportSection(title: "Needs you", items: [ReportItem(text: "Approve the launch post before 10:00 (Company post)", status: .watch),
                                                          ReportItem(text: "Jonas's question about shared views: a reply is drafted", status: .watch),
                                                          ReportItem(text: "The final launch checklist for Jonas is due Friday", status: .neutral)]),
                ReportSection(title: "Calendar", items: [ReportItem(text: "10:30 Launch stand-up with Tomás and Delphine"), ReportItem(text: "15:00 Northwind partner call")]),
            ], createdAt: briefFired.addingTimeInterval(240)))], briefFired.addingTimeInterval(240))
        try await spend(briefTask, .lead, at: briefFired.addingTimeInterval(240), input: 48_000, cached: 36_000, output: 2_200, calls: 3)

        // MARK: Product demo: run now, with three helpers on a cheaper model

        let demoStarted = ago(38)
        let demoThread = try await thread(runTitle("Product demo", demoStarted), preview: "Splitting the prep across three helpers", created: demoStarted, updated: ago(2))
        let demoTask = try await task(demoThread, "Product demo", objective: scheduled("Product demo", "Record this week's demo: what's new in Harbor 2.0.", manual: true), state: .paused, reason: "Working",
                                      started: demoStarted, steps: 11, input: 88_000, output: 4_200)
        try await say(demoThread, demoTask, .user, [.text(scheduled("Product demo", "Record this week's demo: what's new in Harbor 2.0.", manual: true))], demoStarted)
        try await tool(demoThread, demoTask, "use_skill", ["skill_id": .string("product-demo")], result: "Following product-demo v3: 4 steps.", at: demoStarted.addingTimeInterval(15), seconds: 0.2)
        let helperJobs: [(String, String, String, TaskState, String?)] = [
            ("Write the narration script", "Script writer", "Write a 2-minute narration for the six scenes in storyboard.md, in Maya's voice (voice.md).", .completed, "412 words, six scenes; every claim is in the release notes."),
            ("Find the controls for each scene", "Scene finder", "In the demo workspace, find the button or menu each scene clicks, and note its label and place.", .completed, "18 controls found; scene 4's export button moved into the ⋯ menu."),
            ("Check the captions against the script", "Caption checker", "Compare captions.srt with script.md line by line and fix any that differ.", .paused, nil),
        ]
        var calls: [ToolCall] = []
        var results: [ContentPart] = []
        var helperTasks: [TaskRecord] = []
        for (i, (title, name, objective, state, summary)) in helperJobs.enumerated() {
            let worker = AgentProfile(kind: .worker, name: name, role: "worker for Pennant", style: pennant.style, parentAgentID: pennant.id,
                                      status: state == .completed ? .retired : .acting, statusLine: state == .completed ? "Done" : title, avatar: "shape:hexagon", accentColorHex: pennant.accentColorHex)
            try await store.upsertAgent(worker)
            let wc = Conversation(agentID: worker.id, title: title, createdAt: demoStarted.addingTimeInterval(60), updatedAt: ago(Double(10 - i * 3)))
            try await store.upsertConversation(wc)
            let started = demoStarted.addingTimeInterval(60)
            let wt = try await task(wc, title, objective: objective, agent: worker, state: state, reason: state == .completed ? "" : "Working", started: started,
                                    finished: state == .completed ? ago(Double(12 - i * 4)) : nil, steps: [9, 14, 6][i], input: [9_800, 14_200, 6_100][i], output: [1_900, 1_200, 400][i],
                                    summary: summary, parent: demoTask.id)
            try await store.appendMessage(Message(conversationID: wc.id, agentID: worker.id, taskID: wt.id, role: .user, parts: [.text("Delegated by Pennant: \(objective)")], createdAt: started))
            try await spend(wt, .helper, at: state == .completed ? ago(Double(12 - i * 4)) : ago(2), input: [9_800, 14_200, 6_100][i], cached: 0, output: [1_900, 1_200, 400][i], calls: 3)
            helperTasks.append(wt)
            let call = ToolCall(name: "delegate_task", arguments: .object(["title": .string(title), "objective": .string(objective), "worker_name": .string(name)]))
            calls.append(call)
            results.append(.toolResult(ToolResult.text(call.id, name: "delegate_task", "Delegated as task \(wt.id.rawValue). Call await_task with this id when you need the result.")))
        }
        try await say(demoThread, demoTask, .assistant, [.text("The storyboard is ready. Splitting the prep across three helpers on the local model while I set up the recording.")] + calls.map { .toolCall($0) }, demoStarted.addingTimeInterval(55))
        try await say(demoThread, demoTask, .tool, results, demoStarted.addingTimeInterval(60))
        try await spend(demoTask, .lead, at: ago(3), input: 88_000, cached: 61_000, output: 4_200, calls: 5)

        // MARK: Service check: hourly; quiet runs close themselves

        var lastCheck: (Conversation, TaskRecord)?
        for h in (1 ... 10).reversed() {
            guard let fired = calendar.date(bySetting: .minute, value: 0, of: now.addingTimeInterval(Double(-h) * 3600)) else { continue }
            let closed = fired.addingTimeInterval(95)
            let c = try await thread(runTitle("Service check", fired), preview: "All green", created: fired, updated: closed, closed: closed)
            let t = try await task(c, "Service check", objective: scheduled("Service check", "Check the API, the web app and the import queue."), state: .completed,
                                   started: fired, finished: closed, steps: 5, input: 12_000, output: 600, summary: "All green.")
            try await say(c, t, .user, [.text(scheduled("Service check", "Check the API, the web app and the import queue."))], fired)
            try await say(c, t, .assistant, [.text("All green: API 142 ms, web app 380 ms, 3 imports waiting.")], closed)
            try await spend(t, .lead, at: closed, input: 12_000, cached: 9_000, output: 600)
            lastCheck = (c, t)
        }

        // MARK: Schedules: Pennant's jobs, each pinned to its skill

        func job(_ name: String, _ skill: Skill, _ prompt: String, _ schedule: String, next: Date, last: (Conversation, TaskRecord)?, runs: Int) async throws {
            var j = ScheduledJob(name: name, agentID: pennant.id, skillID: skill.id, prompt: prompt, schedule: schedule, conversationID: last?.0.id, nextRunAt: next,
                                 lastRunAt: last?.1.createdAt, lastTaskID: last?.1.id, lastOutcome: last.map { "\($0.1.state.rawValue): \($0.1.resultSummary ?? "")" }, runCount: runs)
            j.freshConversation = true
            try await store.upsertSchedule(j)
        }
        let nextHour = calendar.date(bySetting: .minute, value: 5, of: now.addingTimeInterval(40 * 60)) ?? now.addingTimeInterval(3600)
        try await job("Morning brief", briefSkill, "Tell Maya what needs her today.", "weekdays at 07:30", next: nextFire(7, 30), last: (briefThread, briefTask), runs: 58)
        try await job("Inbox drafts", inboxSkill, "Sort the new mail, archive the noise and draft the replies that need Maya.", "30 8,12,17 * * 1-5",
                      next: [nextFire(8, 30), nextFire(12, 30), nextFire(17, 30)].min() ?? nextFire(8, 30), last: (mailThread, mailTask), runs: 164)
        try await job("Company post", postSkill, "Draft today's post for the Harbor company page.", "weekdays at 09:30", next: nextFire(9, 30), last: (postThread, postTask), runs: 41)
        try await job("Product demo", demoSkill, "Record this week's demo: what's new in Harbor.", "weekly on tue at 10:00",
                      next: calendar.nextDate(after: now.addingTimeInterval(1800), matching: DateComponents(hour: 10, minute: 0, weekday: 3), matchingPolicy: .nextTime) ?? nextFire(10),
                      last: nil, runs: 9)
        try await job("Service check", checkSkill, "Check the API, the web app and the import queue.", "hourly", next: nextHour, last: lastCheck, runs: 1_204)

        // MARK: Goals: one Pennant works on every weekday, and one it proposed this morning

        let pageGoal = Goal(title: "Grow Harbor's LinkedIn page", outcome: "2,000 followers on the Harbor company page by the end of the quarter, from posts people share.",
                            measure: "Followers on the page, read every Friday", ownerAgentID: pennant.id, limits: "Never post without Maya's approval.",
                            workSchedule: "weekdays at 10:00", weeklyBudget: 15, status: .active, createdAt: ago(21 * 1440), updatedAt: ago(1440), lastWorkedAt: ago(1440))
        let goalThread = try await thread("🎯 \(pageGoal.title)", preview: "Drafted the import speed-up carousel.", created: ago(21 * 1440), updated: ago(1440))
        var activeGoal = pageGoal
        activeGoal.conversationID = goalThread.id
        try await store.upsertGoal(activeGoal)
        for (run, schedule, next) in [("work", activeGoal.workSchedule, nextFire(10)), ("review", activeGoal.reviewSchedule,
                calendar.nextDate(after: now.addingTimeInterval(1800), matching: DateComponents(hour: 16, minute: 0, weekday: 6), matchingPolicy: .nextTime) ?? nextFire(16))] {
            var j = ScheduledJob(name: "🎯 \(activeGoal.title) · \(run == "work" ? "work" : "weekly review")", agentID: pennant.id,
                                 prompt: run == "work" ? "A work session on the goal \"\(activeGoal.title)\"." : "The weekly review of the goal \"\(activeGoal.title)\".",
                                 schedule: schedule, conversationID: goalThread.id, nextRunAt: next, runCount: run == "work" ? 14 : 3)
            j.goalID = activeGoal.id
            j.goalRun = run
            try await store.upsertSchedule(j)
        }
        let board: [(String, String, GoalItem.State, GoalItem.Note?)] = [
            ("Approve the posting rhythm", "Three posts a week: Tuesday, Wednesday, Thursday at 9:30.", .waiting, GoalItem.Note(text: "On a card for Maya.", by: pennant.name, at: ago(1440))),
            ("Carousel: imports 4× faster in 2.0", "Six slides from the release notes, with the 50k-row numbers.", .doing, GoalItem.Note(text: "Slides 1–4 drafted.", by: pennant.name, at: ago(1440))),
            ("Line up three customer quotes", "Northwind, Lumen and Kestrel said yes to being quoted.", .next, nil),
            ("A 30-second clip of shared views", "", .idea, nil),
            ("Rewrite the page's About section", "", .done, GoalItem.Note(text: "Live since last Tuesday.", by: pennant.name, at: ago(8 * 1440))),
        ]
        for (i, item) in board.enumerated() {
            try await store.upsertGoalItem(GoalItem(goalID: activeGoal.id, title: item.0, detail: item.1, state: item.2, rank: i, notes: item.3.map { [$0] } ?? [],
                                                    createdAt: ago(Double(20 - i) * 1440), updatedAt: ago(Double(i + 1) * 600)))
        }

        let importGoal = Goal(title: "Faster imports", outcome: "Imports of 50,000 rows finish in under two minutes at p95, and stay there.",
                              measure: "p95 import time on the Service check dashboard", ownerAgentID: pennant.id, freedom: .proposeOnly,
                              workSchedule: "weekdays at 14:00", createdAt: ago(150), updatedAt: ago(150))
        try await store.upsertGoal(importGoal)
        let importThread = try await thread("Import queue", preview: "Proposed a goal: Faster imports.", created: ago(155), updated: ago(150))
        let importTask = try await task(importThread, "Import queue", state: .completed, started: ago(155), finished: ago(150), steps: 3, input: 22_000, output: 800,
                                        summary: "Proposed the goal Faster imports.")
        try await ask(importThread, importTask, "Imports felt slow during the beta. Is that worth a goal?", ago(155))
        var proposal = ApprovalRequest(taskID: importTask.id, title: "Goal: \(importGoal.title)", destination: "Goal", text: importGoal.outcome,
                                       details: [ApprovalDetail(label: "Freedom", value: importGoal.freedom.title), ApprovalDetail(label: "How we'll know", value: importGoal.measure),
                                                 ApprovalDetail(label: "Works", value: importGoal.workSchedule), ApprovalDetail(label: "Reviews", value: importGoal.reviewSchedule)],
                                       notes: "First steps:\n- Profile the three slowest imports from the beta\n- Compare batch sizes of 500 and 5,000 rows\n- Propose the fix as a coding run", createdAt: ago(150))
        proposal.approveLabel = "Approve & start"
        proposal.action = ApprovalAction(tool: ActivateGoalTool.name, arguments: .object(["goal_id": .string(importGoal.id.rawValue)]), textField: "text", label: "Approve & start")
        try await say(importThread, importTask, .assistant, [.text("Yes: p95 was 3 min 40 s in three of the last six checks. Here's a goal for it; I'd only propose changes, not make them."), .approval(proposal)], ago(150))
        try await spend(importTask, .lead, at: ago(150), input: 22_000, cached: 14_000, output: 800)

        // MARK: Memory

        let fromChat = Provenance(sourceType: .userMessage, agentID: pennant.id)
        let launch = MemoryEntity(kind: .project, name: "Harbor 2.0", summary: "The launch going live this week: faster imports, shared views, annual plans.", provenance: fromChat)
        let jonas = MemoryEntity(kind: .person, name: "Jonas Lindqvist", summary: "Head of Partnerships at Northwind. Maya promised him the final launch checklist by Friday.", provenance: fromChat)
        let priya = MemoryEntity(kind: .person, name: "Priya Raman", summary: "Leads design at Northwind; her team will use shared views first.", provenance: fromChat)
        let tomas = MemoryEntity(kind: .person, name: "Tomás Ferreira", summary: "Engineer on the import pipeline; wrote the batching fix.", provenance: fromChat)
        let delphine = MemoryEntity(kind: .person, name: "Delphine Moreau", summary: "Runs support; wants a heads-up before customer emails go out.", provenance: fromChat)
        let northwind = MemoryEntity(kind: .organization, name: "Northwind", summary: "Harbor's largest partner.", provenance: fromChat)
        for e in [launch, jonas, priya, tomas, delphine, northwind] { try await store.upsertEntity(e) }
        try await store.upsertRelation(MemoryRelation(fromEntityID: jonas.id, relation: "works at", toEntityID: northwind.id, provenance: fromChat))
        try await store.upsertRelation(MemoryRelation(fromEntityID: priya.id, relation: "works at", toEntityID: northwind.id, provenance: fromChat))
        try await store.upsertRelation(MemoryRelation(fromEntityID: tomas.id, relation: "works on", toEntityID: launch.id, provenance: fromChat))
        for p in ["Keep company-page posts under 120 words, with at most two hashtags.",
                  "Never publish before 8 AM Pacific.",
                  "Tell Delphine before any email goes to more than 20 customers.",
                  "Replies to partners are signed \"Maya\", not \"Maya Okafor\"."] {
            try await store.upsertPreference(Preference(text: p, provenance: fromChat))
        }
    }
}

public enum DemoSeedError: Error, CustomStringConvertible {
    case notEmpty(String)
    public var description: String {
        switch self { case .notEmpty(let path): return "\(path) already has data. Seed the demo into an empty folder." }
    }
}
