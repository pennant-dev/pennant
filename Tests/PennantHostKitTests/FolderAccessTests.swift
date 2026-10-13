import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Documents, Desktop and Downloads: a refusal in one is recognised, shows as a missing permission, and Pennant asks the
/// owner itself (macOS's prompt), not too often.
final class FolderAccessTests: XCTestCase {
    func testARefusedFolderIsRecognisedInWhatToolsSay() {
        let home = "/Users/maya"
        XCTAssertEqual(FolderAccess.blockedFolder(in: "ls: /Users/maya/Documents/Harbor Studio: Operation not permitted", home: home), "documents")
        XCTAssertEqual(FolderAccess.blockedFolder(in: #"Error Domain=NSCocoaErrorDomain Code=257 "The file “Harbor” couldn’t be opened because you don’t have permission to view it." NSFilePath=/Users/maya/Documents/Harbor"#, home: home), "documents")
        XCTAssertEqual(FolderAccess.blockedFolder(in: "cp: ~/Downloads/brief.pdf: Operation not permitted", home: home), "downloads")
        XCTAssertEqual(FolderAccess.blockedFolder(in: "cat: $HOME/Desktop/shot.png: Operation not permitted", home: home), "desktop")
        XCTAssertNil(FolderAccess.blockedFolder(in: "ln: /tmp/state.json: Operation not permitted", home: home), "not one of the private folders")
        XCTAssertNil(FolderAccess.blockedFolder(in: "ls: /Users/maya/Documents/Harbor: No such file or directory", home: home), "not a refusal")
    }

    func testABlockedFolderIsAMissingPermission() throws {
        let p = DesktopPermissions(accessibility: true, screenRecording: true, inputMonitoring: true, folders: ["documents": .denied, "desktop": .granted])
        XCTAssertFalse(p.allGranted)
        XCTAssertEqual(p.missing, ["Documents folder"])
        XCTAssertTrue(DesktopPermissions(accessibility: true, screenRecording: true, folders: ["documents": .granted]).allGranted)
        // An older host's report, without folders, still reads.
        let old = #"{"accessibility":true,"screenRecording":true,"automation":true,"inputMonitoring":true,"automationTargets":{},"grantee":"Pennant Host"}"#
        let decoded = try JSONDecoder().decode(DesktopPermissions.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.folders, [:])
        XCTAssertEqual(PermissionCheck.tccService(for: "documents"), "SystemPolicyDocumentsFolder")
        XCTAssertEqual(PermissionCheck.tccService(for: "downloads"), "SystemPolicyDownloadsFolder")
        // macOS files the folders, like Apple Events, under the app the host is inside, so that's the answer Grant clears.
        XCTAssertEqual(PermissionCheck.tccClient(for: "documents"), PermissionCheck.tccClient(for: "com.apple.finder"))
    }

    actor Asked {
        var keys: [String] = []
        func add(_ key: String) { keys.append(key) }
    }

    /// Work that hits a blocked folder: Pennant asks the owner then (macOS's prompt), and not again for a while; the model
    /// is told to say so in a line, never to send them to System Settings.
    func testPennantAsksForABlockedFolderItselfAndNotTooOften() async throws {
        let asked = Asked()
        let asks = FolderAsks(ask: { key in await asked.add(key); return .granted }, check: { _ in .denied })
        let now = Date()
        let firstNote = await asks.blocked("documents", now: now)
        let first = try XCTUnwrap(firstNote)
        XCTAssertTrue(first.contains("Pennant would like to access files in your Documents folder"), first)
        XCTAssertTrue(first.contains("click Allow"))
        XCTAssertTrue(first.contains("don't send them to System Settings"))
        let soonNote = await asks.blocked("documents", now: now.addingTimeInterval(600))
        let soon = try XCTUnwrap(soonNote)
        XCTAssertTrue(soon.contains("a little while ago"), soon)
        _ = await asks.blocked("documents", now: now.addingTimeInterval(FolderAsks.again + 1))
        try await Task.sleep(for: .milliseconds(100))
        let keys = await asked.keys
        XCTAssertEqual(keys, ["documents", "documents"], "asked at first, then again only after a while")

        let allowed = FolderAsks(ask: { _ in .granted }, check: { _ in .granted })
        let none = await allowed.blocked("documents")
        XCTAssertNil(none, "the folder is allowed: the refusal was about something else")
    }
}
