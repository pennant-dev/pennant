import AppKit
import ApplicationServices
import PennantCore
import Foundation

/// Launching, activating, listing, and quitting applications through NSWorkspace.
enum AppControl {
    @MainActor
    static func describe(_ app: NSRunningApplication, frontmostPID: pid_t?, windowTitles: [String] = []) -> RunningApp {
        RunningApp(
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            bundleID: app.bundleIdentifier,
            pid: app.processIdentifier,
            isFrontmost: app.processIdentifier == frontmostPID,
            windowTitles: windowTitles
        )
    }

    /// Regular (Dock-visible) apps. Window titles are read through Accessibility off the main thread.
    static func runningApps(includeWindows: Bool) async -> [RunningApp] {
        let basics: [RunningApp] = await MainActor.run {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .map { describe($0, frontmostPID: frontmost) }
        }
        guard includeWindows else { return basics }
        return basics.map { app in
            var copy = app
            copy.windowTitles = AccessibilityReader.windowTitles(pid: app.pid)
            return copy
        }
    }

    static func frontmost() async -> RunningApp? {
        let basic: RunningApp? = await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return describe(app, frontmostPID: app.processIdentifier)
        }
        guard var app = basic else { return nil }
        app.windowTitles = AccessibilityReader.windowTitles(pid: app.pid)
        return app
    }

    @MainActor
    static func findRunning(_ reference: String) -> NSRunningApplication? {
        let needle = reference.lowercased().trimmingCharacters(in: .whitespaces)
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let pid = Int32(needle), let app = apps.first(where: { $0.processIdentifier == pid }) { return app }
        if let app = apps.first(where: { $0.bundleIdentifier?.lowercased() == needle }) { return app }
        if let app = apps.first(where: { $0.localizedName?.lowercased() == needle }) { return app }
        let stripped = needle.hasSuffix(".app") ? String(needle.dropLast(4)) : needle
        if let app = apps.first(where: { $0.localizedName?.lowercased() == stripped }) { return app }
        return apps.filter { $0.activationPolicy == .regular }.first(where: { ($0.localizedName?.lowercased() ?? "").contains(stripped) })
    }

    /// Resolve an app name, bundle identifier, or path to an application URL.
    static func resolveURL(_ reference: String) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) { return URL(fileURLWithPath: trimmed) }
        if trimmed.contains("."), !trimmed.contains(" "), !trimmed.hasSuffix(".app"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) { return url }
        let name = (trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed).lowercased()
        let directories = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                           NSHomeDirectory() + "/Applications", "/System/Library/CoreServices", "/System/Library/CoreServices/Applications"]
        var candidates: [(name: String, url: URL)] = []
        for directory in directories {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for item in items where item.lowercased().hasSuffix(".app") {
                let base = String(item.dropLast(4))
                let url = URL(fileURLWithPath: directory).appendingPathComponent(item)
                if base.lowercased() == name { return url }
                candidates.append((base, url))
            }
        }
        // Fuzzy match: "chrome" → "Google Chrome"; prefer the shortest matching name.
        let fuzzy = candidates.filter { $0.name.lowercased().contains(name) }.sorted { $0.name.count < $1.name.count }
        return fuzzy.first?.url
    }

    @MainActor
    static func launch(_ reference: String) async throws -> RunningApp {
        if let running = findRunning(reference) {
            await bringToFront(running)
            return describe(running, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        guard let url = resolveURL(reference) else { throw DesktopError.appNotFound(reference) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw DesktopError.appNotFound("\(reference): \(error.localizedDescription)")
        }
        _ = await waitUntilFrontmost(app.processIdentifier, timeout: 3)
        return describe(app, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    @MainActor
    static func activate(_ reference: String) async throws -> RunningApp {
        guard let app = findRunning(reference) else { throw DesktopError.appNotFound(reference) }
        await bringToFront(app)
        return describe(app, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Cooperative activation on macOS 14+ can refuse a background process; fall back to AX and Apple events.
    @MainActor
    static func bringToFront(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        app.unhide()
        app.activate(options: [.activateAllWindows])
        if await waitUntilFrontmost(pid, timeout: 1.0) { return }

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if await waitUntilFrontmost(pid, timeout: 1.0) { return }

        if let bundleID = app.bundleIdentifier {
            _ = try? Scripting.runAppleScript("tell application id \"\(bundleID)\" to activate")
            _ = await waitUntilFrontmost(pid, timeout: 1.5)
        }
    }

    @MainActor
    static func waitUntilFrontmost(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if frontmostPID() == pid { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return frontmostPID() == pid
    }

    /// The app in front, as the window server has it. NSWorkspace's answer can lag in a background process.
    static func frontmostPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        if let focused = AccessibilityReader.attribute(system, kAXFocusedApplicationAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(unsafeDowncast(focused, to: AXUIElement.self), &pid) == .success { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
