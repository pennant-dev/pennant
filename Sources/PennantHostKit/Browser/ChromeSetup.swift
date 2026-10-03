import AppKit
import ApplicationServices
import PennantCore
import Foundation

/// "Set it up for me": Pennant adds its extension to Chrome the way a person would, since Chrome lets no app add one
/// by itself. It opens Chrome's Extensions page, turns on Developer mode, clicks Load unpacked and picks the
/// extension's folder. The page's controls are found by name and pressed through Accessibility, without Chrome in
/// front. The folder picker only takes keys typed the ordinary way, into the app in front, so Chrome comes forward for
/// that step, each key waits until Chrome is in front, and the owner's app gets the front back afterwards.
struct ChromeSetup: Sendable {
    /// Chrome, or another channel of it ("com.google.Chrome.beta", Chrome for Testing).
    var bundleID: String
    var folder: URL
    var showCursor: @Sendable (CGPoint, Bool) async -> Void
    /// A key typed the ordinary way, into the app in front.
    var pressKey: @Sendable (KeyChord) async throws -> Void
    var isConnected: @Sendable () async -> Bool

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func run() async throws {
        guard AXIsProcessTrusted() else { throw Failure("Pennant needs Accessibility for this; turn it on in Settings › Permissions.") }
        // The Chrome that's open, when it is: another copy on the Mac would start beside it.
        guard let appURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw Failure("Chrome isn't installed on this Mac.")
        }
        let previous = AppControl.frontmostPID().flatMap { NSRunningApplication(processIdentifier: $0) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        guard let page = URL(string: "chrome://extensions") else { return }
        let chrome = try await NSWorkspace.shared.open([page], withApplicationAt: appURL, configuration: configuration)
        let pid = chrome.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)

        // Added before, and Chrome was only closed: the extension connects as soon as Chrome is open.
        if await wait(seconds: 4, until: { await isConnected() }) { return }
        AccessibilityReader.enableWebAccessibilityIfNeeded(app: app, pid: pid)

        guard let devMode = await poll(seconds: 15, { Self.find(in: app, role: "AXCheckBox", named: "Developer mode") }) else {
            throw Failure("Pennant couldn't find Developer mode on Chrome's Extensions page.")
        }
        if AccessibilityReader.bool(devMode, kAXValueAttribute) != true { try await press(devMode) }
        guard let load = await poll(seconds: 5, { Self.find(in: app, role: "AXButton", named: "Load unpacked") }) else {
            throw Failure("Developer mode is on, but Pennant couldn't find Load unpacked.")
        }
        try await press(load)
        guard let picker = await poll(seconds: 6, { Self.find(in: app, role: "AXSheet", named: nil) }) else {
            throw Failure("Chrome's folder picker didn't open.")
        }

        // The picker takes keys only while Chrome is in front. From here a failure leaves it open for the owner.
        let left = " Chrome's folder picker is still open: press ⌘⇧G in it and paste the folder's path (Copy its path, below)."
        await AppControl.bringToFront(chrome)
        do {
            try await pickFolder(app: app, pid: pid, picker: picker, left: left)
        } catch {
            await giveBack(previous, pid: pid)
            throw error
        }
        await giveBack(previous, pid: pid)

        guard await wait(seconds: 15, until: { await isConnected() }) else {
            throw Failure("Chrome took the folder, but the extension didn't connect. Pennant's card on chrome://extensions may show why.")
        }
    }

    /// Go to Folder in Chrome's open folder picker, the extension's folder, then Select.
    private func pickFolder(app: AXUIElement, pid: pid_t, picker: AXUIElement, left: String) async throws {
        func key(_ chord: KeyChord) async throws {
            guard AppControl.frontmostPID() == pid else {
                throw Failure("Chrome didn't stay in front, so Pennant stopped typing." + left)
            }
            try await pressKey(chord)
        }
        try await Task.sleep(for: .milliseconds(400))
        let before = Self.focused(app)
        try await key(KeyChord(key: "g", command: true, shift: true))
        guard let field = await poll(seconds: 3, {
            guard let now = Self.focused(app), before.map({ !CFEqual($0, now) }) ?? true,
                  BackgroundInput.textRoles.contains(AccessibilityReader.string(now, kAXRoleAttribute)) else { return nil }
            return now
        }) else {
            throw Failure("The folder picker's Go to Folder box didn't open." + left)
        }
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, folder.path as CFString)
        try await Task.sleep(for: .milliseconds(300))
        try await key(KeyChord(key: "return"))
        try await Task.sleep(for: .milliseconds(1200))
        if let select = Self.find(in: picker, role: "AXButton", named: "Select") {
            try await press(select)
        } else {
            try await key(KeyChord(key: "return"))
        }
    }

    /// The app that was in front before Chrome came forward gets the front back.
    private func giveBack(_ previous: NSRunningApplication?, pid: pid_t) async {
        guard let previous, previous.processIdentifier != pid, !previous.isTerminated else { return }
        await AppControl.bringToFront(previous)
        log.info("Chrome setup gave the front back to \(previous.bundleIdentifier ?? "pid \(previous.processIdentifier)")", category: "browser")
    }

    // MARK: Steps

    private func press(_ element: AXUIElement) async throws {
        if let center = AccessibilityReader.center(element) { await showCursor(center, true) }
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else { throw Failure("Pressing \(BackgroundInput.describe(element)) failed (\(error.rawValue)).") }
        try await Task.sleep(for: .milliseconds(500))
    }

    private func poll(seconds: Double, _ look: () -> AXUIElement?) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = look() { return found }
            try? await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline
        return nil
    }

    private func wait(seconds: Double, until done: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await done() { return true }
            try? await Task.sleep(for: .milliseconds(400))
        } while Date() < deadline
        return false
    }

    // MARK: Finding things

    /// The first element of `role` whose name is `name` (any name when nil), breadth first under `root`.
    static func find(in root: AXUIElement, role: String, named name: String?) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if AccessibilityReader.string(element, kAXRoleAttribute) == role,
               name.map({ name in [kAXTitleAttribute, kAXDescriptionAttribute].contains { AccessibilityReader.string(element, $0).caseInsensitiveCompare(name) == .orderedSame } }) ?? true {
                return element
            }
            if depth < 60 { queue.append(contentsOf: AccessibilityReader.children(element).map { ($0, depth + 1) }) }
        }
        return nil
    }

    private static func focused(_ app: AXUIElement) -> AXUIElement? {
        guard let focused = AccessibilityReader.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(focused, to: AXUIElement.self)
    }
}
