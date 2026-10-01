import AppKit
import PennantCore
import Foundation

/// AppleScript (in-process, main thread) and JavaScript for Automation (osascript subprocess).
enum Scripting {
    private static let listType: DescType = 0x6C69_7374 // 'list'
    private static let nullType: DescType = 0x6E75_6C6C // 'null'

    @MainActor
    static func runAppleScript(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw DesktopError.scriptFailed("Could not parse AppleScript") }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            let suffix = number.map { " (error \($0))" } ?? ""
            if number == -1743 {
                throw DesktopError.permissionMissing("Automation for the target application")
            }
            throw DesktopError.scriptFailed(message + suffix)
        }
        return describe(result)
    }

    static func describe(_ descriptor: NSAppleEventDescriptor) -> String {
        if descriptor.descriptorType == listType {
            guard descriptor.numberOfItems > 0 else { return "" }
            return (1 ... descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }.map(describe).joined(separator: "\n")
        }
        if descriptor.descriptorType == nullType { return "" }
        return descriptor.stringValue ?? descriptor.description
    }

    static func runJXA(_ source: String, timeout: TimeInterval = 60) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-jxa-\(UUID().uuidString).js")
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-l", "JavaScript", file.path], timeout: timeout)
        if result.timedOut { throw DesktopError.scriptFailed("JXA timed out after \(Int(timeout)) s") }
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DesktopError.scriptFailed(message.isEmpty ? "osascript exited with \(result.status)" : message)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a subprocess with a timeout, reading both pipes without deadlocking.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval, environment: [String: String]? = nil, currentDirectory: String? = nil) async throws -> Output {
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: executable)
        box.process.arguments = arguments
        box.process.standardOutput = box.stdout
        box.process.standardError = box.stderr
        if let environment { box.process.environment = environment }
        if let currentDirectory { box.process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        try box.process.run()

        let outTask = Task.detached { box.stdout.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { box.stderr.fileHandleForReading.readDataToEndOfFile() }
        let timedOutFlag = TimedOutFlag()
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(timeout))
            if box.process.isRunning {
                timedOutFlag.set()
                box.process.terminate()
                try await Task.sleep(for: .seconds(2))
                if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
            }
        }
        await Task.detached { box.process.waitUntilExit() }.value
        watchdog.cancel()
        let out = await outTask.value
        let err = await errTask.value
        return Output(status: box.process.terminationStatus,
                      stdout: String(decoding: out, as: UTF8.self),
                      stderr: String(decoding: err, as: UTF8.self),
                      timedOut: timedOutFlag.value)
    }

    private final class TimedOutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
}
