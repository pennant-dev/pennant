import PennantCore
@testable import PennantHostKit
import XCTest

/// A stand-in for the extension: answers each action and keeps what was asked.
final class FakeBrowser: BrowserLinking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var asked: [(String, JSONValue)] = []
    var url = "https://example.com/"

    func request(_ action: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        lock.withLock { asked.append((action, params)) }
        if action == "open", let u = params["url"]?.stringValue { lock.withLock { url = u } }
        let tab = JSONValue.number(params["tab"]?.doubleValue ?? 7)
        return .object(["tab": tab, "title": .string("A page"), "url": .string(lock.withLock { url }), "did": .string("Clicked the button “Go”."),
                        "text": .string("Hello"), "elements": .array([.object(["ref": .number(1), "kind": .string("button"), "label": .string("Go")]),
                                               .object(["ref": .number(2), "kind": .string("link"), "label": .string("Pricing"), "href": .string("https://example.com/pricing")])])])
    }
}

/// Pennant in the owner's Chrome: its own tabs, and a card before it uses a site it hasn't been allowed on.
final class WebToolsTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    /// `asks`: the owner wants a card before Pennant first uses a site.
    private func context(hooks: RuntimeHooks? = nil, taskID: TaskID = TaskID(), asks: Bool = false) -> ToolContext {
        var config = HostConfig()
        config.chromeAsksForNewSites = asks
        return ToolContext(agentID: AgentID("a"), taskID: taskID, conversationID: ConversationID("c"), store: FakeStore(), desktop: FakeDesktop(), lease: DesktopLease(), config: config, runtimeHooks: hooks)
    }

    private func hooks(approving: Bool, asked: Locked<[String]>) -> RuntimeHooks {
        var h = RuntimeHooks(delegate: { _, _, _, _, _, _, _ in TaskID() }, awaitTask: { _, _ in throw ToolError.timeout }, askUser: { _, _ in "" },
                             learnSkill: { _, s in s }, scheduleJob: { _, _, _, _ in throw ToolError.failed("") }, deleteSchedule: { _ in },
                             importSkills: { _ in ([], []) })
        h.requestApproval = { _, card in
            asked.set(asked.get() + [card.title])
            var decided = card
            decided.state = approving ? .approved : .rejected
            return decided
        }
        return h
    }

    private func tool(_ name: String, _ browser: FakeBrowser, _ sites: ChromeSites) throws -> any Tool {
        guard let tool = WebTools.all(link: browser, sites: sites).first(where: { $0.spec.name == name }) else { throw XCTSkip(name) }
        return tool
    }

    func testANewSiteIsUsedWithoutACardUnlessTheOwnerAsksToBeAsked() async throws {
        let browser = FakeBrowser()
        let asked = Locked<[String]>([])
        let opened = try await tool("web_open", browser, ChromeSites(folder: folder)).invoke(["url": "https://bank.example.org/"], context: context(hooks: hooks(approving: false, asked: asked)))
        XCTAssertTrue(opened.textContent.contains("tab 7"), opened.textContent)
        XCTAssertTrue(asked.get().isEmpty, "no card by default")
        XCTAssertFalse(HostConfig().chromeAsksForNewSites)
    }

    func testANewSiteIsAskedAboutOnceThenRemembered() async throws {
        let browser = FakeBrowser()
        let sites = ChromeSites(folder: folder)
        let asked = Locked<[String]>([])
        let ctx = context(hooks: hooks(approving: true, asked: asked), asks: true)
        let opened = try await tool("web_open", browser, sites).invoke(["url": "https://signin.aws.amazon.com/signup"], context: ctx)
        XCTAssertTrue(opened.textContent.contains("tab 7"), opened.textContent)
        XCTAssertEqual(asked.get(), ["Use amazon.com in your Chrome"])
        _ = try await tool("web_open", browser, sites).invoke(["url": "https://console.aws.amazon.com/"], context: ctx)
        XCTAssertEqual(asked.get().count, 1, "allowed once for the site")
        let reopened = ChromeSites(folder: folder)
        let remembered = await reopened.isAllowed("amazon.com")
        XCTAssertTrue(remembered, "kept across restarts")
    }

    func testASiteTheOwnerTurnedDownIsNeverOpened() async throws {
        let browser = FakeBrowser()
        let asked = Locked<[String]>([])
        do {
            _ = try await tool("web_open", browser, ChromeSites(folder: folder)).invoke(["url": "https://bank.example.org/"], context: context(hooks: hooks(approving: false, asked: asked), asks: true))
            XCTFail("opened a site the owner turned down")
        } catch ToolError.denied {}
        XCTAssertTrue(browser.asked.isEmpty, "nothing reached Chrome")
    }

    func testActionsGoToTheTaskTabAndReadNumbersTheElements() async throws {
        let browser = FakeBrowser()
        let sites = ChromeSites(folder: folder)
        await sites.allow("example.com")
        let ctx = context()
        _ = try await tool("web_open", browser, sites).invoke(["url": "https://example.com/"], context: ctx)
        let read = try await tool("web_read", browser, sites).invoke([:], context: ctx)
        XCTAssertTrue(read.textContent.contains("[1] button “Go”"), read.textContent)
        XCTAssertTrue(read.textContent.contains("[2] link “Pricing” → https://example.com/pricing"), "links say where they go, for web_open")
        let clicked = try await tool("web_click", browser, sites).invoke(["element": 1], context: ctx)
        XCTAssertTrue(clicked.textContent.hasPrefix("Clicked the button “Go”."), clicked.textContent)
        let click = try XCTUnwrap(browser.asked.last)
        XCTAssertEqual(click.0, "click")
        XCTAssertEqual(click.1["tab"]?.intValue, 7, "the task's own tab")
        XCTAssertEqual(click.1["ref"]?.intValue, 1)
        do {
            _ = try await tool("web_click", browser, sites).invoke([:], context: ctx)
            XCTFail("clicked nowhere")
        } catch ToolError.invalidArguments {}
    }

    /// Pennant's Chrome tabs never touch the owner's screen, so the chat has all of them.
    func testTheChatHasEveryWebToolAndNoneNeedTheScreen() async throws {
        for t in WebTools.all(link: FakeBrowser(), sites: ChromeSites(folder: folder)) {
            XCTAssertFalse(t.spec.needsDesktop, t.spec.name)
            XCTAssertTrue(TaskRuntime.chatTools.contains(t.spec.name), t.spec.name)
        }
        XCTAssertEqual(WebTools.names.count, WebTools.all(link: FakeBrowser(), sites: ChromeSites(folder: folder)).count)
    }

    func testTheSiteOfAnAddress() {
        XCTAssertEqual(ChromeSites.site(of: "https://signin.aws.amazon.com/signup?x=1"), "amazon.com")
        XCTAssertEqual(ChromeSites.site(of: "https://www.bbc.co.uk/news"), "bbc.co.uk")
        XCTAssertEqual(ChromeSites.site(of: "https://example.com"), "example.com")
        XCTAssertNil(ChromeSites.site(of: "not a url"))
    }
}

/// The copy of the extension Chrome loads: kept in the data folder, stamped with its build, replaced when Pennant's changes.
final class ChromeExtensionTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func makeSource(_ script: String = "const VERSION = '1';\nconst BUILD = 'source';\nconnect();\n") throws -> URL {
        let source = folder.appendingPathComponent("Pennant.app/Contents/Resources/PennantChrome", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try #"{"name": "Pennant"}"#.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: source.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("icons/16.png"))
        return source
    }

    func testTheCopyIsStampedAndKeptUntilTheExtensionChanges() throws {
        let source = try makeSource()
        let root = folder.appendingPathComponent("data", isDirectory: true)
        let first = try ChromeExtension.install(from: source, into: root)
        XCTAssertEqual(first.folder.lastPathComponent, "chrome-extension")
        XCTAssertEqual(ChromeExtension.installedBuild(at: first.folder), first.build)
        let script = try String(contentsOf: first.folder.appendingPathComponent("background.js"), encoding: .utf8)
        XCTAssertTrue(script.contains("const BUILD = '\(first.build)';") && !script.contains("'source'"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.folder.appendingPathComponent("icons/16.png").path))

        // Unchanged: the same copy stays, so Chrome isn't asked to reload.
        let marker = first.folder.appendingPathComponent("kept")
        try Data().write(to: marker)
        XCTAssertEqual(try ChromeExtension.install(from: source, into: root).build, first.build)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Pennant's extension changed: a fresh copy with a new build.
        try "const VERSION = '2';\nconst BUILD = 'source';\nconnect();\n".write(to: source.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        let second = try ChromeExtension.install(from: source, into: root)
        XCTAssertNotEqual(second.build, first.build)
        XCTAssertEqual(ChromeExtension.installedBuild(at: second.folder), second.build)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTheExtensionIsFoundInsidePennantApp() throws {
        let source = try makeSource()
        let helper = folder.appendingPathComponent("Pennant.app/Contents/Helpers/Pennant Host.app", isDirectory: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        XCTAssertEqual(ChromeExtension.bundled(from: helper)?.standardizedFileURL, source.standardizedFileURL)
    }
}
