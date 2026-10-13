import Foundation

/// What the host holds of a running plugin: its channel, and a way to stop it. A process in Pennant; in tests, a
/// plugin served in the same process.
public protocol PluginConnection: Sendable {
    var channel: PluginChannel { get }
    func stop(grace: TimeInterval) async
}

/// A running plugin, from the host's side: its process, and the channel over its stdin and stdout. Its stderr is the
/// plugin's log. Ending the host's side of the pipes ends the plugin.
public final class PluginProcess: PluginConnection, @unchecked Sendable {
    public let channel: PluginChannel
    private let process: Process
    private let stdin: Pipe
    private let lock = NSLock()
    private var exited = false

    /// Launches `executable`, inside `sandbox` (a `sandbox-exec` profile) when given. `onLog` gets each line it writes
    /// to stderr; `onExit` its exit status, once.
    public init(executable: URL, sandbox: String? = nil, environment: [String: String] = [:], onLog: @escaping @Sendable (String) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        let process = Process()
        if let sandbox {
            process.executableURL = URL(fileURLWithPath: PluginSandbox.launcher)
            process.arguments = ["-p", sandbox, executable.path]
        } else {
            process.executableURL = executable
        }
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        // A small, fixed environment: nothing of the host's (tokens, paths) leaks in by accident.
        var env = ["LANG": "en_US.UTF-8"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        env.merge(environment) { _, new in new }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.stdin = stdin
        self.channel = PluginChannel(reading: stdout.fileHandleForReading, writing: stdin.fileHandleForWriting)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) { onLog(String(line)) }
        }
        process.terminationHandler = { [weak self] p in
            stderr.fileHandleForReading.readabilityHandler = nil
            self?.markExited()
            onExit(p.terminationStatus)
        }
        try process.run()
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !exited && process.isRunning }
    public var pid: Int32 { process.processIdentifier }

    private func markExited() { lock.lock(); exited = true; lock.unlock() }

    /// Asks it to stop, then makes sure.
    public func stop(grace: TimeInterval = 2) async {
        _ = try? await channel.request(PluginMethod.shutdown, timeout: grace)
        await channel.close()
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(grace)
        while isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if isRunning { process.terminate() }
    }
}
