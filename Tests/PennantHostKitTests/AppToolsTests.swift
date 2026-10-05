import PennantCore
@testable import PennantHostKit
import XCTest

/// Working in an app in the background: no desktop lease, no owner's pointer, coordinates in the app window's pixels.
final class AppToolsTests: XCTestCase {
    private func context(_ desktop: FakeDesktop, lease: DesktopLease = DesktopLease(), taskID: TaskID = TaskID()) -> ToolContext {
        ToolContext(agentID: AgentID("agent-1"), taskID: taskID, conversationID: ConversationID("conv-1"), store: FakeStore(), desktop: desktop, lease: lease, config: HostConfig())
    }

    private func tool(_ name: String) throws -> any Tool {
        guard let tool = DesktopTools.all().first(where: { $0.spec.name == name }) else { throw XCTSkip("missing tool \(name)") }
        return tool
    }

    func testTheAppToolsNeedNoLeaseAndAreKeptOutOfTheChat() throws {
        for name in AppTools.names {
            XCTAssertFalse(try tool(name).spec.needsDesktop, "\(name) works without the owner's screen")
            XCTAssertFalse(TaskRuntime.chatTools.contains(name), "\(name) is a thread's, not the chat's")
        }
    }

    func testAClickLandsInTheWindowItWasSeenInWithoutTheLease() async throws {
        let desktop = FakeDesktop()
        let ctx = context(desktop)
        // No lease held: the owner keeps the screen.
        let seen = try await tool("app_screenshot").invoke(["app": "Notes"], context: ctx)
        XCTAssertTrue(seen.textContent.contains("in the background"), seen.textContent)
        let clicked = try await tool("app_click").invoke(["app": "Notes", "x": 400, "y": 300], context: ctx)
        XCTAssertEqual(clicked.textContent, "Pressed the “OK” button.")
        // 800x600 px of a 400x300 pt window at (100, 50): pixel (400, 300) is the window's middle, (300, 200) on the display.
        XCTAssertTrue(desktop.actions.contains("app-press 4242 300,200 left"), "\(desktop.actions)")

        _ = try await tool("app_type").invoke(["app": "Notes", "text": "Hello"], context: ctx)
        _ = try await tool("app_press_key").invoke(["app": "Notes", "keys": "return"], context: ctx)
        _ = try await tool("app_scroll").invoke(["app": "Notes", "x": 400, "y": 300, "delta_y": 200], context: ctx)
        XCTAssertTrue(desktop.actions.contains("app-type 4242 Hello"))
        XCTAssertTrue(desktop.actions.contains("app-key 4242 return"))
        XCTAssertTrue(desktop.actions.contains("app-scroll 4242 100"), "pixels scroll as window points: \(desktop.actions)")
    }

    func testAClickNeedsALookFirstAndStopsWhenTheOwnerPaused() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease()
        let ctx = context(desktop, lease: lease)
        do {
            _ = try await tool("app_click").invoke(["app": "Notes", "x": 1, "y": 1], context: ctx)
            XCTFail("clicked without having looked")
        } catch {
            XCTAssertTrue("\(error)".contains("app_screenshot"), "\(error)")
        }
        await lease.pause()
        do {
            _ = try await tool("app_screenshot").invoke(["app": "Notes"], context: ctx)
            XCTFail("worked while the owner had paused computer use")
        } catch ToolError.denied {}
        XCTAssertTrue(desktop.actions.isEmpty)
    }
}
