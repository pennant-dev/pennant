import CoreGraphics
import PennantCore
@testable import PennantHostKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic desktop double: records every action, never touches the real machine.
public final class FakeDesktop: DesktopControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    public var permissionsValue = DesktopPermissions(accessibility: true, screenRecording: true, automation: true)
    public var displayWidth = 1600
    public var displayHeight = 1000
    public var interruptCount = 0
    public var apps: [RunningApp] = [
        RunningApp(name: "Finder", bundleID: "com.apple.finder", pid: 101, isFrontmost: false, windowTitles: ["Documents"]),
        RunningApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 202, isFrontmost: true, windowTitles: ["Untitled"]),
    ]
    public var nodes: [AXNode] = [
        AXNode(index: 0, role: "AXWindow", title: "Untitled", value: "", description: "", x: 100, y: 50, width: 800, height: 600, enabled: true, focused: false, depth: 1, actions: ["AXRaise"]),
        AXNode(index: 1, role: "AXButton", title: "Save", value: "", description: "", x: 400, y: 80, width: 96, height: 24, enabled: true, focused: false, depth: 2, actions: ["AXPress"]),
        AXNode(index: 2, role: "AXTextArea", title: "", value: "Hello", description: "document text", x: 120, y: 120, width: 760, height: 500, enabled: true, focused: true, depth: 2, actions: []),
    ]

    public init() {}

    public var actions: [String] { lock.withLock { recorded } }
    private func record(_ line: String) { lock.withLock { recorded.append(line) } }

    /// A real, tiny JPEG so image decoders accept it.
    public static let tinyJPEG: Data = {
        let width = 8, height = 8
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    public func permissions() async -> DesktopPermissions { permissionsValue }
    public func requestPermissions(targets: [String]) async -> DesktopPermissions { record("requestPermissions(\(targets.joined(separator: ",")))"); return permissionsValue }

    public func captureScreen(maxWidth: Int) async throws -> CapturedScreen {
        record("captureScreen(\(maxWidth))")
        let width = min(maxWidth, displayWidth)
        let height = Int((Double(width) * Double(displayHeight) / Double(displayWidth)).rounded())
        return CapturedScreen(jpeg: Self.tinyJPEG, width: width, height: height, displayWidth: displayWidth, displayHeight: displayHeight, cursorX: 10, cursorY: 10)
    }

    public func displaySize() async -> (width: Int, height: Int) { (displayWidth, displayHeight) }

    public func moveMouse(x: Double, y: Double) async throws { record("move(\(Int(x)),\(Int(y)))") }
    public func livePointer(_ input: RemoteInput, x: Double, y: Double) async throws {
        let kind: String
        switch input {
        case .pointerMove: kind = "move"
        case .pointerDown(_, _, let b): kind = "down-\(b.rawValue)"
        case .pointerUp(_, _, let b): kind = "up-\(b.rawValue)"
        case .click(_, _, let b, let n): kind = "click-\(b.rawValue)x\(n)"
        default: kind = "other"
        }
        record("live-\(kind)(\(Int(x)),\(Int(y)))")
    }
    public func click(x: Double, y: Double, button: PointerButton, count: Int) async throws { record("click(\(Int(x)),\(Int(y)),\(button.rawValue),\(count))") }
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws { record("drag(\(Int(fromX)),\(Int(fromY))->\(Int(toX)),\(Int(toY)))") }
    public func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws { record("scroll(\(Int(x)),\(Int(y)),\(Int(deltaX)),\(Int(deltaY)))") }
    public func typeText(_ text: String) async throws { record("type(\(text))") }
    public func pressKey(_ chord: KeyChord) async throws {
        var mods: [String] = []
        if chord.command { mods.append("cmd") }
        if chord.shift { mods.append("shift") }
        if chord.option { mods.append("option") }
        if chord.control { mods.append("ctrl") }
        record("key(" + (mods + [chord.key]).joined(separator: "+") + ")")
    }

    public func runningApps() async -> [RunningApp] { apps }
    public func frontmostApp() async -> RunningApp? { apps.first { $0.isFrontmost } }
    public func launchApp(nameOrBundleID: String) async throws -> RunningApp {
        record("launch(\(nameOrBundleID))")
        if let existing = apps.first(where: { $0.name.lowercased() == nameOrBundleID.lowercased() || $0.bundleID == nameOrBundleID }) { return existing }
        if nameOrBundleID.lowercased() == "missing" { throw DesktopError.appNotFound(nameOrBundleID) }
        return RunningApp(name: nameOrBundleID, bundleID: nil, pid: 999, isFrontmost: true)
    }
    public func activateApp(nameOrBundleID: String) async throws -> RunningApp {
        record("activate(\(nameOrBundleID))")
        guard let app = apps.first(where: { $0.name.lowercased() == nameOrBundleID.lowercased() || $0.bundleID == nameOrBundleID }) else { throw DesktopError.appNotFound(nameOrBundleID) }
        return app
    }

    public func accessibilityTree(pid: Int32?, maxDepth: Int, maxNodes: Int) async throws -> [AXNode] {
        record("tree(\(pid.map(String.init) ?? "front"),\(maxDepth),\(maxNodes))")
        return Array(nodes.prefix(maxNodes))
    }
    public func performAXAction(index: Int, action: String) async throws {
        guard nodes.indices.contains(index) else { throw DesktopError.inputFailed("No UI node with index \(index)") }
        record("axAction(\(index),\(action))")
    }
    public func setAXValue(index: Int, value: String) async throws {
        guard nodes.indices.contains(index) else { throw DesktopError.inputFailed("No UI node with index \(index)") }
        record("axSet(\(index),\(value))")
    }

    public func runAppleScript(_ source: String) async throws -> String { record("applescript"); return "ok:" + source }
    public func runJavaScriptForAutomation(_ source: String) async throws -> String { record("jxa"); return "ok:" + source }

    public func screenStream(options: ScreenStreamOptions) -> AsyncStream<CapturedScreen> {
        AsyncStream { continuation in
            continuation.yield(CapturedScreen(jpeg: Self.tinyJPEG, width: 8, height: 8, displayWidth: displayWidth, displayHeight: displayHeight))
            continuation.finish()
        }
    }

    public func interruptInput() async { lock.withLock { interruptCount += 1 }; record("interrupt") }
    public func showCursor(x: Double, y: Double, click: Bool) async { record("cursor \(Int(x)),\(Int(y))\(click ? " click" : "")") }

    /// The app window background tools see: 400x300 points at (100, 50), drawn at 800x600 pixels.
    public var windowFrame = CGRect(x: 100, y: 50, width: 400, height: 300)
    public func captureWindow(app: String, title: String?, maxWidth: Int) async throws -> WindowCapture {
        record("window \(app)")
        return WindowCapture(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 800, height: 600, frame: windowFrame, title: "Untitled",
                             app: RunningApp(name: app, bundleID: nil, pid: 4242, isFrontmost: false))
    }
    public func pressInApp(pid: Int32, x: Double, y: Double, button: PointerButton, count: Int) async throws -> String {
        record("app-press \(pid) \(Int(x)),\(Int(y)) \(button.rawValue)")
        return "Pressed the “OK” button."
    }
    public func typeInApp(pid: Int32, text: String) async throws -> String { record("app-type \(pid) \(text)"); return "Typed into the text field." }
    public func keyInApp(pid: Int32, chord: KeyChord) async throws { record("app-key \(pid) \(chord.key)") }
    public func scrollInApp(pid: Int32, x: Double, y: Double, deltaX: Double, deltaY: Double) async throws { record("app-scroll \(pid) \(Int(deltaY))") }
}
