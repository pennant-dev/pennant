import PennantCore
@testable import PennantHostKit
import XCTest

final class TeachingTests: XCTestCase {
    // MARK: Wording

    func testSummariesReadAsPlainSteps() {
        let record = TeachingElement(role: "AXButton", roleDescription: "button", label: "Record")
        let click = TeachingEvent(id: 1, kind: .click(button: "left", count: 1, element: record, app: "Recordly", window: "Recordly", x: 0.5, y: 0.1))
        XCTAssertEqual(click.summary, "Clicked button “Record” in Recordly (window “Recordly”)")

        let blank = TeachingEvent(id: 2, kind: .click(button: "left", count: 2, element: nil, app: "Canvas", window: nil, x: 0.25, y: 0.75))
        XCTAssertEqual(blank.summary, "Double-clicked an unlabelled spot at 25% across, 75% down the window in Canvas")

        let field = TeachingElement(role: "AXTextField", roleDescription: "text field", label: "Search")
        XCTAssertEqual(TeachingEvent(id: 3, kind: .typed(text: "acme", field: field, app: "Safari")).summary, "Typed “acme” into text field “Search” in Safari")
        XCTAssertEqual(TeachingEvent(id: 4, kind: .secureTyped(app: "1Password")).summary, "Typed a password in 1Password (not recorded)")
        XCTAssertEqual(TeachingEvent(id: 5, kind: .shortcut(keys: "⌘⇧5", app: "Finder")).summary, "Pressed ⌘⇧5 in Finder")
        XCTAssertEqual(TeachingEvent(id: 6, kind: .note("pick the Acme window, not the terminal")).summary, "Note: pick the Acme window, not the terminal")
    }

    func testTranscriptNumbersStepsWithSecondsFromStart() {
        let start = Date(timeIntervalSince1970: 1000)
        let session = TeachingSession(goal: "g", startedAt: start, events: [
            TeachingEvent(id: 1, at: start.addingTimeInterval(1), kind: .appActivated(app: "Recordly", bundleID: nil)),
            TeachingEvent(id: 2, at: start.addingTimeInterval(4.4), kind: .key(name: "Return", app: "Recordly")),
        ])
        XCTAssertEqual(session.transcript, "1. [+1s] Switched to Recordly\n2. [+4s] Pressed Return in Recordly")
    }

    func testSessionDecodesWithAllEventKinds() throws {
        let session = TeachingSession(goal: "g", events: [
            TeachingEvent(id: 1, kind: .appActivated(app: "A", bundleID: "com.a")),
            TeachingEvent(id: 2, kind: .window(app: "A", title: "W")),
            TeachingEvent(id: 3, kind: .click(button: "right", count: 1, element: TeachingElement(role: "AXCell", identifier: "row-1", value: "on"), app: "A", window: nil, x: nil, y: nil)),
            TeachingEvent(id: 4, kind: .scroll(direction: "down", app: "A")),
        ])
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(TeachingSession.self, from: data), session)
    }

    // MARK: Drafting

    func testDraftParsesFencedJSONIntoATaughtSkill() throws {
        let session = TeachingSession(goal: "Record a demo", events: [TeachingEvent(id: 1, kind: .note("use full screen"))])
        let text = """
        Here it is:
        ```json
        {"name": "Record a screen demo", "purpose": "Records the Acme UI", "inputs": ["duration"],
         "steps": [{"instruction": "Open Recordly", "check": "Its window is in front", "tool": "open_app"},
                   "Press ⌘⇧R to start",
                   {"instruction": "", "check": "dropped"}],
         "expected_result": "A video file", "failure_conditions": ["Recording captures the wrong window", ""]}
        ```
        """
        let skill = try SkillDrafter.skill(from: text, goal: session.goal, session: session)
        XCTAssertEqual(skill.name, "Record a screen demo")
        XCTAssertEqual(skill.origin, "taught")
        XCTAssertEqual(skill.status, .provisional)
        XCTAssertEqual(skill.steps.map(\.instruction), ["Open Recordly", "Press ⌘⇧R to start"])
        XCTAssertEqual(skill.steps.first?.tool, "open_app")
        XCTAssertEqual(skill.steps.first?.check, "Its window is in front")
        XCTAssertEqual(skill.inputs, ["duration"])
        XCTAssertEqual(skill.failureConditions, ["Recording captures the wrong window"])
        XCTAssertTrue(skill.body.contains("## Recorded demonstration"))
        XCTAssertTrue(skill.body.contains("Note: use full screen"))
    }

    func testDraftWithoutStepsIsRefused() {
        let session = TeachingSession(goal: "g")
        XCTAssertThrowsError(try SkillDrafter.skill(from: "{\"name\": \"x\", \"steps\": []}", goal: "g", session: session))
        XCTAssertThrowsError(try SkillDrafter.skill(from: "I could not do it", goal: "g", session: session))
    }

    func testDraftFallsBackToTheGoalForAName() throws {
        let skill = try SkillDrafter.skill(from: "{\"steps\": [\"Do it\"]}", goal: "Export the weekly report", session: TeachingSession(goal: "Export the weekly report"))
        XCTAssertEqual(skill.name, "Export the weekly report")
        XCTAssertEqual(skill.purpose, "Export the weekly report")
    }

    func testPromptCarriesGoalNotesAndTools() {
        let session = TeachingSession(goal: "Record a demo", events: [TeachingEvent(id: 1, kind: .note("the window matters"))])
        let messages = SkillDrafter.messages(goal: session.goal, session: session)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].text.contains("ui_action"))
        XCTAssertTrue(messages[1].text.contains("Record a demo"))
        XCTAssertTrue(messages[1].text.contains("Note: the window matters"))
    }

    // MARK: Session

    /// A recorder stand-in: the test pushes steps through the sink the service hands it.
    final class FakeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (TeachingRecorder.Recorded) -> Void)?
        private(set) var stopped = false
        func attach(_ s: @escaping @Sendable (TeachingRecorder.Recorded) -> Void) { lock.withLock { sink = s } }
        func push(_ kind: TeachingEventKind) { lock.withLock { sink }?(TeachingRecorder.Recorded(at: Date(), kind: kind)) }
        func stop() { lock.withLock { stopped = true } }
    }

    func testServiceKeepsStepsInOrderAndStopWaitsForThem() async {
        let fake = FakeRecorder()
        let published = PublishLog()
        let service = TeachingService(publish: { await published.add($0) }, startRecorder: { sink in
            fake.attach(sink)
            return ({ fake.stop() }, true)
        })
        let started = await service.start(goal: "  Record a demo  ")
        XCTAssertEqual(started.goal, "Record a demo")
        XCTAssertNil(started.warning)
        for i in 0 ..< 50 { fake.push(.key(name: "K\(i)", app: "A")) }
        let stopped = await service.stop()
        XCTAssertTrue(fake.stopped)
        XCTAssertEqual(stopped?.isRecording, false)
        XCTAssertNotNil(stopped?.endedAt)
        XCTAssertEqual(stopped?.events.count, 50)
        XCTAssertEqual(stopped?.events.map(\.id), Array(1 ... 50))
        if case .key(let name, _) = stopped?.events.last?.kind { XCTAssertEqual(name, "K49") } else { XCTFail("last step is not a key") }

        let noted = await service.addNote("the second window")
        XCTAssertEqual(noted?.events.last?.summary, "Note: the second window")
        let trimmed = await service.removeEvents([1, 2, 3])
        XCTAssertEqual(trimmed?.events.count, 48)
        await service.cancel()
        let gone = await service.current
        XCTAssertNil(gone)
        let last = await published.last
        XCTAssertNil(last ?? nil, "cancel publishes nil")
    }

    func testSessionSurvivesARestartStopped() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("teach-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeRecorder()
        let first = TeachingService(publish: { _ in }, fileURL: url, startRecorder: { sink in fake.attach(sink); return ({}, true) })
        _ = await first.start(goal: "Record a demo")
        fake.push(.key(name: "Return", app: "A"))
        for _ in 0 ..< 100 where (await first.current?.events.count ?? 0) < 1 { try await Task.sleep(for: .milliseconds(10)) }
        _ = await first.addNote("keep this")
        // The host restarts mid-recording.
        let second = TeachingService(publish: { _ in }, fileURL: url, startRecorder: { _ in ({}, true) })
        let restored = await second.current
        XCTAssertEqual(restored?.goal, "Record a demo")
        XCTAssertEqual(restored?.isRecording, false)
        XCTAssertEqual(restored?.events.count, 2)
        let next = await second.addNote("after restart")
        XCTAssertEqual(next?.events.last?.id, 3)
        await second.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testServiceWarnsWhenTheTapIsRefused() async {
        let service = TeachingService(publish: { _ in }, startRecorder: { _ in ({}, false) })
        let s = await service.start(goal: "g")
        XCTAssertNotNil(s.warning)
    }

    // MARK: Host round trip

    func testHostDraftsAndSavesATaughtSkill() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let provider = ScriptedProvider([])
        provider.checkpointJSON = "{\"name\": \"Record a screen demo\", \"purpose\": \"Records a demo\", \"steps\": [{\"instruction\": \"Open Recordly\", \"check\": \"window shows\"}]}"
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let service = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await service.start(startAPI: false)
        let client = ConnectedClient(id: ClientID("test"), displayName: "test", platform: "test")

        guard case .error = await service.handle(.draftSkillFromTeaching(goal: nil), from: client) else { return XCTFail("drafting with no session should fail") }
        guard case .teaching(let s?) = await service.handle(.startTeaching(goal: "Record a demo"), from: client) else { return XCTFail("start failed") }
        XCTAssertTrue(s.isRecording)
        _ = await service.handle(.addTeachingNote("open Recordly from the Dock"), from: client)
        _ = await service.handle(.addTeachingNote("pick full screen"), from: client)

        let reply = await service.handle(.draftSkillFromTeaching(goal: "Record a screen demo of Acme"), from: client)
        guard case .skill(let skill) = reply else { return XCTFail("unexpected reply \(reply)") }
        XCTAssertEqual(skill.origin, "taught")
        XCTAssertEqual(skill.steps.count, 1)
        let saved = try await service.store.skill(skill.id)
        XCTAssertEqual(saved?.name, "Record a screen demo")
        let session = await service.teaching.current
        XCTAssertEqual(session?.isRecording, false)
        XCTAssertEqual(session?.draftSkillID, skill.id)
        XCTAssertEqual(session?.goal, "Record a screen demo of Acme")
        let prompt = provider.requests.last?.messages.last?.text ?? ""
        XCTAssertTrue(prompt.contains("Note: pick full screen"))

        // Same name again: a new version, not a duplicate.
        guard case .skill(let second) = await service.handle(.draftSkillFromTeaching(goal: nil), from: client) else { return XCTFail("second draft failed") }
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(second.previousVersionID, skill.id)
        await service.stop()
    }
}

actor PublishLog {
    private(set) var items: [TeachingSession?] = []
    func add(_ s: TeachingSession?) { items.append(s) }
    var last: TeachingSession?? { items.last }
}
