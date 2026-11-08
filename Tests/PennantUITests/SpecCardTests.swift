#if os(macOS)
import AppKit
import PennantCore
import SwiftUI
import XCTest
@testable import PennantUI

/// The bundled card page draws cards as pictures in one hidden web view, and a chat full of them adds no web views.
@MainActor final class SpecCardTests: XCTestCase {
    func testPicturesDrawWithOneWebView() async throws {
        XCTAssertNotNil(SpecWebView.page, "PennantCards.html is missing from the bundle")
        let before = Self.webContentProcesses().count
        let started = Date()
        var pictures: [CardPicture] = []
        for i in 0..<12 {
            let spec = try JSONDecoder().decode(JSONValue.self, from: Data(Self.brief.replacingOccurrences(of: "Good morning, Maya", with: "Card \(i)").utf8))
            let drawn = await CardPictures.shared.picture(of: spec, width: 680, appearance: .init(dark: i % 2 == 0, fontSize: 13))
            let picture = try XCTUnwrap(drawn)
            pictures.append(picture)
        }
        print("cards: 12 pictures in \(String(format: "%.2f", Date().timeIntervalSince(started))) s, heights \(Set(pictures.map { Int($0.height) }).sorted()), \(pictures[0].image.width)x\(pictures[0].image.height) px")
        XCTAssertTrue(pictures.allSatisfy { $0.height > 100 && $0.image.width >= 680 })

        // The same card again comes from what's kept.
        let again = Date()
        let spec = try JSONDecoder().decode(JSONValue.self, from: Data(Self.brief.replacingOccurrences(of: "Good morning, Maya", with: "Card 1").utf8))
        _ = await CardPictures.shared.picture(of: spec, width: 680, appearance: .init(dark: false, fontSize: 13))
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.05)

        // A chat of twelve cards adds no web views of its own.
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ScrollView { VStack(spacing: 12) { ForEach(0..<12, id: \.self) { i in
            SpecCardView(id: "card-\(i)", spec: try! JSONDecoder().decode(JSONValue.self, from: Data(Self.brief.replacingOccurrences(of: "Good morning, Maya", with: "Card \(i)").utf8)))
        } }.frame(width: 680) })
        window.orderBack(nil)
        try await Task.sleep(for: .seconds(2))
        let after = Self.webContentProcesses()
        print("cards: WebContent processes \(before) before, \(after.count) with the chat open")
        XCTAssertLessThanOrEqual(after.count - before, 1)
        if let out = ProcessInfo.processInfo.environment["PENNANT_CARD_PNG"] {
            let rep = NSBitmapImageRep(cgImage: pictures[1].image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        window.orderOut(nil)
    }

    /// Resident sizes (KB) of the WebKit content processes running now.
    static func webContentProcesses() -> [Int] {
        let ps = Process(), pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "rss=,comm="]
        ps.standardOutput = pipe
        try? ps.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: out, as: UTF8.self).split(separator: "\n")
            .filter { $0.contains("WebContent") }.compactMap { Int($0.split(separator: " ").first ?? "") }
    }

    static let brief = #"""
    {"root":"c","state":{"rows":[{"day":"Mon","n":3},{"day":"Tue","n":5}]},"elements":{
      "c":{"type":"Card","props":{"title":"Good morning, Maya","description":"Saturday"},"children":["m","t","b"]},
      "m":{"type":"Metric","props":{"label":"Mail that needs you","value":"3","detail":null,"trend":"down"}},
      "t":{"type":"Table","props":{"data":{"$state":"/rows"},"columns":[{"key":"day","label":"Day"},{"key":"n","label":"Count"}],"emptyMessage":null}},
      "b":{"type":"BarChart","props":{"title":"Sign-ups","data":{"$state":"/rows"},"xKey":"day","yKey":"n","aggregate":null,"color":null,"height":120}}}}
    """#
}
#endif
