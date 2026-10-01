import AppKit
import ApplicationServices
import CoreGraphics
import PennantCore
import Foundation
import IOKit.hid

/// macOS privacy permission checks and prompts for the host process.
///
/// - Accessibility: synthesised keyboard/mouse events and the AX tree.
/// - Screen Recording: ScreenCaptureKit screenshots and the live stream. Takes effect after the process restarts.
/// - Input Monitoring: the keyboard half of the pause-on-human-input tap.
/// - Automation: Apple events to each target app, checked with `AEDeterminePermissionToAutomateTarget`.
///
/// Grants are attributed to the "responsible" process: the app when it spawned the host, or `pennant-host`
/// itself when launchd started it. `grantee()` reports which.
public enum PermissionCheck {
    /// Apple event targets the tools rely on. Browsers are included when installed.
    public static var automationTargets: [String] {
        var targets = ["com.apple.systemevents", "com.apple.finder", "com.apple.Safari"]
        for extra in ["com.google.Chrome", "com.microsoft.edgemac"] where NSWorkspace.shared.urlForApplication(withBundleIdentifier: extra) != nil {
            targets.append(extra)
        }
        return targets
    }

    public static func accessibility(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    public static func screenRecording() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the Screen Recording prompt (once), then macOS lists the process in System Settings.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    public static func inputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        if inputMonitoring() { return true }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Automation consent for one target. `ask` shows the consent dialog if the user has not decided yet
    /// (the target must be running for macOS to show it).
    public static func automation(target bundleID: String, ask: Bool = false) -> PermissionState {
        // macOS can block this call indefinitely (a target app launching, quitting or being removed, a stuck consent
        // prompt). Run it on its own thread with a time limit so a hung check never stalls the host; a target whose
        // check is still hung is reported unknown, not asked again, until that check returns.
        if hungTargets.get().contains(bundleID) { return .unknown }
        let done = DispatchSemaphore(value: 0)
        let result = Locked(PermissionState.unknown)
        automationQueue.async {
            result.set(automationNow(target: bundleID, ask: ask))
            hungTargets.set(hungTargets.get().subtracting([bundleID]))
            done.signal()
        }
        if done.wait(timeout: .now() + (ask ? 120 : 2)) == .timedOut {
            hungTargets.set(hungTargets.get().union([bundleID]))
            log.warn("Automation permission check for \(bundleID) did not return; reporting unknown until it does", category: "desktop")
            return .unknown
        }
        return result.get()
    }

    private static let automationQueue = DispatchQueue(label: "dev.pennant.automation-permission", attributes: .concurrent)
    private static let hungTargets = Locked(Set<String>())

    private static func automationNow(target bundleID: String, ask: Bool) -> PermissionState {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = descriptor.aeDesc else { return .unknown }
        let wildcard: AEEventClass = 0x2A2A2A2A // '****'
        let status = AEDeterminePermissionToAutomateTarget(address, wildcard, AEEventID(wildcard), ask)
        switch status {
        case noErr: return .granted
        case -1743: return .denied            // errAEEventNotPermitted
        case -1744: return .notDetermined     // errAEEventWouldRequireUserConsent
        case -600: return .unknown            // procNotFound: target not running
        default:
            log.warn("AEDeterminePermissionToAutomateTarget(\(bundleID)) returned \(status); if the host is signed with the hardened runtime it needs the com.apple.security.automation.apple-events entitlement", category: "desktop")
            return .unknown
        }
    }

    public static func automationStates() -> [String: PermissionState] {
        var out: [String: PermissionState] = [:]
        for target in automationTargets { out[target] = automation(target: target) }
        return out
    }

    /// Legacy summary: System Events consent, treated as granted when it cannot be determined.
    public static func automation() -> Bool {
        let state = automation(target: "com.apple.systemevents")
        return state == .granted || state == .unknown
    }

    /// Messages, which the iMessage channel sends through.
    public static let messagesBundleID = "com.apple.MobileSMS"

    /// The app System Settings lists for this host's Full Disk Access: this bundle when it's responsible for itself,
    /// else the app that started it. Nil when it isn't an app (a development build).
    public static func granteeAppPath() -> String? {
        if grantee() == hostDisplayName { return Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : nil }
        var url = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0 ..< 6 {
            if url.pathExtension == "app" { return url.path }
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Which process macOS will attribute grants to.
    public static var hostDisplayName: String {
        Bundle.main.bundlePath.hasSuffix(".app") ? "Pennant Host" : "pennant-host"
    }

    /// TCC service name for a request target.
    public static func tccService(for target: String) -> String {
        switch target.lowercased() {
        case "accessibility": return "Accessibility"
        case "screenrecording": return "ScreenCapture"
        case "inputmonitoring": return "ListenEvent"
        default: return "AppleEvents"
        }
    }

    /// Bundle identifier of the app that contains this helper, when it runs from `Pennant.app/Contents/Helpers`.
    /// macOS attributes Apple Events consent for an embedded helper to that outer app.
    public static func outerBundleIdentifier() -> String? {
        var url = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0 ..< 6 {
            if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier { return id }
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// The identity System Settings keys a service to: the outer app for Apple Events, this bundle otherwise.
    public static func tccClient(for target: String) -> String {
        let own = Bundle.main.bundleIdentifier ?? "dev.pennant.host"
        return tccService(for: target) == "AppleEvents" ? (outerBundleIdentifier() ?? own) : own
    }

    /// `tccutil reset <service> <client>`: clears the entry so the next request prompts again.
    /// Entries left by earlier copies at other paths are not touched; remove those in System Settings.
    public static func reset(target: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", tccService(for: target), tccClient(for: target)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public static func grantee() -> String {
        let parent = getppid()
        if parent == 1 || ProcessInfo.processInfo.environment["PENNANT_SELF_RESPONSIBLE"] == "1" { return hostDisplayName }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(parent, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "pennant-host" }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]).split(separator: "/").last.map(String.init)?.replacingOccurrences(of: ".app", with: "") ?? "pennant-host"
        }
        return (path as NSString).lastPathComponent
    }

    public static func current() -> DesktopPermissions {
        DesktopPermissions(accessibility: accessibility(), screenRecording: screenRecording(), automation: automation(), inputMonitoring: inputMonitoring(), automationTargets: automationStates(), grantee: grantee())
    }

    /// Request the listed permissions ("accessibility", "screenRecording", "inputMonitoring", "automation", or a
    /// bundle id). Empty means all. Runs the prompts on the main thread and returns the state afterwards.
    @MainActor
    public static func request(_ targets: [String]) async -> DesktopPermissions {
        let wanted = Set(targets.map { $0.lowercased() })
        func wants(_ key: String) -> Bool { wanted.isEmpty || wanted.contains(key.lowercased()) }

        if wants("accessibility"), !accessibility() { _ = accessibility(prompt: true) }
        if wants("screenRecording"), !screenRecording() { requestScreenRecording() }
        if wants("inputMonitoring"), !inputMonitoring() { requestInputMonitoring() }

        // Messages is asked for only by name (the iMessage channel's setup), never with "all".
        let automationTargetsToAsk = automationTargets.filter { wants("automation") || wants($0) }
            + (wanted.contains(messagesBundleID.lowercased()) ? [messagesBundleID] : [])
        for target in automationTargetsToAsk where automation(target: target) != .granted {
            // The consent dialog needs the target running. Launch it hidden if necessary; never for browsers
            // unless the user asked for that target explicitly.
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: target).isEmpty
            let isBrowser = !["com.apple.systemevents", "com.apple.finder", messagesBundleID].contains(target)
            if !running {
                guard !isBrowser || wanted.contains(target.lowercased()) || wants("automation"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else { continue }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                try? await Task.sleep(for: .seconds(1.5))
            }
            _ = automation(target: target, ask: true)
        }
        return current()
    }

    /// Evaluate permissions in a fresh copy of this executable. macOS caches Screen Recording (and sometimes
    /// Accessibility) per process, so the running host would keep reporting "missing" after a grant.
    /// The helper inherits the same responsible process, so it sees exactly what this host would see after a restart.
    /// Whether this process is the real host executable (never spawn a copy of a test runner or the app).
    public static var canSpawnHelper: Bool {
        (Bundle.main.executableURL?.lastPathComponent ?? "") == "pennant-host"
    }

    public static func fresh(timeout: TimeInterval = 6) async -> DesktopPermissions? {
        guard canSpawnHelper, let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--check-permissions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask { pipe.fileHandleForReading.readDataToEndOfFile() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let data, !data.isEmpty, let permissions = try? JSONCodec.decode(DesktopPermissions.self, from: data) else { return nil }
        return permissions
    }

    /// True when a grant exists (fresh) that this process cannot use until it restarts.
    public static func restartNeeded(fresh: DesktopPermissions, inProcess: DesktopPermissions) -> Bool {
        (fresh.accessibility && !inProcess.accessibility) || (fresh.screenRecording && !inProcess.screenRecording) || (fresh.inputMonitoring && !inProcess.inputMonitoring)
    }

    /// Map a `DesktopError.permissionMissing` label to request targets.
    public static func targets(forMissing label: String) -> [String] {
        let l = label.lowercased()
        if l.contains("accessibility") { return ["accessibility"] }
        if l.contains("screen") { return ["screenRecording"] }
        if l.contains("input monitoring") { return ["inputMonitoring"] }
        if l.contains("automation") { return ["automation"] }
        return []
    }
}
