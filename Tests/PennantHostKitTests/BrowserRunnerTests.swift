@testable import PennantHostKit
import Foundation
import XCTest

final class BrowserRunnerTests: XCTestCase {
    /// A stopped task takes its script with it: nothing left running (a browser window, say).
    func testAScriptStopsWhenItsTaskIsCancelled() async throws {
        let marker = "41.\(Int.random(in: 1000 ... 9999))"
        let run = Task { try await BrowserRunner.run(executable: "/bin/sleep", arguments: [marker], cwd: URL(fileURLWithPath: NSTemporaryDirectory()), stdin: nil, timeout: 60) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(Self.running(marker), "the script started")
        run.cancel()
        _ = try? await run.value
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(Self.running(marker), "the script outlived its task")
    }

    static func running(_ marker: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "sleep \(marker)"]
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
