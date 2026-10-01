import Darwin
import Foundation
import Observation
import ServiceManagement

/// Finds and starts `pennant-host`. In development it spawns the binary directly;
/// in production it registers the LaunchAgent bundled with the app via SMAppService.
@MainActor
@Observable
final class HostLauncher {
    enum Mode: String { case launchAgent, spawned, external, none }

    private(set) var mode: Mode = .none
    private(set) var binaryPath: String?
    private(set) var lastError: String?
    private(set) var agentStatus: SMAppService.Status = .notFound
    private var process: Process?
    /// PID of a host spawned with posix_spawn (self-responsible for privacy prompts).
    private var spawnedPID: pid_t = 0

    static let launchAgentPlist = "dev.pennant.host.plist"

    init() { refreshAgentStatus() }

    /// Candidate locations for the host binary, in order.
    static func candidateBinaries() -> [URL] {
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PENNANT_HOST_BINARY"] { urls.append(URL(fileURLWithPath: env)) }
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Pennant Host.app/Contents/MacOS/pennant-host"))
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pennant-host"))
        // Running from Xcode: walk up from the app bundle to find the package's .build directory.
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            for cfg in ["release", "debug"] {
                urls.append(dir.appendingPathComponent(".build/\(cfg)/pennant-host"))
            }
            dir = dir.deletingLastPathComponent()
        }
        if let src = ProcessInfo.processInfo.environment["PENNANT_PROJECT_DIR"] {
            urls.append(URL(fileURLWithPath: src).appendingPathComponent(".build/release/pennant-host"))
            urls.append(URL(fileURLWithPath: src).appendingPathComponent(".build/debug/pennant-host"))
        }
        return urls
    }

    static func findBinary() -> URL? {
        candidateBinaries().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// True when something already accepts connections on the port.
    static func isPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    func ensureHostRunning(port: Int) async {
        refreshAgentStatus()
        if Self.isPortOpen(port) {
            mode = agentStatus == .enabled ? .launchAgent : .external
            return
        }
        if agentStatus == .enabled {
            mode = .launchAgent
            // launchd will start it (KeepAlive); give it a moment.
            for _ in 0 ..< 20 where !Self.isPortOpen(port) { try? await Task.sleep(for: .milliseconds(250)) }
            return
        }
        // A host we started is still coming up (a first start can wait on Keychain prompts): wait for it rather
        // than starting another.
        if spawnedHostIsRunning {
            mode = .spawned
            for _ in 0 ..< 240 where !Self.isPortOpen(port) { try? await Task.sleep(for: .milliseconds(250)) }
            return
        }
        guard let binary = Self.findBinary() else {
            lastError = "pennant-host binary not found. Build it with `swift build --product pennant-host` or set PENNANT_HOST_BINARY."
            mode = .none
            return
        }
        spawn(binary)
        for _ in 0 ..< 40 where !Self.isPortOpen(port) { try? await Task.sleep(for: .milliseconds(250)) }
    }

    private func spawn(_ binary: URL) {
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pennant/logs/host-stdout.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["PENNANT_SELF_RESPONSIBLE"] = "1"
        switch Self.spawnSelfResponsible(binary.path, environment: env, logPath: logURL.path) {
        case .success(let pid):
            spawnedPID = pid
            process = nil
            binaryPath = binary.path
            mode = .spawned
            lastError = nil
        case .failure(let error):
            lastError = "Could not start pennant-host: \(error)"
            mode = .none
        }
    }

    /// Spawn the host so macOS treats it as its own responsible process. Privacy prompts and the
    /// System Settings entries then always name `pennant-host`, the same identity launchd would use,
    /// instead of depending on whichever process happened to start it.
    nonisolated static func spawnSelfResponsible(_ path: String, environment: [String: String], logPath: String) -> Result<pid_t, SpawnError> {
        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attrs, &noSignals)
        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attrs, 1)
        }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attrs, argv, envp)
        return rc == 0 ? .success(pid) : .failure(SpawnError(code: rc))
    }

    struct SpawnError: Error, CustomStringConvertible {
        let code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    /// True while the host we spawned is running. Reaps it once it has exited (a zombie still answers kill(0)).
    private var spawnedHostIsRunning: Bool {
        guard spawnedPID > 0 else { return false }
        var status: Int32 = 0
        switch waitpid(spawnedPID, &status, WNOHANG) {
        case 0: return true
        case -1: return kill(spawnedPID, 0) == 0
        default: return false
        }
    }

    // MARK: Restart

    /// PID of the process listening on a local TCP port, via lsof. Nil when nothing listens.
    nonisolated static func pidListening(on port: Int) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", "-i", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    /// Stop the host that serves `port` and start it again. Used after config changes that need a restart.
    func restartHost(port: Int) async {
        lastError = nil
        if agentStatus == .enabled {
            // launchd owns it: unregister, wait for the port to close, register again (KeepAlive restarts it).
            do { try await SMAppService.agent(plistName: Self.launchAgentPlist).unregister() } catch { lastError = "Unregister failed: \(error.localizedDescription)" }
            for _ in 0 ..< 40 where Self.isPortOpen(port) { try? await Task.sleep(for: .milliseconds(250)) }
            registerAgent()
        } else {
            if let p = process, p.isRunning {
                p.terminate()
            } else if spawnedHostIsRunning {
                kill(spawnedPID, SIGTERM)
            } else if let pid = Self.pidListening(on: port) {
                kill(pid, SIGTERM)
            }
            process = nil
            spawnedPID = 0
            for _ in 0 ..< 40 where Self.isPortOpen(port) { try? await Task.sleep(for: .milliseconds(250)) }
            if Self.isPortOpen(port) {
                lastError = "The host on port \(port) did not stop. Stop it manually and try again."
                return
            }
            mode = .none
        }
        await ensureHostRunning(port: port)
    }

    // MARK: LaunchAgent (production)

    func refreshAgentStatus() {
        agentStatus = SMAppService.agent(plistName: Self.launchAgentPlist).status
    }

    func registerAgent() {
        do {
            try SMAppService.agent(plistName: Self.launchAgentPlist).register()
            lastError = nil
        } catch {
            lastError = "Register failed: \(error.localizedDescription)"
        }
        refreshAgentStatus()
    }

    func unregisterAgent() {
        Task {
            do { try await SMAppService.agent(plistName: Self.launchAgentPlist).unregister() } catch { lastError = "Unregister failed: \(error.localizedDescription)" }
            refreshAgentStatus()
        }
    }

    var agentStatusLabel: String {
        switch agentStatus {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires approval in System Settings > Login Items"
        case .notFound: return "LaunchAgent not found in this build"
        @unknown default: return "Unknown"
        }
    }
}
