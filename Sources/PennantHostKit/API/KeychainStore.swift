import PennantCore
import Foundation
import Security

/// Generic-password Keychain access for the host, with a file fallback when the Keychain is unavailable
/// (for example under tests or on a headless account). The fallback file is created with mode 0600.
public final class KeychainStore: @unchecked Sendable {
    public let service: String
    private let fallbackFileURL: URL
    private let preferFile: Bool
    private let lock = NSLock()
    private var warnedFallback = false
    private var fileCache: [String: String]?
    /// The same secrets under their name from before the rename (`io.cove.host…`). Read only when an account is
    /// missing here, then copied here, so each secret moves the first time it is needed and macOS asks about it at
    /// most once. `nil` for stores with no older name.
    private let legacy: KeychainStore?
    /// Accounts whose old copy couldn't be read in this run (denied, or the Keychain locked): not asked again
    /// until the host restarts.
    private var legacyMisses: Set<String> = []

    public init(service: String, fallbackFileURL: URL, preferFile: Bool = false, legacyService: String? = nil, legacyFallbackFileURL: URL? = nil) {
        self.service = service
        self.fallbackFileURL = fallbackFileURL
        self.preferFile = preferFile || ProcessInfo.processInfo.environment["PENNANT_KEYCHAIN_FALLBACK"] == "1"
        // The previous name's store looks under the name before it in turn (Pennant → Ayes → Cove).
        legacy = legacyService.map {
            KeychainStore(service: $0, fallbackFileURL: legacyFallbackFileURL ?? fallbackFileURL.deletingLastPathComponent().appendingPathComponent(".no-legacy-fallback-\($0).json"),
                          preferFile: preferFile, legacyService: KeychainMigration.legacyName(for: $0))
        }
    }

    /// A store for one of the host's services, reading secrets saved under its pre-rename name when needed. Only
    /// the real data folder looks for old names: hosts on other roots (tests, `--root`) never read the user's
    /// older secrets.
    /// The host's secrets: in the Keychain for the host's own data folder; in files next to any other folder
    /// (tests, a scratch host), so those never read or prompt for the real host's Keychain items.
    public static func host(service: String, fallbackFileURL: URL) -> KeychainStore {
        guard isHostDataFolder(fallbackFileURL.deletingLastPathComponent()) else {
            return KeychainStore(service: service, fallbackFileURL: fallbackFileURL, preferFile: true)
        }
        return KeychainStore(service: service, fallbackFileURL: fallbackFileURL, legacyService: legacyName(for: service, fallbackFileURL: fallbackFileURL))
    }

    static func isHostDataFolder(_ folder: URL) -> Bool {
        folder.resolvingSymlinksInPath().standardizedFileURL.path == DataFolder.url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func legacyName(for service: String, fallbackFileURL: URL) -> String? {
        let folder = fallbackFileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard folder == DataFolder.url.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return KeychainMigration.legacyName(for: service)
    }

    // MARK: Public API

    public func get(account: String) -> String? {
        if let value = ownGet(account: account) { return value }
        return legacyGet(account: account)
    }

    /// Only what is saved under this service's own name: never looks under an older name, so it never makes macOS
    /// ask. For reads on the host's start path.
    public func getOwn(account: String) -> String? { ownGet(account: account) }

    public var hasLegacy: Bool { legacy != nil }

    private func legacyGet(account: String) -> String? {
        guard let legacy else { return nil }
        lock.lock()
        let missed = legacyMisses.contains(account)
        lock.unlock()
        guard !missed else { return nil }
        guard let value = legacy.get(account: account) else {
            lock.lock(); legacyMisses.insert(account); lock.unlock()
            return nil
        }
        try? set(account: account, value: value)
        return value
    }

    private func ownGet(account: String) -> String? {
        if preferFile { return fileGet(account) }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return fileGet(account)
        default:
            noteFallback(status)
            return fileGet(account)
        }
    }

    public func set(account: String, value: String) throws {
        if preferFile { try fileSet(account, value); return }
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status != errSecSuccess {
            noteFallback(status)
            try fileSet(account, value)
        } else {
            // Keep the fallback file free of stale copies.
            fileDelete(account)
        }
    }

    public func delete(account: String) {
        if !preferFile {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { noteFallback(status) }
        }
        fileDelete(account)
        // Remove the pre-rename copy too, so a deleted secret doesn't come back from it.
        legacy?.delete(account: account)
    }

    public func listAccounts() -> [String] {
        // Old accounts are listed too (attributes only, which never asks), so nothing looks missing before it moves.
        var accounts = Set(fileAccounts()).union(legacy?.listAccounts() ?? [])
        if !preferFile {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let items = result as? [[String: Any]] {
                for item in items {
                    if let account = item[kSecAttrAccount as String] as? String { accounts.insert(account) }
                }
            } else if status != errSecItemNotFound {
                noteFallback(status)
            }
        }
        return accounts.sorted()
    }

    // MARK: Keychain helpers

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func noteFallback(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        guard !warnedFallback else { return }
        warnedFallback = true
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        log.warn("Keychain unavailable (\(message)); using file fallback at \(fallbackFileURL.path)", category: "keychain")
    }

    // MARK: File fallback

    private func loadFile() -> [String: String] {
        if let fileCache { return fileCache }
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: fallbackFileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = decoded
        }
        fileCache = dict
        return dict
    }

    private func writeFile(_ dict: [String: String]) throws {
        fileCache = dict
        let dir = fallbackFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(dict)
        try data.write(to: fallbackFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackFileURL.path)
    }

    private func fileGet(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadFile()[account]
    }

    private func fileSet(_ account: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        var dict = loadFile()
        dict[account] = value
        try writeFile(dict)
    }

    private func fileDelete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = loadFile()
        guard dict.removeValue(forKey: account) != nil else { return }
        try? writeFile(dict)
    }

    private func fileAccounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadFile().keys)
    }
}
