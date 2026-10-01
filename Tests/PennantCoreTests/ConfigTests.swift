import PennantCore
import XCTest

final class ConfigTests: XCTestCase {
    func testCompactionDecodesOlderConfigAndCapsThreshold() throws {
        // A config written before `triggerTokens` existed still loads, with the cap defaulted.
        let json = #"{"triggerFraction":0.75,"reserveFraction":0.15,"keepRecentMessages":8}"#
        let c = try JSONDecoder().decode(HostConfig.Compaction.self, from: Data(json.utf8))
        XCTAssertEqual(c.triggerTokens, 128_000)
        XCTAssertEqual(c.keepRecentMessages, 8)
        // The cap wins for a huge window; the fraction wins for a small one; zero disables the cap.
        XCTAssertEqual(c.threshold(window: 1_000_000), 128_000)
        XCTAssertEqual(c.threshold(window: 32_000), 24_000)
        var off = c
        off.triggerTokens = 0
        XCTAssertEqual(off.threshold(window: 1_000_000), 750_000)
    }

    func testBudgetExhaustionAndExtension() {
        var usage = TaskUsage()
        usage.steps = 3
        usage.addTurn(input: 900, output: 200)
        var budget = TaskBudget(maxSteps: 3, maxTokens: 1000, maxDuration: 0, maxDelegations: 0)
        XCTAssertEqual(budget.exhaustedReason(usage: usage), "reached 3 steps")
        budget.extend(by: TaskBudget(maxSteps: 3, maxTokens: 1000, maxDuration: 0), usage: usage)
        XCTAssertEqual(budget.maxSteps, 6)
        XCTAssertEqual(budget.maxTokens, 2100)
        XCTAssertNil(budget.exhaustedReason(usage: usage))
        let unlimited = TaskBudget(maxSteps: 0, maxTokens: 0, maxDuration: 0)
        XCTAssertNil(unlimited.exhaustedReason(usage: usage))
    }

    func testTokenLimitCountsWhatATaskAddsNotWhatItRereads() {
        // Forty turns re-reading a 150k conversation that grows by 2k a turn: 6M sent, but only ~230k new.
        var usage = TaskUsage()
        for turn in 0..<40 { usage.addTurn(input: 150_000 + turn * 2_000, output: 500) }
        XCTAssertGreaterThan(usage.inputTokens, 6_000_000, "the full total is kept for cost")
        XCTAssertEqual(usage.newTokens, 150_000 + 39 * 2_000 + 40 * 500)
        XCTAssertNil(TaskBudget(maxSteps: 0, maxTokens: 5_000_000, maxDuration: 0).exhaustedReason(usage: usage))

        // Compaction shrinks the next turn's input: nothing is added for that turn, and growth counts from there.
        let before = usage.newTokens
        usage.addTurn(input: 40_000, output: 300)
        XCTAssertEqual(usage.newTokens, before + 300)
        usage.addTurn(input: 45_000, output: 300)
        XCTAssertEqual(usage.newTokens, before + 300 + 5_000 + 300)

        let tight = TaskBudget(maxSteps: 0, maxTokens: 100_000, maxDuration: 0)
        XCTAssertEqual(tight.exhaustedReason(usage: usage), "added 100k new tokens")
    }

    /// A task that sat four hours on an approval card hit its four-hour limit the moment you approved it. Waiting on
    /// a person (or being paused) isn't the task's own time.
    func testTheTimeLimitCountsWorkNotWaitingForAPerson() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var usage = TaskUsage(startedAt: start)
        let budget = TaskBudget(maxSteps: 0, maxTokens: 0, maxDuration: 4 * 3600)
        usage.track(from: .running, to: .waitingForUser, at: start.addingTimeInterval(600))            // 10 min of work
        XCTAssertNil(budget.exhaustedReason(usage: usage, now: start.addingTimeInterval(5 * 3600)), "still waiting: no work time passes")
        usage.track(from: .waitingForUser, to: .queued, at: start.addingTimeInterval(5 * 3600))        // approved after ~5 h
        XCTAssertEqual(usage.activeSeconds(now: start.addingTimeInterval(5 * 3600 + 600)) ?? 0, 1200, accuracy: 0.001)
        XCTAssertNil(budget.exhaustedReason(usage: usage, now: start.addingTimeInterval(5 * 3600 + 600)))
        // Work time still adds up to the limit.
        XCTAssertEqual(budget.exhaustedReason(usage: usage, now: start.addingTimeInterval(4 * 3600 + 5 * 3600)), "worked for 4 hours")
        // Paused by the owner counts as waiting too.
        usage.track(from: .running, to: .paused, at: start.addingTimeInterval(6 * 3600))
        usage.track(from: .paused, to: .running, at: start.addingTimeInterval(8 * 3600))
        XCTAssertEqual(usage.waitedSeconds, (5 * 3600 - 600) + 2 * 3600, accuracy: 0.001)
    }
}

final class ModelProfileRulesTests: XCTestCase {
    func testOlderConfigBecomesADefaultProfileAndStaysInSync() throws {
        var c = HostConfig(inference: HostConfig.Inference(baseURL: "https://spark.example/v1", model: "qwen"))
        XCTAssertTrue(c.normalizeModels())
        XCTAssertEqual(c.inferenceProfiles.count, 1)
        XCTAssertEqual(c.defaultProfile?.inference.model, "qwen")
        XCTAssertFalse(c.normalizeModels(), "a second pass changes nothing")

        // Choosing another profile as the default drives the host model.
        var azure = HostConfig.Inference(baseURL: "https://r.cognitiveservices.azure.com/openai/v1", model: "gpt-5.6-sol", provider: HostConfig.Inference.azureProvider)
        azure.azure = .init(subscriptionID: "sub", resourceGroup: "rg", resource: "r")
        let sol = InferenceProfile(name: "GPT-5.6 Sol · Azure", inference: azure)
        var next = c
        next.inferenceProfiles.append(sol)
        next.defaultProfileID = sol.id
        next.reconcileModels(previous: c)
        XCTAssertEqual(next.inference.model, "gpt-5.6-sol")
        XCTAssertEqual(next.inference.provider, HostConfig.Inference.azureProvider)

        // An older client editing `inference` directly updates the default profile instead of diverging.
        var edited = next
        edited.inference.reasoningEffort = "high"
        edited.reconcileModels(previous: next)
        XCTAssertEqual(edited.defaultProfile?.inference.reasoningEffort, "high")

        // Fallbacks drop the default, duplicates and deleted profiles; the old single field still decodes.
        edited.fallbackProfileIDs = [sol.id, "gone", c.defaultProfileID!, c.defaultProfileID!]
        edited.normalizeModels()
        XCTAssertEqual(edited.fallbackProfileIDs, [c.defaultProfileID!])
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as! [String: Any]
        legacy.removeValue(forKey: "fallbackProfileIDs")
        legacy["fallbackProfileID"] = sol.id
        let decoded = try JSONDecoder().decode(HostConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.fallbackProfileIDs, [sol.id])
        XCTAssertEqual(decoded.defaultProfileID, edited.defaultProfileID)
    }

    /// A config from before several projects had one coding folder: it becomes the only project, named after it, and
    /// is written back as projects.
    func testAnOlderCodingFolderBecomesTheOnlyProject() throws {
        let json = #"{"engine":"claudeCode","workingDirectory":"/Users/maya/code/harbor-web","instructions":"Branch first.","mode":"plan"}"#
        let coding = try JSONDecoder().decode(HostConfig.Coding.self, from: Data(json.utf8))
        XCTAssertEqual(coding.projects, [CodingProject(name: "harbor-web", path: "/Users/maya/code/harbor-web")])
        XCTAssertEqual(coding.defaultProject?.name, "harbor-web")
        XCTAssertNil(coding.modelProfileID)
        XCTAssertEqual(coding.instructions, "Branch first.")
        XCTAssertEqual(coding.mode, .plan)
        let data = try JSONEncoder().encode(coding)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("workingDirectory"))
        XCTAssertEqual(try JSONDecoder().decode(HostConfig.Coding.self, from: data), coding)
    }

    func testCodingProjectsAndTheirModelRoundTrip() throws {
        var coding = HostConfig.Coding(engine: .pennant, modelProfileID: "fast-profile")
        coding.addProject(path: "/work/app", asDefault: true)
        coding.addProject(path: "/clients/app", asDefault: false)
        coding.addProject(path: "/work/www", name: "Site", asDefault: true)
        XCTAssertEqual(coding.projects.map(\.name), ["Site", "app", "app 2"], "names stay unique: the code tool finds projects by name")
        // A folder already there is renamed or moved, not added twice.
        coding.addProject(path: "/work/app", name: "API", asDefault: true)
        XCTAssertEqual(coding.projects.map(\.name), ["API", "Site", "app 2"])
        XCTAssertEqual(coding.project(named: "site")?.path, "/work/www")
        XCTAssertEqual(coding.uniqueName("site"), "site 2")
        XCTAssertEqual(coding.uniqueName("site", except: "/work/www"), "site")

        var config = HostConfig()
        config.coding = coding
        let back = try JSONDecoder().decode(HostConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.coding, coding)
        XCTAssertEqual(back.coding?.modelProfileID, "fast-profile")
        XCTAssertEqual(back.coding?.engine, .pennant)
    }
}
