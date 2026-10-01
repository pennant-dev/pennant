import PennantCore
@testable import PennantHostKit
import XCTest

final class DesktopToolsTests: XCTestCase {
    private let agentID = AgentID("agent-1")
    private let conversationID = ConversationID("conv-1")

    private func makeContext(taskID: TaskID = TaskID(), desktop: FakeDesktop = FakeDesktop(), lease: DesktopLease = DesktopLease(), store: FakeStore = FakeStore()) -> ToolContext {
        ToolContext(agentID: agentID, taskID: taskID, conversationID: conversationID, store: store, desktop: desktop, lease: lease, config: HostConfig())
    }

    private func tool(_ name: String) throws -> any Tool {
        guard let tool = DesktopTools.all().first(where: { $0.spec.name == name }) else { throw XCTSkip("missing tool \(name)") }
        return tool
    }

    func testAllToolsHaveUniqueNamesAndObjectSchemas() {
        let tools = DesktopTools.all()
        let names = tools.map(\.spec.name)
        XCTAssertEqual(Set(names).count, names.count)
        for tool in tools {
            XCTAssertEqual(tool.spec.inputSchema["type"]?.stringValue, "object", tool.spec.name)
            XCTAssertFalse(tool.spec.description.isEmpty, tool.spec.name)
        }
        XCTAssertTrue(try tool("click").spec.needsDesktop)
        XCTAssertFalse(try tool("screenshot").spec.needsDesktop)
        XCTAssertFalse(try tool("list_apps").spec.needsDesktop)
        XCTAssertFalse(try tool("wait").spec.needsDesktop)
        XCTAssertTrue(try tool("run_applescript").spec.isConsequential)
    }

    func testClickWithoutLeaseIsRevoked() async throws {
        let desktop = FakeDesktop()
        let context = makeContext(desktop: desktop)
        do {
            _ = try await tool("click").invoke(["x": 10, "y": 20], context: context)
            XCTFail("click must require the desktop lease")
        } catch ToolError.desktopRevoked {
        }
        XCTAssertTrue(desktop.actions.isEmpty)
    }

    func testClickMapsScreenshotPixelsToDisplayPoints() async throws {
        let desktop = FakeDesktop() // 1600x1000 display
        let lease = DesktopLease()
        let taskID = TaskID()
        let store = FakeStore()
        let context = makeContext(taskID: taskID, desktop: desktop, lease: lease, store: store)
        _ = try await lease.acquire(agentID: agentID, taskID: taskID)

        let shot = try await tool("screenshot").invoke(["max_width": 800], context: context)
        XCTAssertFalse(shot.isError)
        XCTAssertTrue(shot.textContent.contains("800x500 px"))
        guard case .image(let ref)? = shot.content.last else { return XCTFail("screenshot should return an image part") }
        XCTAssertEqual(ref.width, 800)
        let stored = try await store.artifactData(ref.artifactID)
        XCTAssertEqual(stored, FakeDesktop.tinyJPEG)
        let record = try await store.artifact(ref.artifactID)
        XCTAssertEqual(record?.kind, "screenshot")
        XCTAssertEqual(record?.taskID, taskID)

        let result = try await tool("click").invoke(["x": 100, "y": 50, "button": "right", "count": 1], context: context)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(desktop.actions.last, "click(200,100,right,1)")

        _ = try await tool("double_click").invoke(["x": 10, "y": 10], context: context)
        XCTAssertEqual(desktop.actions.last, "click(20,20,left,2)")

        _ = try await tool("drag").invoke(["from_x": 0, "from_y": 0, "to_x": 400, "to_y": 250], context: context)
        XCTAssertEqual(desktop.actions.last, "drag(0,0->800,500)")

        _ = try await tool("scroll").invoke(["x": 400, "y": 250, "delta_y": 100], context: context)
        XCTAssertEqual(desktop.actions.last, "scroll(800,500,0,200)")
    }

    func testClickWithoutScreenshotUsesDisplayPoints() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease()
        let taskID = TaskID()
        let context = makeContext(taskID: taskID, desktop: desktop, lease: lease)
        _ = try await lease.acquire(agentID: agentID, taskID: taskID)
        _ = try await tool("click").invoke(["x": 300, "y": 200], context: context)
        XCTAssertEqual(desktop.actions.last, "click(300,200,left,1)")
    }

    func testInvalidArguments() async throws {
        let lease = DesktopLease()
        let taskID = TaskID()
        let context = makeContext(taskID: taskID, lease: lease)
        _ = try await lease.acquire(agentID: agentID, taskID: taskID)
        do {
            _ = try await tool("click").invoke(["x": 10], context: context)
            XCTFail("missing y must fail")
        } catch ToolError.invalidArguments {
        }
        do {
            _ = try await tool("click").invoke(["x": 10, "y": 10, "button": "pinky"], context: context)
            XCTFail("bad button must fail")
        } catch ToolError.invalidArguments {
        }
        do {
            _ = try await tool("press_key").invoke([:], context: context)
            XCTFail("missing keys must fail")
        } catch ToolError.invalidArguments {
        }
    }

    func testKeyboardTools() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease()
        let taskID = TaskID()
        let context = makeContext(taskID: taskID, desktop: desktop, lease: lease)
        _ = try await lease.acquire(agentID: agentID, taskID: taskID)
        _ = try await tool("press_key").invoke(["keys": "cmd+shift+s"], context: context)
        XCTAssertEqual(desktop.actions.last, "key(cmd+shift+s)")
        _ = try await tool("press_key").invoke(["keys": "Return"], context: context)
        XCTAssertEqual(desktop.actions.last, "key(return)")
        _ = try await tool("type_text").invoke(["text": "hello\nworld"], context: context)
        XCTAssertEqual(desktop.actions.last, "type(hello\nworld)")
    }

    func testTakeoverRevokesMidTask() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease(desktop: desktop)
        let taskID = TaskID()
        let context = makeContext(taskID: taskID, desktop: desktop, lease: lease)
        _ = try await lease.acquire(agentID: agentID, taskID: taskID)
        _ = try await tool("type_text").invoke(["text": "a"], context: context)
        await lease.humanTakeover()
        do {
            _ = try await tool("type_text").invoke(["text": "b"], context: context)
            XCTFail("typing after takeover must be refused")
        } catch ToolError.desktopRevoked {
        }
        XCTAssertEqual(desktop.actions.filter { $0.hasPrefix("type(") }, ["type(a)"])
    }

    func testAppTools() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease()
        let taskID = TaskID()
        let context = makeContext(taskID: taskID, desktop: desktop, lease: lease)
        let list = try await tool("list_apps").invoke([:], context: context)
        XCTAssertTrue(list.textContent.contains("TextEdit"))
        XCTAssertTrue(list.textContent.contains("[frontmost]"))

        _ = try await lease.acquire(agentID: agentID, taskID: taskID)
        let opened = try await tool("open_app").invoke(["name": "Notes"], context: context)
        XCTAssertTrue(opened.textContent.contains("Opened Notes"))
        XCTAssertEqual(desktop.actions.last, "launch(Notes)")
        let activated = try await tool("activate_app").invoke(["name": "com.apple.finder"], context: context)
        XCTAssertTrue(activated.textContent.contains("Finder"))
        do {
            _ = try await tool("activate_app").invoke(["name": "Nope"], context: context)
            XCTFail("unknown app must fail")
        } catch is DesktopError {
        }
    }

    func testUITreeAndActions() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease()
        let taskID = TaskID()
        let context = makeContext(taskID: taskID, desktop: desktop, lease: lease)
        let tree = try await tool("ui_tree").invoke(["max_nodes": 2], context: context)
        let text = tree.textContent
        XCTAssertTrue(text.contains("TextEdit: 2 nodes"), text)
        XCTAssertTrue(text.contains("[1] AXButton 'Save' @400,80 96x24 actions=AXPress"), text)
        XCTAssertTrue(text.contains("display points"), text)

        _ = try await lease.acquire(agentID: agentID, taskID: taskID)
        _ = try await tool("screenshot").invoke(["max_width": 800], context: context)
        let scaled = try await tool("ui_tree").invoke(["app": "textedit"], context: context)
        XCTAssertTrue(scaled.textContent.contains("[1] AXButton 'Save' @200,40 48x12"), scaled.textContent)
        XCTAssertTrue(scaled.textContent.contains("screenshot pixels"))

        _ = try await tool("ui_action").invoke(["index": 1], context: context)
        XCTAssertEqual(desktop.actions.last, "axAction(1,AXPress)")
        _ = try await tool("ui_set_value").invoke(["index": 2, "value": "New text"], context: context)
        XCTAssertEqual(desktop.actions.last, "axSet(2,New text)")
        do {
            _ = try await tool("ui_action").invoke(["index": 42], context: context)
            XCTFail("unknown index must fail")
        } catch is DesktopError {
        }
    }

    func testScriptingAndWait() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease()
        let taskID = TaskID()
        let context = makeContext(taskID: taskID, desktop: desktop, lease: lease)
        _ = try await lease.acquire(agentID: agentID, taskID: taskID)
        let script = try await tool("run_applescript").invoke(["source": "return 1"], context: context)
        XCTAssertEqual(script.textContent, "ok:return 1")
        let jxa = try await tool("run_jxa").invoke(["source": "1+1"], context: context)
        XCTAssertEqual(jxa.textContent, "ok:1+1")
        let started = Date()
        let waited = try await tool("wait").invoke(["seconds": 0.1], context: context)
        XCTAssertTrue(waited.textContent.hasPrefix("Waited 0.1"))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
    }

    func testKeyCodeResolution() {
        XCTAssertEqual(KeyCodes.resolve("return").code, 36)
        XCTAssertEqual(KeyCodes.resolve("Escape").code, 53)
        XCTAssertEqual(KeyCodes.resolve("s").code, 1)
        XCTAssertEqual(KeyCodes.resolve("S").code, 1)
        XCTAssertTrue(KeyCodes.resolve("S").shift)
        XCTAssertEqual(KeyCodes.resolve("!").code, 18)
        XCTAssertTrue(KeyCodes.resolve("!").shift)
        XCTAssertEqual(KeyCodes.resolve("f5").code, 96)
        XCTAssertNil(KeyCodes.resolve("nosuchkey").code)
        XCTAssertEqual(KeyCodes.resolve("é").unicode, Array("é".utf16))
        let chord = KeyChord(parsing: "cmd+shift+t")
        XCTAssertTrue(chord.command && chord.shift && !chord.option)
        XCTAssertEqual(chord.key, "t")
    }

    func testCaptureGeometryMapping() {
        let geometry = CaptureGeometry(width: 800, height: 500, displayWidth: 1600, displayHeight: 1000)
        XCTAssertEqual(geometry.scale, 2)
        let display = geometry.toDisplay(x: 10, y: 20)
        XCTAssertEqual(display.x, 20)
        XCTAssertEqual(display.y, 40)
        let back = geometry.toScreenshot(x: 20, y: 40)
        XCTAssertEqual(back.x, 10)
        XCTAssertEqual(back.y, 20)
        let size = ScreenCapturer.outputSize(maxWidth: 1440, displayWidth: 1728, displayHeight: 1117, pixelScale: 2)
        XCTAssertEqual(size.width, 1440)
        XCTAssertEqual(size.height, 931)
    }
}

final class ShellGroupTests: XCTestCase {
    /// A timed-out command takes its children with it (a backgrounded sleep would otherwise outlive the shell).
    func testTimeoutStopsTheWholeProcessGroup() async throws {
        let marker = "pennant-group-test-\(UUID().uuidString.prefix(8))"
        _ = marker
        let result = try await ShellRunner.run("sleep 37.3 & sleep 37.3", workingDirectory: NSTemporaryDirectory(), timeout: 1)
        XCTAssertTrue(result.timedOut)
        try await Task.sleep(for: .seconds(4))
        // The bracket keeps pgrep from matching its own command line.
        let left = try await ShellRunner.run("pgrep -f 'slee[p] 37.3' | wc -l", workingDirectory: NSTemporaryDirectory(), timeout: 10)
        XCTAssertEqual(left.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0", "children must be stopped with the shell")
    }
}
