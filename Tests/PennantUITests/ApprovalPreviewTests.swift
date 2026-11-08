#if os(macOS)
import AppKit
import PennantCore
import SwiftUI
import XCTest
@testable import PennantUI

/// A card's preview follows what it sends, read from the destinations and calls hosts put on cards.
@MainActor final class ApprovalPreviewTests: XCTestCase {
    static let task = TaskID("task")

    static var email: ApprovalRequest {
        var r = ApprovalRequest(taskID: task, title: "Reply to Dana about the renewal", destination: "Outlook · send from maya@harbor.example (to Dana)",
                                text: "Hi Dana,\n\nThanks for the redlines. Clauses 4 and 7 work for us; on 9 we'd like a 30-day notice instead of 60.\n\nBest,\nMaya")
        r.action = ApprovalAction(tool: "microsoft_365__mail_send", arguments: ["to": ["dana@okafor.example"], "cc": ["lena@harbor.example"], "subject": "Re: Harbor renewal redlines"], textField: "body")
        return r
    }
    static let post = ApprovalRequest(taskID: task, title: "LinkedIn post: what we learned shipping Harbor 2", destination: "LinkedIn · Harbor company page",
                                      text: "We shipped Harbor 2 last week. The part that took longest wasn't the sync engine but the undo button, so every change you make in Harbor can now be taken back for 30 days.\n\nWhat would you want undo for?")
    static let message = ApprovalRequest(taskID: task, title: "Text Dana", destination: "iMessage · Dana Okafor", text: "Running 10 minutes late, start without me 🙏")
    static var command: ApprovalRequest {
        var r = ApprovalRequest(taskID: task, title: "Clear the build cache", destination: "shell", text: "rm -rf ~/Library/Caches/harbor-build && du -sh ~/Library/Caches")
        r.action = ApprovalAction(tool: "shell", arguments: [:], textField: "command")
        return r
    }

    func testEachCardFindsItsKind() {
        guard case .email(let e) = ApprovalPreview.Kind(Self.email) else { return XCTFail("not an email") }
        XCTAssertEqual(e.from, "maya@harbor.example")
        XCTAssertEqual(e.to, "dana@okafor.example")
        XCTAssertEqual(e.cc, "lena@harbor.example")
        XCTAssertEqual(e.subject, "Re: Harbor renewal redlines")

        let reply = ApprovalRequest(taskID: Self.task, title: "Reply", destination: "Email reply to Lena Brandt <lena@brandt.example>", text: "Thanks!")
        guard case .email(let r) = ApprovalPreview.Kind(reply) else { return XCTFail("not an email") }
        XCTAssertTrue(r.reply)
        XCTAssertEqual(r.to, "Lena Brandt <lena@brandt.example>")

        XCTAssertEqual(ApprovalPreview.Kind(Self.post), .post(.init(platform: "LinkedIn", account: "Harbor company page", limit: 3000, color: "#0A66C2")))
        XCTAssertEqual(ApprovalPreview.Kind(ApprovalRequest(taskID: Self.task, title: "t", destination: "X · @harborapp", text: "")), .post(.init(platform: "X", account: "@harborapp", limit: 280, color: "#111111")))
        XCTAssertEqual(ApprovalPreview.Kind(Self.message), .message(.init(service: "iMessage", to: "Dana Okafor")))
        XCTAssertEqual(ApprovalPreview.Kind(Self.command), .command("This Mac"))
        XCTAssertEqual(ApprovalPreview.Kind(ApprovalRequest(taskID: Self.task, title: "Goal", destination: "Goal", text: "")), .plain)
        // "Xcode" is not X.
        XCTAssertEqual(ApprovalPreview.Kind(ApprovalRequest(taskID: Self.task, title: "t", destination: "Xcode · Harbor", text: "")), .plain)
    }

    /// PENNANT_APPROVAL_PNG=<folder> saves each card, light and dark, to look at.
    func testCardsDraw() throws {
        let folder = ProcessInfo.processInfo.environment["PENNANT_APPROVAL_PNG"]
        for (name, request) in [("email", Self.email), ("post", Self.post), ("message", Self.message), ("command", Self.command)] {
            for dark in [false, true] {
                let view = ApprovalCard(request: request).frame(width: 620).padding(16)
                    .background(dark ? Color(hex: "#151517") : .white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, name)
                XCTAssertGreaterThan(image.height, 200, name)
                if let folder {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: folder).appendingPathComponent("approval-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
#endif
