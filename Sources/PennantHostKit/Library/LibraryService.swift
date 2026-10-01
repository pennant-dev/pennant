import PennantCore
import Foundation
import ImageIO

/// The user's brand assets: collections of files (logos, fonts, templates, images) with written guidance, stored
/// under `<data>/library/<collection>/`. Agents find them with `find_assets` and use the files by path.
public actor LibraryService {
    let root: URL
    let store: any StoreProtocol
    private static let key = "library.index"

    public init(root: URL, store: any StoreProtocol) {
        self.root = root
        self.store = store
    }

    public func index() async -> LibraryIndex {
        guard let raw = try? await store.setting(Self.key), let data = raw.data(using: .utf8),
              let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else { return LibraryIndex() }
        return index
    }

    private func save(_ index: LibraryIndex) async throws {
        let data = try JSONEncoder().encode(index)
        try await store.setSetting(Self.key, value: String(decoding: data, as: UTF8.self))
    }

    static func slug(_ s: String) -> String {
        let cleaned = s.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "collection" : cleaned
    }

    public func upload(collection: String, fileName: String, mimeType: String, data: Data, name: String, notes: String) async throws -> LibraryIndex {
        let collectionName = collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Brand" : collection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty else { throw HostCommandError.invalid("The file was empty.") }
        guard data.count <= 50 * 1024 * 1024 else { throw HostCommandError.invalid("\(fileName) is larger than 50 MB.") }
        var index = await index()
        if !index.collections.contains(where: { $0.name == collectionName }) { index.collections.append(LibraryCollection(name: collectionName)) }
        let folder = root.appendingPathComponent(Self.slug(collectionName), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = (fileName as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
        var url = folder.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\((safe as NSString).deletingPathExtension)-\(n).\((safe as NSString).pathExtension)")
            n += 1
        }
        try data.write(to: url, options: .atomic)
        let size = Self.pixelSize(data)
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (safe as NSString).deletingPathExtension : name
        index.assets.append(LibraryAsset(collection: collectionName, name: display, fileName: url.lastPathComponent, mimeType: mimeType, byteCount: data.count, width: size?.0, height: size?.1, notes: notes, path: url.path))
        try await save(index)
        return index
    }

    public func update(_ asset: LibraryAsset) async throws -> LibraryIndex {
        var index = await index()
        guard let i = index.assets.firstIndex(where: { $0.id == asset.id }) else { throw HostCommandError.invalid("That asset no longer exists.") }
        index.assets[i].name = asset.name
        index.assets[i].notes = asset.notes
        try await save(index)
        return index
    }

    public func delete(id: String) async throws -> LibraryIndex {
        var index = await index()
        if let asset = index.assets.first(where: { $0.id == id }) { try? FileManager.default.removeItem(atPath: asset.path) }
        index.assets.removeAll { $0.id == id }
        try await save(index)
        return index
    }

    public func saveCollection(_ collection: LibraryCollection) async throws -> LibraryIndex {
        var index = await index()
        let name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostCommandError.invalid("Give the collection a name.") }
        if let i = index.collections.firstIndex(where: { $0.name == name }) { index.collections[i].notes = collection.notes }
        else { index.collections.append(LibraryCollection(name: name, notes: collection.notes)) }
        try await save(index)
        return index
    }

    public func deleteCollection(_ name: String) async throws -> LibraryIndex {
        var index = await index()
        for asset in index.assets where asset.collection == name { try? FileManager.default.removeItem(atPath: asset.path) }
        index.assets.removeAll { $0.collection == name }
        index.collections.removeAll { $0.name == name }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.slug(name)))
        try await save(index)
        return index
    }

    /// A 320 px JPEG of an image asset, for the Library grid.
    public func preview(id: String) async throws -> Data {
        guard let asset = await index().assets.first(where: { $0.id == id }), let data = FileManager.default.contents(atPath: asset.path) else {
            throw HostCommandError.invalid("That asset no longer exists.")
        }
        if asset.mimeType == "image/svg+xml" { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary) else {
            throw HostCommandError.invalid("No preview for \(asset.fileName).")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { throw HostCommandError.invalid("No preview") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

/// Sign-ins and secrets for scripts. What an entry is (name, kind, site, username, notes) is in the host's settings;
/// the password, TOTP secret and API secret are in the host's own Keychain and only ever go into a script that asked
/// for the entry by name.
public actor VaultService {
    let store: any StoreProtocol
    let keychain: KeychainStore
    private static let key = "vault.items"

    public init(store: any StoreProtocol, keychain: KeychainStore) {
        self.store = store
        self.keychain = keychain
    }

    public func items() async -> [VaultItem] {
        guard let raw = try? await store.setting(Self.key), let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([VaultItem].self, from: data) else { return [] }
        return items.sorted { $0.name < $1.name }
    }

    private func save(_ items: [VaultItem]) async throws {
        try await store.setSetting(Self.key, value: String(decoding: try JSONEncoder().encode(items), as: UTF8.self))
    }

    public func save(_ item: VaultItem, secret: VaultSecret?) async throws -> [VaultItem] {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty else { throw HostCommandError.invalid("Give the entry a name, like linkedin.") }
        var all = await items()
        if all.contains(where: { $0.name == name && $0.id != item.id }) { throw HostCommandError.invalid("An entry named \(name) already exists.") }
        var stored = stored(item.id)
        if let secret {
            if let p = secret.password { stored.password = p.isEmpty ? nil : p }
            if let t = secret.totp { stored.totp = t.isEmpty ? nil : t.replacingOccurrences(of: " ", with: "").uppercased() }
            if let s = secret.secret { stored.secret = s.isEmpty ? nil : s }
            try keychain.set(account: item.id, value: String(decoding: try JSONEncoder().encode(stored), as: UTF8.self))
        }
        var updated = item
        updated.name = name
        updated.hasPassword = stored.password != nil
        updated.hasTOTP = stored.totp != nil
        updated.hasSecret = stored.secret != nil
        updated.updatedAt = Date()
        all.removeAll { $0.id == item.id }
        all.append(updated)
        try await save(all)
        return all.sorted { $0.name < $1.name }
    }

    public func delete(id: String) async throws -> [VaultItem] {
        keychain.delete(account: id)
        var all = await items()
        all.removeAll { $0.id == id }
        try await save(all)
        return all
    }

    private func stored(_ id: String) -> VaultSecret {
        guard let raw = keychain.get(account: id), let data = raw.data(using: .utf8), let s = try? JSONDecoder().decode(VaultSecret.self, from: data) else { return VaultSecret() }
        return s
    }

    // MARK: Sign-ins copied from the user's browser (a record of what Pennant's browser holds; no secrets here)

    private static let signInsKey = "vault.browserSignIns"

    public func browserSignIns() async -> [BrowserSignIn] {
        guard let raw = try? await store.setting(Self.signInsKey), let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([BrowserSignIn].self, from: data) else { return [] }
        return list.sorted { $0.site < $1.site }
    }

    private func saveSignIns(_ list: [BrowserSignIn]) async throws {
        try await store.setSetting(Self.signInsKey, value: String(decoding: try JSONEncoder().encode(list), as: UTF8.self))
    }

    /// Records an import, replacing earlier records for the same sites.
    public func recordSignIns(_ result: ChromeImportResult, profileName: String, account: String?) async throws -> [BrowserSignIn] {
        var list = await browserSignIns()
        for (site, count) in result.perSite {
            list.removeAll { $0.site == site }
            list.append(BrowserSignIn(site: site, profileName: profileName, account: account, cookies: count, expiresAt: result.expiresAt[site]))
        }
        try await saveSignIns(list)
        return list.sorted { $0.site < $1.site }
    }

    public func forgetSignIn(_ site: String) async throws -> [BrowserSignIn] {
        var list = await browserSignIns()
        list.removeAll { $0.site == site }
        try await saveSignIns(list)
        return list
    }

    /// The entries a script asked for, with their secrets, keyed by name, and the names the vault does not have
    /// (the script then signs in another way).
    public func resolve(_ names: [String]) async -> (entries: [String: [String: String]], secrets: [String], missing: [String]) {
        let all = await items()
        var out: [String: [String: String]] = [:]
        var values: [String] = []
        var missing: [String] = []
        for raw in names {
            let name = raw.lowercased()
            guard let item = all.first(where: { $0.name == name }) else { missing.append(raw); continue }
            let s = stored(item.id)
            var entry: [String: String] = [:]
            if let v = item.username { entry["username"] = v }
            if let v = item.url { entry["url"] = v }
            if let v = s.password { entry["password"] = v; values.append(v) }
            if let v = s.totp { entry["totp"] = v; values.append(v) }
            if let v = s.secret { entry["secret"] = v; values.append(v) }
            out[name] = entry
        }
        return (out, values, missing)
    }
}
