import CommonCrypto
import PennantCore
import Foundation
import Security

/// Copies the user's sign-ins for chosen sites from their own Chrome into Pennant's browser profile, so scripts start
/// signed in without a login page. Only cookies for the named sites move; the everyday Chrome is only read.
/// Chrome encrypts cookie values with a key in the login Keychain ("Chrome Safe Storage"), so macOS asks the user
/// once to let Pennant read it.
public enum ChromeSignIns {
    static var chromeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    public static func profiles() -> [ChromeProfile] {
        let localState = chromeRoot.appendingPathComponent("Local State")
        var names: [String: (String, String?)] = [:]
        if let data = try? Data(contentsOf: localState),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, value) in cache {
                let info = value as? [String: Any]
                names[dir] = (info?["name"] as? String ?? dir, (info?["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        let dirs: [String]
        do { dirs = try FileManager.default.contentsOfDirectory(atPath: chromeRoot.path) } catch {
            log.warn("Cannot list Chrome profiles at \(chromeRoot.path): \(error.localizedDescription)", category: "vault")
            dirs = []
        }
        return dirs.filter { dir in
            (dir == "Default" || dir.hasPrefix("Profile ")) && FileManager.default.fileExists(atPath: chromeRoot.appendingPathComponent("\(dir)/Cookies").path)
        }
        .sorted { a, b in a == "Default" ? true : b == "Default" ? false : a.localizedStandardCompare(b) == .orderedAscending }
        .map { ChromeProfile(id: $0, name: names[$0]?.0 ?? $0, account: names[$0]?.1) }
    }

    static func normalize(_ site: String) -> String {
        var s = site.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func matches(host: String, site: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return h == site || h.hasSuffix("." + site)
    }

    /// The sites a Chrome profile holds cookies for, most cookies first. Reads only site names (no values, so no
    /// Keychain prompt).
    public static func sites(profile: String) throws -> [ChromeSite] {
        let source = chromeRoot.appendingPathComponent("\(profile)/Cookies")
        guard FileManager.default.fileExists(atPath: source.path) else { throw HostCommandError.invalid("Chrome has no profile named \(profile).") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for suffix in ["", "-journal", "-wal"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: temp.appendingPathComponent("Cookies" + suffix)) }
        }
        let db = try SQLiteDatabase(path: temp.appendingPathComponent("Cookies").path)
        defer { db.close() }
        let hosts = try db.query("SELECT host_key, COUNT(*) FROM cookies GROUP BY host_key") { ($0.string(0) ?? "", Int($0.int(1))) }
        var counts: [String: Int] = [:]
        for (host, n) in hosts {
            let site = registrableDomain(host)
            if !site.isEmpty { counts[site, default: 0] += n }
        }
        return counts.map { ChromeSite(site: $0.key, cookies: $0.value) }.sorted { ($0.cookies, $1.site) > ($1.cookies, $0.site) }
    }

    /// "www.linkedin.com" → "linkedin.com"; keeps three labels for two-letter country forms like "bbc.co.uk".
    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel = labels[labels.count - 2]
        let countryForm = labels.last!.count == 2 && ["co", "com", "org", "net", "ac", "gov", "edu"].contains(secondLevel)
        return labels.suffix(countryForm ? 3 : 2).joined(separator: ".")
    }

    struct CookieRow {
        var host, name, value: String
        var encrypted: Data
        var path: String
        var expires: Int64
        var secure, httpOnly: Bool
        var sameSite: Int64
    }

    /// Playwright-shaped cookies ({name, value, domain, path, expires, httpOnly, secure, sameSite}) for the sites.
    static func cookies(profile: String, sites: [String]) throws -> [[String: Any]] {
        let source = chromeRoot.appendingPathComponent("\(profile)/Cookies")
        guard FileManager.default.fileExists(atPath: source.path) else { throw HostCommandError.invalid("Chrome has no profile named \(profile).") }
        let wanted = sites.map(normalize).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { throw HostCommandError.invalid("Name at least one site, like linkedin.com.") }
        // Chrome keeps the database open; read a copy.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for suffix in ["", "-journal", "-wal"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: temp.appendingPathComponent("Cookies" + suffix)) }
        }
        let db = try SQLiteDatabase(path: temp.appendingPathComponent("Cookies").path)
        defer { db.close() }
        let version = (try? db.query("SELECT value FROM meta WHERE key = 'version'") { Int($0.string(0) ?? "") ?? 0 }.first) ?? 0
        let rows = try db.query("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies") { row in
            CookieRow(host: row.string(0) ?? "", name: row.string(1) ?? "", value: row.string(2) ?? "", encrypted: row.data(3) ?? Data(),
                      path: row.string(4) ?? "/", expires: row.int(5), secure: row.bool(6), httpOnly: row.bool(7), sameSite: row.int(8))
        }.filter { r in wanted.contains { matches(host: r.host, site: $0) } }
        guard !rows.isEmpty else { return [] }
        let key = try safeStorageKey()
        return rows.compactMap { r in
            var value = r.value
            if value.isEmpty, !r.encrypted.isEmpty {
                guard let plain = decrypt(r.encrypted, key: key, hostDigestPrefix: version >= 24) else { return nil }
                value = plain
            }
            var cookie: [String: Any] = ["name": r.name, "value": value, "domain": r.host, "path": r.path, "httpOnly": r.httpOnly, "secure": r.secure]
            // Chrome counts microseconds since 1601; 0 means a session cookie.
            cookie["expires"] = r.expires == 0 ? -1 : Double(r.expires) / 1_000_000 - 11_644_473_600
            switch r.sameSite {
            case 0: cookie["sameSite"] = r.secure ? "None" : "Lax"
            case 1: cookie["sameSite"] = "Lax"
            case 2: cookie["sameSite"] = "Strict"
            default: break
            }
            return cookie
        }
    }

    /// The AES key Chrome derives from its Keychain password (PBKDF2-SHA1, "saltysalt", 1003 rounds, 16 bytes).
    static func safeStorageKey() throws -> Data {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Chrome Safe Storage",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw HostCommandError.invalid("macOS did not allow Pennant to read Chrome's cookie key. Try again and choose Allow (or Always Allow).")
            }
            throw HostCommandError.invalid("Could not read Chrome's cookie key from the Keychain (status \(status)).")
        }
        return derive(password: password)
    }

    static func derive(password: Data) -> Data {
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let pw = [CChar](password.map { CChar(bitPattern: $0) })
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        return Data(key)
    }

    /// "v10" + AES-128-CBC (IV of 16 spaces, PKCS7). Newer databases prefix the plaintext with SHA-256 of the host.
    static func decrypt(_ blob: Data, key: Data, hostDigestPrefix: Bool) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = [UInt8](blob.dropFirst(3))
        let k = [UInt8](key)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        let outCount = out.count
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             k, k.count, iv, cipher, cipher.count, &out, outCount, &moved)
        guard status == kCCSuccess else { return nil }
        var plain = Array(out.prefix(moved))
        if hostDigestPrefix, plain.count >= 32 { plain.removeFirst(32) }
        return String(bytes: plain, encoding: .utf8)
    }

    /// Imports the sites' cookies into Pennant's browser profile.
    public static func importInto(_ browser: BrowserRunner, profile: String, sites: [String]) async throws -> ChromeImportResult {
        let cookies = try cookies(profile: profile, sites: sites)
        guard !cookies.isEmpty else {
            throw HostCommandError.invalid("That Chrome profile has no sign-in for \(sites.joined(separator: ", ")). Sign in there first, or pick another profile.")
        }
        let input = try JSONSerialization.data(withJSONObject: ["cookies": cookies])
        let reply = try await browser.run(script: "import-cookies", source: BrowserScripts.addCookies, input: input, timeout: 120,
                                          redact: cookies.compactMap { $0["value"] as? String })
        let result = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        guard result["ok"] as? Bool == true else { throw HostCommandError.invalid("Could not add the cookies: \(result["error"] as? String ?? "unknown error")") }
        var perSite: [String: Int] = [:]
        var expiresAt: [String: Date] = [:]
        let wanted = sites.map(normalize)
        for c in cookies {
            guard let site = wanted.first(where: { matches(host: c["domain"] as? String ?? "", site: $0) }) else { continue }
            perSite[site, default: 0] += 1
            if let e = c["expires"] as? Double, e > 0 {
                let date = Date(timeIntervalSince1970: e)
                if date > (expiresAt[site] ?? .distantPast) { expiresAt[site] = date }
            }
        }
        return ChromeImportResult(profile: profile, cookies: cookies.count, perSite: perSite, expiresAt: expiresAt)
    }

    /// Deletes a site's cookies from Pennant's browser profile.
    public static func remove(site: String, from browser: BrowserRunner) async throws {
        let input = try JSONSerialization.data(withJSONObject: ["site": normalize(site)])
        let reply = try await browser.run(script: "clear-cookies", source: BrowserScripts.clearCookies, input: input, timeout: 120)
        let result = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        guard result["ok"] as? Bool == true else { throw HostCommandError.invalid("Could not remove the sign-in: \(result["error"] as? String ?? "unknown error")") }
    }
}
