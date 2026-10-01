import PennantCore
import PennantHostKit
import AppKit
import Foundation

// pennant-host: the user-session service that runs agents, owns the database, and serves clients.
// Usage: pennant-host [--root <dir>] [--port <n>] [--endpoint <url>] [--model <name>] [--mode everyday|dedicated] [--no-api]

struct Arguments {
    var list: [String]
    mutating func option(_ name: String) -> String? {
        guard let i = list.firstIndex(of: name), i + 1 < list.count else { return nil }
        let v = list[i + 1]
        list.removeSubrange(i...(i + 1))
        return v
    }
    mutating func flag(_ name: String) -> Bool {
        if let i = list.firstIndex(of: name) { list.remove(at: i); return true }
        return false
    }
}
final class ArgumentBox: @unchecked Sendable {
    var arguments = Arguments(list: Array(CommandLine.arguments.dropFirst()))
    func option(_ name: String) -> String? { arguments.option(name) }
    func flag(_ name: String) -> Bool { arguments.flag(name) }
}
let argumentBox = ArgumentBox()
func option(_ name: String) -> String? { argumentBox.option(name) }
func flag(_ name: String) -> Bool { argumentBox.flag(name) }

// Helper mode: the coding CLI's permission tool. Claude Code starts this over stdio; each question is relayed to the
// running host as an approval card. It never starts a host of its own.
if CommandLine.arguments.dropFirst().first == "coder-permission" {
    guard let task = option("--task"), let root = option("--root"), let port = option("--port").flatMap(Int.init) else {
        FileHandle.standardError.write(Data("usage: pennant-host coder-permission --task <id> --root <dir> --port <n>\n".utf8))
        exit(64)
    }
    let done = DispatchSemaphore(value: 0)
    // Detached: top-level code runs on the main actor, which the semaphore below keeps busy.
    Task.detached {
        do { try await CoderPermissionBridge.run(taskID: TaskID(task), root: URL(fileURLWithPath: root), port: port) }
        catch { FileHandle.standardError.write(Data("coder-permission: \(error)\n".utf8)) }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Helper mode: evaluate the privacy permissions in a fresh process and print them as JSON.
// The running host uses this because macOS caches some grants (Screen Recording) per process.
if flag("--check-permissions") {
    let permissions = PermissionCheck.current()
    if let data = try? JSONCodec.encode(permissions) { FileHandle.standardOutput.write(data) }
    exit(0)
}

// Diagnostic: parse SKILL.md folders and print what would be imported, without touching the database.
if let path = option("--import-dry-run") {
    let files = SkillImporter.findSkillFiles(under: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    print("\(files.count) SKILL.md file(s) under \(path)")
    for file in files {
        do {
            let skill = try SkillImporter.parse(skillFile: file)
            print("- \(skill.name): \(skill.steps.count) step(s), \(skill.scripts.count) file(s), \(skill.body.count) chars — \(skill.purpose.prefix(90))")
        } catch {
            print("! \(file.path): \(error)")
        }
    }
    exit(0)
}

let root = option("--root").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
// Before the rename the data lived in …/Pennant; move it (once) before anything opens it.
let folderMigration = root == nil ? DataFolder.migrateLegacy() : nil
let paths = root.map { HostPaths(root: $0) } ?? HostPaths.default()
// One host per data folder. A second copy (an app that launched another while the first was still starting, or
// waiting on a Keychain prompt) leaves at once instead of fighting over the port and asking for the secrets again.
try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
let hostLockFD = open(paths.root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR, 0o600)
if hostLockFD < 0 || flock(hostLockFD, LOCK_EX | LOCK_NB) != 0 {
    print("Another pennant-host is already running for \(paths.root.path); leaving.")
    exit(0)
}
// A staged import (Settings › Move to another Mac) is swapped in before anything reads the data.
PennantTransfer.applyPendingImport(paths: paths)
// Keychain secrets saved under the old service names move lazily, the first time each is needed (KeychainStore.host).
if let folderMigration { print(folderMigration) }
var config = ConfigLoader.load(from: paths.configURL)
if let p = option("--port"), let port = Int(p) { config.api.port = port }
if let e = option("--endpoint") { config.inference.baseURL = e }
if let m = option("--model") { config.inference.model = m }
if let mode = option("--mode"), let m = DeploymentMode(rawValue: mode) { config.mode = m }
if flag("--no-vision") { config.inference.supportsVision = false }
if flag("--no-tools") { config.inference.supportsTools = false }
let noAPI = flag("--no-api")
if flag("--help") || flag("-h") {
    print("pennant-host [--root <dir>] [--port <n>] [--endpoint <openai-compatible base url>] [--model <name>] [--mode everyday|dedicated] [--no-api] [--seed-demo]")
    exit(0)
}

// A fictional world for screenshots and demo films, into an empty folder only (never the real data folder).
if flag("--seed-demo") {
    guard root != nil else {
        FileHandle.standardError.write(Data("--seed-demo needs --root <an empty folder>.\n".utf8))
        exit(2)
    }
    Task {
        do {
            try await DemoSeed.run(paths: paths)
            print("Seeded the demo (Pennant and its jobs for the fictional Harbor launch) into \(paths.root.path). Start it with: pennant-host --root \(paths.root.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Seeding failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

let service: HostService
do {
    service = try HostService(paths: paths, config: config)
} catch {
    FileHandle.standardError.write(Data("Failed to initialise host: \(error)\n".utf8))
    exit(1)
}

let stopSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
var signalSources: [DispatchSourceSignal] = []
for sig in stopSignals {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Task {
            await service.stop()
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

Task {
    do {
        try await service.start(startAPI: !noAPI)
        let token = await service.devices.localToken()
        print("pennant-host ready: port \(config.api.port), data at \(paths.root.path)")
        print("local client token: \(token.prefix(8))… (full token in \(paths.root.path)/client-token)")
    } catch {
        FileHandle.standardError.write(Data("Host failed to start: \(error)\n".utf8))
        exit(1)
    }
}

// Apple's desktop frameworks expect a real main thread that runs its run loop. Under dispatchMain() the main thread
// slept and main-queue work ran on a worker, so when a screen stream's ReplayKit created NSApplication there it waited
// on the main thread forever and froze the host. So the application object exists from the start (hidden, never
// activated) and the main run loop runs.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
RunLoop.main.run()
