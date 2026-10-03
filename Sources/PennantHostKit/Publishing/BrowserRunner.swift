import PennantCore
import Foundation

/// Runs small Playwright scripts with Node for work the Mac's own apps cannot do reliably: rendering HTML to PNG,
/// and working in web apps that offer no usable API (scripts that skills bring). Pennant installs its own Playwright under
/// `<data>/browser` on first use and keeps a dedicated browser profile there, so the user signs in once and their
/// everyday Chrome is never touched. One script at a time uses the profile.
public actor BrowserRunner {
    public static let playwrightVersion = "1.62.1"

    let root: URL
    var profile: URL { root.appendingPathComponent("profile", isDirectory: true) }
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(root: URL) { self.root = root }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Installs Playwright (once) next to the scripts. The browsers themselves come from Playwright's shared cache,
    /// or are downloaded on first use.
    func ensureInstalled() async throws {
        let marker = root.appendingPathComponent("node_modules/playwright/package.json")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = #"{"name":"pennant-browser","private":true,"type":"module","dependencies":{"playwright":"\#(Self.playwrightVersion)"}}"#
        try Data(package.utf8).write(to: root.appendingPathComponent("package.json"))
        log.info("Installing Playwright \(Self.playwrightVersion) for browser tools", category: "browser")
        let npm = MCPManager.resolveExecutable("npm")
        let result = try await Self.run(executable: npm, arguments: npm.hasSuffix("/env") ? ["npm", "install", "--no-audit", "--no-fund"] : ["install", "--no-audit", "--no-fund"], cwd: root, stdin: nil, timeout: 300)
        guard result.status == 0, FileManager.default.fileExists(atPath: marker.path) else {
            throw Failure(message: "Could not install Playwright: \(result.stderr.suffix(400))")
        }
        let browsers = try await Self.run(executable: MCPManager.resolveExecutable("npx"), arguments: ["playwright", "install", "chromium"], cwd: root, stdin: nil, timeout: 600)
        if browsers.status != 0 { log.warn("playwright install chromium: \(browsers.stderr.suffix(300))", category: "browser") }
    }

    /// Runs `source` (an ES module) with `input` as JSON on stdin; the script prints one JSON object as its last
    /// stdout line. Progress lines on stderr go to the host log.
    /// `input` and the result are JSON objects (as data, so they cross the actor boundary safely).
    /// `redact` lists secret values (from the vault) that must never reach the log or the result.
    public func run(script name: String, source: String, input: Data, timeout: TimeInterval, redact: [String] = []) async throws -> Data {
        await acquire()
        defer { release() }
        // Queued behind another script while its task was stopped: it doesn't start.
        try Task.checkCancellation()
        try await ensureInstalled()
        let file = root.appendingPathComponent("\(name).mjs")
        try Data(source.utf8).write(to: file, options: .atomic)
        var payload = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        payload["profile"] = profile.path
        let data = try JSONSerialization.data(withJSONObject: payload)
        let node = MCPManager.resolveExecutable("node")
        let result = try await Self.run(executable: node, arguments: node.hasSuffix("/env") ? ["node", file.path] : [file.path], cwd: root, stdin: data, timeout: timeout)
        let stderr = Self.redact(result.stderr, redact)
        for line in stderr.split(separator: "\n").suffix(40) { log.info("[\(name)] \(line)", category: "browser") }
        guard let raw = result.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) is [String: Any] else {
            throw Failure(message: "The \(name) script failed (exit \(result.status)): \(stderr.suffix(600))")
        }
        let last = Self.redact(String(raw), redact)
        return Data(last.utf8)
    }

    /// Runs a script file (from a skill folder, say). It is copied next to Pennant's Playwright install first, so its
    /// `import 'playwright'` resolves without the skill carrying node_modules.
    public func run(file: URL, input: Data, timeout: TimeInterval, redact: [String] = []) async throws -> Data {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { throw Failure(message: "Cannot read \(file.path)") }
        let name = "skill-" + file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return try await run(script: name, source: source, input: input, timeout: timeout, redact: redact)
    }

    /// Blanks secret values out of text. Values shorter than 8 characters are not secrets (a cookie of "true"), and
    /// blanking them would corrupt the script's JSON result.
    static func redact(_ text: String, _ secrets: [String]) -> String {
        secrets.filter { $0.count >= 8 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    struct ProcessResult { var status: Int32; var stdout: String; var stderr: String }

    static func run(executable: String, arguments: [String], cwd: URL, stdin: Data?, timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        let outBox = DataBox(), errBox = DataBox()
        out.fileHandleForReading.readabilityHandler = { h in outBox.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }
        try process.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                if Date() > deadline { throw Failure(message: "Timed out after \(Int(timeout)) s") }
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch {
            // Timed out, or its task was stopped: the script (and the browser it opened) goes too.
            if process.isRunning { process.terminate() }
            throw error
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outBox.append(out.fileHandleForReading.readDataToEndOfFile())
        errBox.append(err.fileHandleForReading.readDataToEndOfFile())
        return ProcessResult(status: process.terminationStatus, stdout: outBox.string, stderr: errBox.string)
    }
}

/// Collects a pipe's output from its handler thread.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
