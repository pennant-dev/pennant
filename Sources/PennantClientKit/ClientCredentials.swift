import PennantCore
import Foundation
import Security

/// Client-side persistence of the client ID and host token, per host, in the Keychain
/// (service "dev.pennant.client") with a mode-0600 file fallback under Application Support/Pennant.
public struct ClientCredentials: Hashable, Codable, Sendable {
    public var clientID: ClientID
    public var token: String
    public var hostName: String
    public var savedAt: Date

    public init(clientID: ClientID, token: String, hostName: String = "", savedAt: Date = Date()) {
        self.clientID = clientID
        self.token = token
        self.hostName = hostName
        self.savedAt = savedAt
    }

    public static let keychainService = "dev.pennant.client"
    /// The service before the rename to Pennant: saved sign-ins are read from it once and copied over.
    static let legacyKeychainService = "dev.ayes.client"

    // MARK: Load / save

    public static func load(for endpoint: HostEndpoint) -> ClientCredentials? {
        guard let json = ClientKeychain.shared.get(account: endpoint.id),
              let credentials = try? JSONCodec.decode(ClientCredentials.self, from: Data(json.utf8)) else { return nil }
        return credentials
    }

    public static func save(_ credentials: ClientCredentials, for endpoint: HostEndpoint) throws {
        let data = try JSONCodec.encode(credentials)
        try ClientKeychain.shared.set(account: endpoint.id, value: String(decoding: data, as: UTF8.self))
    }

    public static func remove(for endpoint: HostEndpoint) {
        ClientKeychain.shared.delete(account: endpoint.id)
    }

    /// Stable client identity for this device, created on first use.
    public static func deviceClientID() -> ClientID {
        if let existing = ClientKeychain.shared.get(account: "device-client-id"), !existing.isEmpty {
            return ClientID(existing)
        }
        let id = ClientID()
        try? ClientKeychain.shared.set(account: "device-client-id", value: id.rawValue)
        return id
    }

    /// On the Mac, the host mirrors its local token to `~/Library/Application Support/Pennant/client-token`
    /// so clients on the same user account can connect without signing in.
    public static func readLocalHostToken() -> String? {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Pennant/client-token")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
        #else
        return nil
        #endif
    }
}

/// Minimal generic-password Keychain wrapper for clients, with a file fallback.
final class ClientKeychain: @unchecked Sendable {
    static let shared = ClientKeychain()

    private let service = ClientCredentials.keychainService
    private let lock = NSLock()
    private var cache: [String: String]?
    private let preferFile = ProcessInfo.processInfo.environment["PENNANT_KEYCHAIN_FALLBACK"] == "1"

    private var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pennant/client-credentials.json")
    }

    func get(account: String) -> String? {
        if !preferFile {
            if let value = keychainGet(account: account, service: service) { return value }
            // Signed in before the rename: bring the saved sign-in over so nobody has to sign in again.
            if let value = keychainGet(account: account, service: ClientCredentials.legacyKeychainService) {
                try? set(account: account, value: value)
                return value
            }
        }
        return fileGet(account)
    }

    private func keychainGet(account: String, service: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(account: String, value: String) throws {
        if !preferFile {
            var query = baseQuery(account: account)
            let data = Data(value.utf8)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                query[kSecValueData as String] = data
                status = SecItemAdd(query as CFDictionary, nil)
            }
            if status == errSecSuccess {
                fileDelete(account)
                return
            }
        }
        try fileSet(account, value)
    }

    func delete(account: String) {
        if !preferFile { SecItemDelete(baseQuery(account: account) as CFDictionary) }
        fileDelete(account)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func loadFile() -> [String: String] {
        if let cache { return cache }
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: fallbackURL), let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = decoded
        }
        cache = dict
        return dict
    }

    private func writeFile(_ dict: [String: String]) throws {
        cache = dict
        try FileManager.default.createDirectory(at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(dict).write(to: fallbackURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackURL.path)
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
}
