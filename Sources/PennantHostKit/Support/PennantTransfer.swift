import CommonCrypto
import PennantCore
import CryptoKit
import Foundation

/// Moving Pennant to another Mac: an export folder with a consistent copy of the database (agents, conversations,
/// skills, schedules, usage, vault entries), shared files, the config (models, settings), the Library and the
/// skills folders, plus — only when a passphrase is given — the vault's secrets and connector sign-ins, sealed with
/// AES-GCM under a key derived from the passphrase. Importing stages the folder; the host swaps it in when it
/// next starts (before the database opens) and keeps the data it replaced next to it.
public enum PennantTransfer {
    /// Keychain services whose items travel (sealed) with an export.
    static let secretServices = ["dev.pennant.host.vault", "dev.pennant.host.mcp"]
    static let stagingName = ".restore"
    static let formatVersion = 1

    struct Manifest: Codable {
        var format: Int
        var createdAt: Date
        var hostName: String
        /// The Pennant that made it (exports from before the rename don't say).
        var pennantVersion: String?
        var includesSecrets: Bool
    }

    // MARK: Export

    public static func export(store: SQLiteStore, paths: HostPaths, into parent: URL, passphrase: String?) async throws -> PennantExportResult {
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let dir = parent.appendingPathComponent("Pennant Export \(stamp.string(from: Date()))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try await store.backup(to: dir)
        for name in ["config.json"] where fm.fileExists(atPath: paths.root.appendingPathComponent(name).path) {
            try fm.copyItem(at: paths.root.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        for folder in ["library", "skills"] {
            let src = paths.root.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            try copyTree(src, to: dir.appendingPathComponent(folder, isDirectory: true), skipping: ["node_modules", ".DS_Store"])
        }
        var secretCount = 0
        if let passphrase, !passphrase.isEmpty {
            var secrets: [String: [String: String]] = [:]
            for service in secretServices {
                let keychain = KeychainStore.host(service: service, fallbackFileURL: paths.root.appendingPathComponent(service == "dev.pennant.host.vault" ? "vault-fallback.json" : "mcp-credentials.json"))
                var items: [String: String] = [:]
                for account in keychain.listAccounts() { if let v = keychain.get(account: account) { items[account] = v } }
                secretCount += items.count
                secrets[service] = items
            }
            let sealed = try seal(try JSONEncoder().encode(secrets), passphrase: passphrase)
            try sealed.write(to: dir.appendingPathComponent(HostPaths.sealedSecretsName), options: .atomic)
        }
        let manifest = Manifest(format: formatVersion, createdAt: Date(), hostName: Host.current().localizedName ?? "Mac", pennantVersion: PennantVersion.string, includesSecrets: secretCount > 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try Data("""
        Pennant export from \(manifest.hostName), \(stamp.string(from: manifest.createdAt)).
        Import it on another Mac from Pennant › Settings › Host settings › Move to another Mac (or `pennant import "<this folder>"`).
        \(manifest.includesSecrets ? "Vault secrets and connector sign-ins are inside, sealed with the passphrase you chose." : "No secrets inside: vault passwords and connector sign-ins need to be entered again.")
        Browser sign-ins don't transfer (Chrome ties them to this Mac): copy them again in Vault › Sign-ins from Chrome.
        """.utf8).write(to: dir.appendingPathComponent("README.txt"))
        log.info("Exported Pennant to \(dir.path) (secrets: \(secretCount))", category: "host")
        return PennantExportResult(path: dir.path, bytes: folderSize(dir), secrets: secretCount)
    }

    // MARK: Import

    /// Checks an export and stages it for the next start. Throws on a wrong passphrase before touching anything.
    public static func stage(from dir: URL, passphrase: String?, paths: HostPaths) throws {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else {
            throw HostCommandError.invalid("\(dir.lastPathComponent) isn't a Pennant export (no manifest.json).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.format <= formatVersion else { throw HostCommandError.invalid("This export comes from a newer Pennant; update Pennant first.") }
        // Staged first (the data in use isn't touched until the next start), with any files from before the rename
        // given their names now.
        let staging = paths.root.appendingPathComponent(stagingName, isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try copyTree(dir, to: staging, skipping: [])
        HostPaths.adoptRenamedFiles(in: staging)
        do {
            guard fm.fileExists(atPath: staging.appendingPathComponent(HostPaths.databaseName).path) else { throw HostCommandError.invalid("The export has no database.") }
            let sealedURL = staging.appendingPathComponent(HostPaths.sealedSecretsName)
            if fm.fileExists(atPath: sealedURL.path) {
                guard let passphrase, !passphrase.isEmpty else { throw HostCommandError.invalid("This export carries sealed secrets: give its passphrase (or remove \(HostPaths.sealedSecretsName) to import without them).") }
                let secrets = try open(try Data(contentsOf: sealedURL), passphrase: passphrase)
                try fm.removeItem(at: sealedURL)
                let url = staging.appendingPathComponent("secrets.json")
                try secrets.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Swaps a staged import in. Called at host start before the database opens; the replaced data is kept in
    /// `before-import-<date>` next to it. Returns whether anything was restored.
    @discardableResult
    public static func applyPendingImport(paths: HostPaths) -> Bool {
        let fm = FileManager.default
        let staging = paths.root.appendingPathComponent(stagingName, isDirectory: true)
        guard fm.fileExists(atPath: staging.appendingPathComponent(HostPaths.databaseName).path) else { return false }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let keep = paths.root.appendingPathComponent("before-import-\(stamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: keep, withIntermediateDirectories: true)
            for name in [HostPaths.databaseName, HostPaths.databaseName + "-wal", HostPaths.databaseName + "-shm", "config.json", "artifacts", "library", "skills"] {
                let current = paths.root.appendingPathComponent(name)
                if fm.fileExists(atPath: current.path) { try fm.moveItem(at: current, to: keep.appendingPathComponent(name)) }
            }
            for name in [HostPaths.databaseName, "config.json", "artifacts", "library", "skills"] {
                let incoming = staging.appendingPathComponent(name)
                if fm.fileExists(atPath: incoming.path) { try fm.moveItem(at: incoming, to: paths.root.appendingPathComponent(name)) }
            }
            let secretsURL = staging.appendingPathComponent("secrets.json")
            if let data = try? Data(contentsOf: secretsURL), let secrets = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
                for (exported, items) in secrets {
                    // Exports made before the rename name the old services.
                    let service = KeychainMigration.renamed[exported] ?? exported
                    let keychain = KeychainStore.host(service: service, fallbackFileURL: paths.root.appendingPathComponent(service == "dev.pennant.host.vault" ? "vault-fallback.json" : "mcp-credentials.json"))
                    for (account, value) in items { try? keychain.set(account: account, value: value) }
                }
            }
            try fm.removeItem(at: staging)
            log.info("Imported an Pennant export; the previous data is in \(keep.lastPathComponent)", category: "host")
            return true
        } catch {
            log.error("Import failed part way: \(error). The previous data is in \(keep.path)", category: "host")
            return false
        }
    }

    // MARK: Sealing

    struct Sealed: Codable { var salt: String; var iterations: UInt32; var box: String }

    static func key(_ passphrase: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8).map { CChar(bitPattern: $0) }
        let s = [UInt8](salt)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, s, s.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        return SymmetricKey(data: out)
    }

    static func seal(_ plain: Data, passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let iterations: UInt32 = 210_000
        let box = try AES.GCM.seal(plain, using: key(passphrase, salt: salt, iterations: iterations))
        guard let combined = box.combined else { throw HostCommandError.invalid("Couldn't seal the secrets.") }
        return try JSONEncoder().encode(Sealed(salt: salt.base64EncodedString(), iterations: iterations, box: combined.base64EncodedString()))
    }

    static func open(_ data: Data, passphrase: String) throws -> Data {
        guard let s = try? JSONDecoder().decode(Sealed.self, from: data), let salt = Data(base64Encoded: s.salt), let combined = Data(base64Encoded: s.box) else {
            throw HostCommandError.invalid("\(HostPaths.sealedSecretsName) is damaged.")
        }
        do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key(passphrase, salt: salt, iterations: s.iterations)) } catch {
            throw HostCommandError.invalid("Wrong passphrase for this export's secrets.")
        }
    }

    // MARK: Files

    static func copyTree(_ src: URL, to dst: URL, skipping: Set<String>) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) where !skipping.contains(name) {
            let from = src.appendingPathComponent(name), to = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &isDir)
            if isDir.boolValue { try copyTree(from, to: to, skipping: skipping) } else {
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
        }
    }

    static func folderSize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}
