import PennantCore
import Foundation
import Security

/// Mints and checks client tokens: the local one, which the Mac's own apps and the CLI read from a file, and one for
/// each device someone signed in on.
public actor DeviceTokens {
    public struct Device: Hashable, Codable, Sendable, Identifiable {
        public var id: ClientID
        public var name: String
        public var platform: String
        public var pairedAt: Date
        public var token: String
        /// The person who signed in on this device; nil for a device from before accounts, which is the owner's.
        public var personID: PersonID?
    }

    public static let keychainService = "dev.pennant.host"
    public static let localAccount = "local"
    public static let localTokenFileName = "client-token"

    private let paths: HostPaths
    private let keychain: KeychainStore
    private var clients: [ClientID: Device] = [:]
    private var cachedLocalToken: String?

    public init(paths: HostPaths, useFileFallback: Bool = false) {
        self.paths = paths
        let keychain = KeychainStore(service: Self.keychainService, fallbackFileURL: paths.root.appendingPathComponent("keychain-fallback.json"), preferFile: useFileFallback, legacyService: useFileFallback ? nil : KeychainStore.legacyName(for: Self.keychainService, fallbackFileURL: paths.root.appendingPathComponent("keychain-fallback.json")))
        self.keychain = keychain
        self.clients = Self.loadClients(from: keychain)
        Task { await self.adoptLegacyClients() }
    }

    public enum TokenOwner: Sendable, Equatable {
        /// The local token, or a device from before accounts.
        case owner
        /// A device someone signed in on with a provider.
        case person(PersonID)
    }

    /// Who a token belongs to; nil when the token is unknown.
    public func owner(of token: String) -> TokenOwner? {
        guard !token.isEmpty else { return nil }
        if let local = cachedLocalToken ?? readLocalTokenFromStore(), constantTimeEquals(local, token) { return .owner }
        guard let client = clients.values.first(where: { constantTimeEquals($0.token, token) }) else { return nil }
        return client.personID.map(TokenOwner.person) ?? .owner
    }

    /// A session for someone who signed in with a provider on this device.
    public func mintToken(clientID: ClientID, clientName: String, platform: String, personID: PersonID) -> String {
        let token = Self.randomToken()
        let client = Device(id: clientID, name: clientName, platform: platform, pairedAt: Date(), token: token, personID: personID)
        clients[clientID] = client
        if let data = try? JSONCodec.encode(client), let json = String(data: data, encoding: .utf8) {
            try? keychain.set(account: "client:\(clientID.rawValue)", value: json)
        }
        log.info("Signed in \(clientName) (\(platform)) as person \(personID)", category: "devices")
        return token
    }

    /// Signs out every device a person signed in on.
    public func revoke(personID: PersonID) {
        for client in clients.values where client.personID == personID { revoke(clientID: client.id) }
    }

    public func revoke(clientID: ClientID) {
        clients[clientID] = nil
        keychain.delete(account: "client:\(clientID.rawValue)")
        log.info("Revoked client \(clientID)", category: "devices")
    }

    /// Token trusted for clients on this user account. Stored in the Keychain and mirrored to
    /// `<root>/client-token` (mode 0600) so the Mac app and the CLI can read it without signing in.
    public func localToken() -> String {
        if let cachedLocalToken { return cachedLocalToken }
        var token = readLocalTokenFromStore()
        if token == nil {
            token = Self.randomToken()
            try? keychain.set(account: Self.localAccount, value: token!)
        }
        cachedLocalToken = token
        writeLocalTokenFile(token!)
        return token!
    }

    public var localTokenFileURL: URL { paths.root.appendingPathComponent(Self.localTokenFileName) }

    // MARK: Private

    /// Devices saved under this service's own name. Start-up reads only these: a device saved under an older name
    /// (before a rename) is brought over by `adoptLegacyClients` once the host is running, because reading it may
    /// make macOS ask, and a question must never hold up the host's start.
    private static func loadClients(from keychain: KeychainStore) -> [ClientID: Device] {
        var clients: [ClientID: Device] = [:]
        for account in keychain.listAccounts() where account.hasPrefix("client:") {
            guard let json = keychain.getOwn(account: account),
                  let client = try? JSONCodec.decode(Device.self, from: Data(json.utf8)) else { continue }
            clients[client.id] = client
        }
        return clients
    }

    /// Reads (and copies over) devices still saved under an older service name, off the actor so a Keychain
    /// question doesn't stall other sign-ins meanwhile, then adds them.
    private func adoptLegacyClients() {
        guard keychain.hasLegacy else { return }
        let keychain = self.keychain
        let known = Set(clients.keys.map { "client:\($0.rawValue)" })
        Task.detached(priority: .utility) { [weak self] in
            var found: [Device] = []
            for account in keychain.listAccounts() where account.hasPrefix("client:") && !known.contains(account) {
                guard let json = keychain.get(account: account),
                      let client = try? JSONCodec.decode(Device.self, from: Data(json.utf8)) else { continue }
                found.append(client)
            }
            await self?.adopt(found)
        }
    }

    private func adopt(_ found: [Device]) {
        for client in found where clients[client.id] == nil { clients[client.id] = client }
        if !found.isEmpty { log.info("Brought over \(found.count) device(s) signed in before the rename", category: "devices") }
    }

    private func readLocalTokenFromStore() -> String? {
        // The Mac's own apps read the token from the mirrored file, so a new one is fine: never ask for the old one.
        if let token = keychain.getOwn(account: Self.localAccount), !token.isEmpty {
            cachedLocalToken = token
            return token
        }
        return nil
    }

    private func writeLocalTokenFile(_ token: String) {
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let url = localTokenFileURL
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == token { return }
            try Data(token.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.warn("Could not write local token file: \(error)", category: "devices")
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
