import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// AppleScript that drives the owner's Chrome takes over the window they're working in: the chat hands that to a
/// thread, and a thread works in its own tabs once the extension is connected. Looking at what's open stays allowed.
final class ChromeGuardTests: XCTestCase {
    func testDrivingChromeIsToldApartFromLookingAtIt() {
        let drives = [
            #"osascript -e 'tell application "Google Chrome" to activate'"#,
            "osascript <<'EOF'\ntell application \"Google Chrome\"\n  make new tab at end of tabs of window 1 with properties {URL:\"https://example.com\"}\nend tell\nEOF",
            "cat > /tmp/go.applescript <<'EOF'\ntell application \"Google Chrome\"\n\tset URL of active tab of window 1 to \"https://example.com\"\nend tell\nEOF\nosascript /tmp/go.applescript",
            #"osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "document.querySelector(\"button\").click()"'"#,
            #"osascript -l JavaScript -e "Application('Google Chrome').activate()""#,
            #"osascript -e "tell application id \"com.google.Chrome\" to reload active tab of front window""#,
        ]
        for command in drives { XCTAssertTrue(ChromeGuard.drivesChrome(command), command) }

        let looks = [
            #"osascript -e 'tell application "Google Chrome" to get URL of active tab of front window'"#,
            "osascript <<'EOF'\ntell application \"Google Chrome\"\nset out to \"\"\nrepeat with w in windows\nrepeat with t in tabs of w\nset out to out & (title of t) & linefeed\nend repeat\nend repeat\nreturn out\nend tell\nEOF",
            #"osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "document.body.innerText.slice(0, 2000)"'"#,
            #"osascript -e 'tell application "Safari" to activate'"#,
            #"open -a "Google Chrome" ~/Desktop/report.html"#,
            #"osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'"#,
        ]
        for command in looks { XCTAssertFalse(ChromeGuard.drivesChrome(command), command) }
    }

    /// A script osascript runs from a file is judged by what's in it, wherever the command runs it from.
    func testAScriptFileIsReadForWhatItDoes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "on run argv\n\ttell application \"Google Chrome\"\n\t\tactivate\n\t\tset URL of active tab of window 1 to item 1 of argv\n\tend tell\nend run\n"
            .write(to: folder.appendingPathComponent("go.applescript"), atomically: true, encoding: .utf8)
        try "tell application \"Google Chrome\" to get URL of active tab of front window\n"
            .write(to: folder.appendingPathComponent("look.applescript"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ChromeGuard.drivesChrome("osascript \(folder.path)/go.applescript 'https://example.com' >/dev/null 2>&1; sleep 4"))
        XCTAssertTrue(ChromeGuard.drivesChrome("cd \(folder.path) && osascript go.applescript 'https://example.com'"))
        XCTAssertTrue(ChromeGuard.drivesChrome("osascript go.applescript 'https://example.com'", in: folder.path))
        XCTAssertFalse(ChromeGuard.drivesChrome("osascript \(folder.path)/look.applescript"))
        XCTAssertFalse(ChromeGuard.drivesChrome("osascript \(folder.path)/missing.applescript"))
    }

    func testTheChatStartsAThreadInsteadOfDrivingChromeButMayLook() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        // `true ||` keeps osascript itself from running here.
        let drive = ToolCall(id: ToolCallID("d1"), name: "shell", arguments: ["command": .string(#"true || osascript -e 'tell application "Google Chrome" to activate'"#)])
        let look = ToolCall(id: ToolCallID("l1"), name: "shell", arguments: ["command": .string(#"true || osascript -e 'tell application "Google Chrome" to get URL of active tab of front window'"#)])
        let provider = ScriptedProvider([])
        provider.chatTurns = [.init(toolCalls: [drive]), .init(toolCalls: [look]), .init(text: "I'll have a thread do that.")]
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let chat = try await s.runtime.ensureMainChat()
        let (_, _, ask) = try await s.runtime.submitUserMessage(agentID: chat.agentID, conversationID: chat.id, text: "Open my GitHub notifications in Chrome", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(ask)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }

        let records = try await s.store.toolRecords(taskID: ask)
        let refused = try XCTUnwrap(records.first { $0.call.id == drive.id })
        XCTAssertEqual(refused.status, .denied)
        XCTAssertEqual(refused.resultSummary, "Drives the owner's Chrome")
        let looked = try XCTUnwrap(records.first { $0.call.id == look.id })
        XCTAssertEqual(looked.status, .succeeded, "looking at which page is open stays allowed")
        let told = provider.requests.flatMap(\.messages).map(\.text).first { $0.contains("Refused: this drives the owner's Chrome") } ?? ""
        XCTAssertTrue(told.contains("Start a thread for it"), told)
        let chatPrompt = provider.requests.first?.messages.first?.text ?? ""
        XCTAssertTrue(chatPrompt.contains("or in another app goes to a thread however quick it looks"), chatPrompt)
        await s.stop()
    }

    /// Without the extension, a thread still has AppleScript to fall back on.
    func testAThreadWithoutTheExtensionMayStillDriveChrome() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let drive = ToolCall(id: ToolCallID("d1"), name: "shell", arguments: ["command": .string(#"true || osascript -e 'tell application "Google Chrome" to activate'"#)])
        let provider = ScriptedProvider([.init(toolCalls: [drive]), .init(text: "Done.")])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Open the page in Chrome", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, try await s.store.task(taskID)?.state != .completed { try await Task.sleep(for: .milliseconds(20)) }
        let records = try await s.store.toolRecords(taskID: taskID)
        XCTAssertEqual(records.first { $0.call.id == drive.id }?.status, .succeeded)
        await s.stop()
    }
}
