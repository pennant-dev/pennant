import PennantCore
import Foundation

/// The folders macOS keeps to the apps allowed there: Documents, Desktop and Downloads. Opening one tells whether
/// Pennant may: an answer at once when macOS has one, or its prompt when it hasn't asked yet (the open waits for the
/// owner; the checks here don't). Asking again clears an earlier "Don't Allow", so macOS shows its prompt and the
/// owner only has to accept it.
public enum FolderAccess {
    public static var keys: [String] { DesktopPermissions.folderKeys }

    /// "documents" → "Documents", as the folder is named in the home folder.
    static func name(_ key: String) -> String { key.prefix(1).uppercased() + key.dropFirst() }

    static func url(_ key: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name(key), isDirectory: true)
    }

    /// The privacy service macOS keeps each one under, for `tccutil reset`.
    static func service(_ key: String) -> String {
        switch key {
        case "desktop": return "SystemPolicyDesktopFolder"
        case "downloads": return "SystemPolicyDownloadsFolder"
        default: return "SystemPolicyDocumentsFolder"
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: PermissionState] = [:]
    nonisolated(unsafe) private static var opening: Set<String> = []

    /// What the last opens found, without opening anything.
    public static var states: [String: PermissionState] {
        lock.lock(); defer { lock.unlock() }
        return known
    }

    private static func isOpening(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return opening.contains(key)
    }

    /// Opens the folder, once at a time: granted or denied, or notDetermined while macOS is still asking (the open
    /// goes on waiting for the owner, and what they answer is kept).
    public static func check(_ key: String, wait: TimeInterval) async -> PermissionState {
        // Only the real host opens them: anything else (a test run) would bring up macOS's prompts for itself.
        guard PermissionCheck.canSpawnHelper else { return states[key] ?? .unknown }
        start(key)
        let deadline = Date().addingTimeInterval(wait)
        while isOpening(key), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if isOpening(key) { return .notDetermined }
        return states[key] ?? .unknown
    }

    private static func start(_ key: String) {
        lock.lock()
        let already = !opening.insert(key).inserted
        lock.unlock()
        if already { return }
        let path = url(key).path
        Thread.detachNewThread {
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            let state: PermissionState = fd >= 0 ? .granted : (errno == EPERM || errno == EACCES ? .denied : .unknown)
            if fd >= 0 { close(fd) }
            lock.lock()
            known[key] = state
            opening.remove(key)
            lock.unlock()
        }
    }

    /// Looks at each folder, briefly: what macOS has decided, and its prompt for any it hasn't asked about.
    public static func checkAll() async {
        await withTaskGroup(of: Void.self) { group in
            for key in keys { group.addTask { _ = await check(key, wait: 1) } }
        }
    }

    /// Asks the owner for a folder: an earlier "Don't Allow" is cleared so macOS shows its prompt again, then this
    /// waits (up to `wait`) for their answer.
    public static func ask(_ key: String, wait: TimeInterval = 90) async -> PermissionState {
        let state = await check(key, wait: 1)
        let after: PermissionState
        switch state {
        case .granted:
            return .granted
        case .denied:
            let cleared = await reset(key)
            log.info("Folders: \(name(key)) was denied; cleared the answer for \(PermissionCheck.tccClient(for: key)): \(cleared ? "yes" : "no")", category: "permissions")
            guard cleared else { return .denied }
            after = await check(key, wait: wait)
        case .notDetermined, .unknown:
            after = await check(key, wait: wait)
        }
        log.info("Folders: asked for \(name(key)): \(after.rawValue)", category: "permissions")
        return after
    }

    /// `tccutil reset <service> <Pennant>`: macOS forgets its answer for Pennant only, and asks again on the next open.
    /// The answer is filed under the app the host is inside (see `PermissionCheck.tccClient`), not the host itself.
    static func reset(_ key: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service(key), PermissionCheck.tccClient(for: key)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return await Task.detached {
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    /// The protected folder an error is about: macOS refusing ("Operation not permitted") a path inside one.
    public static func blockedFolder(in text: String, home: String = NSHomeDirectory()) -> String? {
        let refused = text.localizedCaseInsensitiveContains("operation not permitted")
            || text.localizedCaseInsensitiveContains("you don’t have permission to view it")
            || text.localizedCaseInsensitiveContains("you don't have permission to view it")
        guard refused else { return nil }
        for key in keys {
            let folder = name(key)
            if text.contains("\(home)/\(folder)") || text.contains("~/\(folder)") || text.contains("$HOME/\(folder)") { return key }
        }
        return nil
    }
}

/// Work that ran into a folder macOS keeps Pennant out of: Pennant asks the owner for it then and there (macOS's
/// prompt; they only accept it), at most every few hours per folder, and the model is told what to say.
actor FolderAsks {
    static let again: TimeInterval = 6 * 3600
    private var asked: [String: Date] = [:]
    private let ask: @Sendable (String) async -> PermissionState
    private let check: @Sendable (String) async -> PermissionState

    init(ask: @escaping @Sendable (String) async -> PermissionState = { await FolderAccess.ask($0) },
         check: @escaping @Sendable (String) async -> PermissionState = { await FolderAccess.check($0, wait: 1) }) {
        self.ask = ask
        self.check = check
    }

    func blocked(_ key: String, now: Date = Date()) async -> String? {
        // Allowed after all: the refusal was about something else (one file's own permissions).
        guard await check(key) != .granted else { return nil }
        let folder = FolderAccess.name(key)
        if let last = asked[key], now.timeIntervalSince(last) < Self.again {
            return "macOS is keeping Pennant out of the owner's \(folder) folder, and Pennant asked them for it a little while ago. Tell them in a line that this needs their \(folder) folder: they allow it in Pennant's Settings › Permissions (\(DesktopPermissions.folderTitle(key)), Grant). Don't send them to System Settings. Carry on with what doesn't need it."
        }
        asked[key] = now
        let ask = self.ask
        Task.detached { _ = await ask(key) }
        return "macOS is keeping Pennant out of the owner's \(folder) folder, so Pennant has just asked them for it: macOS shows “Pennant would like to access files in your \(folder) folder”. Tell them in a line to click Allow, then try again; don't send them to System Settings or explain more."
    }
}
