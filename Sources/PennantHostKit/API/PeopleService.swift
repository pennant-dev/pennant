import PennantCore
import CryptoKit
import CommonCrypto
import Foundation
import Network

/// People and sign-in. The host runs the whole OAuth exchange itself (PKCE for Microsoft and Google, the device
/// flow for GitHub), so provider tokens never leave the Mac: a signed-in app only ever holds a host session. Who
/// may join is decided here, from the people list, the invites, and the allowed Microsoft organisations.
public actor PeopleService {
    public enum SignInError: Error, Sendable, CustomStringConvertible {
        case notConfigured(SignInProvider)
        case untrustedNetwork
        case unknownState
        case provider(String)
        case notInvited(email: String)
        case disabled
        case wrongPassword
        case lockedOut(until: Date)
        case weakPassword
        case badInviteCode

        public var code: String {
            switch self {
            case .notInvited: return "not_invited"
            case .untrustedNetwork: return "untrusted_network"
            case .wrongPassword: return "wrong_password"
            case .lockedOut: return "locked_out"
            case .weakPassword: return "weak_password"
            case .badInviteCode: return "bad_invite_code"
            default: return "sign_in_failed"
            }
        }

        public var description: String {
            switch self {
            case .notConfigured(let p): return "\(p.title) sign-in isn't set up on this host."
            case .untrustedNetwork: return "This connection isn't encrypted, so the Mac won't accept a sign-in over it. Update Pennant on this device (new versions always encrypt), or connect over Tailscale."
            case .unknownState: return "That sign-in expired. Start again."
            case .provider(let message): return message
            case .notInvited(let email): return "\(email) isn't invited to this host. Ask the owner to invite you."
            case .disabled: return "Your access to this host was removed."
            case .wrongPassword: return "That email and password don't match."
            case .lockedOut(let until): return "Too many tries. Wait \(max(1, Int(until.timeIntervalSinceNow.rounded(.up)))) seconds and try again."
            case .weakPassword: return "Use at least \(PeopleService.minimumPasswordLength) characters."
            case .badInviteCode: return "That invite code isn't valid, or it has expired. Ask for a new one."
            }
        }
    }

    /// What we learned about a person from the provider.
    struct Claims: Sendable {
        var identity: LinkedIdentity
        var name: String
    }

    private struct Pending: Sendable {
        var provider: SignInProvider
        var verifier: String
        var redirectURI: String
        var deviceCode: String?
        var interval: TimeInterval
        var expiresAt: Date
    }

    private let fileURL: URL
    /// Password hashes, apart from people.json (which clients see).
    private let passwordsURL: URL
    private var passwords: [String: PasswordHash]
    /// Failed password tries per email, for slowing down guessing.
    private var failures: [String: (count: Int, lockedUntil: Date?)] = [:]
    private let session: URLSession
    private var directory: PeopleDirectory
    private var pending: [String: Pending] = [:]

    /// Microsoft scopes asked for at sign-in: only who you are.
    static let microsoftScopes = ["openid", "profile", "email"]

    public init(paths: HostPaths, session: URLSession = .shared) {
        self.fileURL = paths.root.appendingPathComponent("people.json")
        self.passwordsURL = paths.root.appendingPathComponent("passwords.json")
        self.session = session
        self.directory = (try? JSONCodec.decode(PeopleDirectory.self, from: Data(contentsOf: fileURL))) ?? PeopleDirectory()
        self.passwords = (try? JSONCodec.decode([String: PasswordHash].self, from: Data(contentsOf: passwordsURL))) ?? [:]
    }

    // MARK: The directory

    public func snapshot() -> PeopleDirectory { directory }
    public func person(_ id: PersonID) -> Person? { directory.people.first { $0.id == id } }
    public var signInSettings: SignInSettings { directory.signIn }

    /// Invites an email: they join by signing in with a provider that confirms it, or with the one-time code.
    /// Inviting again gives a fresh code.
    public func invite(_ email: String) throws {
        let invite = PersonInvite(email: email, code: Self.inviteCode(), expiresAt: Date().addingTimeInterval(Self.inviteLifetime))
        guard invite.email.contains("@") else { throw SignInError.provider("That doesn't look like an email address.") }
        guard !directory.people.contains(where: { $0.email.lowercased() == invite.email }) else { throw SignInError.provider("\(invite.email) already has an account.") }
        directory.invites.removeAll { $0.email == invite.email }
        directory.invites.append(invite)
        try save()
    }

    static let inviteLifetime: TimeInterval = 7 * 24 * 3600

    /// Eight characters people can read out: no 0/O, 1/I/L.
    static func inviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    public func removeInvite(_ email: String) throws {
        directory.invites.removeAll { $0.email == email.lowercased() }
        try save()
    }

    /// Removes a member. Their password goes too; the caller signs out their devices.
    public func remove(_ id: PersonID) throws {
        guard let p = person(id), p.role != .owner else { return }
        directory.people.removeAll { $0.id == id }
        if passwords.removeValue(forKey: id.rawValue) != nil { try savePasswords() }
        try save()
    }

    public func setRole(_ id: PersonID, _ role: PersonRole) throws {
        guard let i = directory.people.firstIndex(where: { $0.id == id }) else { return }
        directory.people[i].role = role
        try save()
    }

    public func update(_ settings: SignInSettings) throws {
        directory.signIn = settings
        try save()
    }

    public func touch(_ id: PersonID) {
        guard let i = directory.people.firstIndex(where: { $0.id == id }) else { return }
        directory.people[i].lastSeenAt = Date()
        try? save()
    }


    private func save() throws {
        let data = try JSONCodec.encode(directory)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: Accounts and passwords

    public static let minimumPasswordLength = 10

    /// The owner's account: the owner who already has one, else a new one for the Mac's user.
    public func ownerAccount(defaultName: String) throws -> Person {
        if let owner = directory.people.first(where: { $0.role == .owner }) { return owner }
        let owner = Person(id: PersonID("owner"), name: defaultName, email: "", role: .owner)
        directory.people.append(owner)
        try save()
        return owner
    }

    public func updateAccount(_ id: PersonID, name: String, email: String) throws -> Person {
        guard let i = directory.people.firstIndex(where: { $0.id == id }) else { throw SignInError.unknownState }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty || email.contains("@") else { throw SignInError.provider("That doesn't look like an email address.") }
        if !email.isEmpty, directory.people.contains(where: { $0.id != id && $0.email.lowercased() == email }) {
            throw SignInError.provider("Someone else here already uses \(email).")
        }
        if !name.isEmpty { directory.people[i].name = name }
        directory.people[i].email = email
        try save()
        return directory.people[i]
    }

    /// Sets a password. `current` must match an existing one unless `skipCurrent` (the owner at the Mac itself).
    public func setPassword(_ id: PersonID, new: String, current: String?, skipCurrent: Bool = false) throws -> Person {
        guard let i = directory.people.firstIndex(where: { $0.id == id }) else { throw SignInError.unknownState }
        guard new.count >= Self.minimumPasswordLength else { throw SignInError.weakPassword }
        if let existing = passwords[id.rawValue], !skipCurrent {
            guard let current, existing.matches(current) else { throw SignInError.wrongPassword }
        }
        passwords[id.rawValue] = PasswordHash.make(new)
        try savePasswords()
        directory.people[i].hasPassword = true
        try save()
        return directory.people[i]
    }

    /// Email and password. Every attempt costs the same (a hash is checked even for unknown emails, so timing
    /// doesn't say who has an account), and repeated failures lock the email out for longer each time.
    public func signIn(email: String, password: String, trusted: Bool) throws -> Person {
        if !trusted { throw SignInError.untrustedNetwork }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let until = failures[email]?.lockedUntil, until > Date() { throw SignInError.lockedOut(until: until) }
        let person = directory.people.first { !$0.email.isEmpty && $0.email.lowercased() == email }
        let hash = person.flatMap { passwords[$0.id.rawValue] } ?? Self.decoy
        guard hash.matches(password), let person, passwords[person.id.rawValue] != nil else {
            var f = failures[email] ?? (0, nil)
            f.count += 1
            // Five free tries, then 30s, 60s, 120s… up to an hour.
            if f.count >= 5 { f.lockedUntil = Date().addingTimeInterval(min(3600, 30 * pow(2, Double(f.count - 5)))) }
            failures[email] = f
            throw SignInError.wrongPassword
        }
        failures[email] = nil
        if person.disabled { throw SignInError.disabled }
        touch(person.id)
        return self.person(person.id) ?? person
    }

    /// Joins with an invite code: a new member with the invited email and the chosen name and password.
    public func redeem(code: String, name: String, password: String, trusted: Bool) throws -> Person {
        if !trusted { throw SignInError.untrustedNetwork }
        let typed = PersonInvite.normalize(code)
        guard typed.count == 8, let invite = directory.invites.first(where: { $0.code == typed && !$0.isExpired }) else {
            throw SignInError.badInviteCode
        }
        guard password.count >= Self.minimumPasswordLength else { throw SignInError.weakPassword }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var person = Person(name: trimmed.isEmpty ? invite.email : trimmed, email: invite.email, lastSeenAt: Date())
        directory.invites.removeAll { $0.email == invite.email }
        directory.people.append(person)
        passwords[person.id.rawValue] = PasswordHash.make(password)
        try savePasswords()
        person.hasPassword = true
        if let i = directory.people.firstIndex(where: { $0.id == person.id }) { directory.people[i] = person }
        try save()
        return person
    }

    /// A hash nobody's password matches, checked for unknown emails so they take as long as known ones.
    private static let decoy = PasswordHash.make(PeopleService.random(24))

    private func savePasswords() throws {
        let data = try JSONCodec.encode(passwords)
        try data.write(to: passwordsURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordsURL.path)
    }

    // MARK: Network trust

    /// A Tailscale address: 100.64.0.0/10 or fd7a:115c:a1e0::/48.
    public static func isTailscale(_ endpoint: NWEndpoint?) -> Bool {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b.count == 4 && b[0] == 100 && (b[1] & 0xC0) == 0x40
        case .ipv6(let a):
            if a.isIPv4Mapped, let v4 = a.asIPv4 { return isTailscale(NWEndpoint.hostPort(host: .ipv4(v4), port: 1)) }
            let b = [UInt8](a.rawValue)
            return b.count == 16 && b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        default:
            return false
        }
    }

    // MARK: Starting a sign-in

    public func begin(_ provider: SignInProvider, redirectURI: String, trusted: Bool) async throws -> SignInStart {
        // Nothing that signs someone in may cross a network in the clear: the Mac itself, TLS, or Tailscale only.
        if !trusted { throw SignInError.untrustedNetwork }
        guard let config = directory.signIn.provider(provider) else { throw SignInError.notConfigured(provider) }
        pending = pending.filter { $0.value.expiresAt > Date() }
        let state = Self.random(24)
        let verifier = Self.random(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        switch provider {
        case .microsoft:
            let tenant = (config.tenant ?? "organizations").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "organizations"
            guard var c = URLComponents(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize") else { throw SignInError.notConfigured(provider) }
            c.queryItems = [
                .init(name: "client_id", value: config.clientID), .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: redirectURI), .init(name: "response_mode", value: "query"),
                .init(name: "scope", value: Self.microsoftScopes.joined(separator: " ")),
                .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"), .init(name: "prompt", value: "select_account"),
            ]
            pending[state] = Pending(provider: provider, verifier: verifier, redirectURI: redirectURI, interval: 0, expiresAt: Date().addingTimeInterval(600))
            return SignInStart(state: state, provider: provider, step: .browser(url: c.url!, callbackScheme: Self.scheme(of: redirectURI)))
        case .google:
            // Google's iOS clients redirect to the reversed client id.
            let redirect = Self.googleRedirect(config.clientID)
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [
                .init(name: "client_id", value: config.clientID), .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: redirect), .init(name: "scope", value: "openid email profile"),
                .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"), .init(name: "prompt", value: "select_account"),
            ]
            pending[state] = Pending(provider: provider, verifier: verifier, redirectURI: redirect, interval: 0, expiresAt: Date().addingTimeInterval(600))
            return SignInStart(state: state, provider: provider, step: .browser(url: c.url!, callbackScheme: Self.scheme(of: redirect)))
        case .github:
            let json = try await post("https://github.com/login/device/code", ["client_id": config.clientID, "scope": "read:user user:email"])
            guard let deviceCode = json["device_code"] as? String, let userCode = json["user_code"] as? String,
                  let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
                throw SignInError.provider((json["error_description"] as? String) ?? "GitHub didn't start the sign-in. Is device flow enabled on the OAuth app?")
            }
            let expires = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 900)
            pending[state] = Pending(provider: provider, verifier: "", redirectURI: "", deviceCode: deviceCode, interval: (json["interval"] as? Double) ?? 5, expiresAt: expires)
            return SignInStart(state: state, provider: provider, step: .deviceCode(userCode: userCode, verificationURL: uri, expiresAt: expires))
        }
    }

    // MARK: Finishing a sign-in

    /// Exchanges the code (or waits for GitHub's device code), then decides whether this person may join.
    public func complete(state: String, code: String?, trusted: Bool) async throws -> Person {
        if !trusted { throw SignInError.untrustedNetwork }
        guard let p = pending.removeValue(forKey: state), p.expiresAt > Date() else { throw SignInError.unknownState }
        guard let config = directory.signIn.provider(p.provider) else { throw SignInError.notConfigured(p.provider) }
        let claims: Claims
        switch p.provider {
        case .microsoft:
            guard let code else { throw SignInError.unknownState }
            let tenant = config.tenant ?? "organizations"
            let json = try await post("https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token", [
                "client_id": config.clientID, "grant_type": "authorization_code", "code": code, "redirect_uri": p.redirectURI,
                "code_verifier": p.verifier, "scope": Self.microsoftScopes.joined(separator: " "),
            ])
            claims = try Self.microsoftClaims(json, clientID: config.clientID)
        case .google:
            guard let code else { throw SignInError.unknownState }
            let json = try await post("https://oauth2.googleapis.com/token", [
                "client_id": config.clientID, "grant_type": "authorization_code", "code": code, "redirect_uri": p.redirectURI, "code_verifier": p.verifier,
            ])
            claims = try Self.googleClaims(json, clientID: config.clientID)
        case .github:
            claims = try await githubClaims(deviceCode: p.deviceCode ?? "", clientID: config.clientID, interval: p.interval, until: p.expiresAt)
        }
        return try admit(claims)
    }

    /// Who gets in: someone we know (by provider id, then by email), anyone from an allowed Microsoft organisation,
    /// or someone whose verified email was invited. Everyone else is turned away.
    func admit(_ claims: Claims) throws -> Person {
        let id = claims.identity
        let email = id.email.lowercased()
        var person: Person
        if let i = directory.people.firstIndex(where: { $0.identities.contains { $0.provider == id.provider && $0.subject == id.subject } }) {
            person = directory.people[i]
        } else if let i = directory.people.firstIndex(where: { !$0.email.isEmpty && $0.email.lowercased() == email }) {
            directory.people[i].identities.append(id)
            person = directory.people[i]
        } else if id.provider == .microsoft, let tid = id.tenantID, directory.signIn.allowedTenants.contains(tid) {
            person = Person(name: claims.name, email: email, identities: [id])
            directory.people.append(person)
        } else if directory.invites.contains(where: { $0.email == email }) {
            directory.invites.removeAll { $0.email == email }
            person = Person(name: claims.name, email: email, identities: [id])
            directory.people.append(person)
        } else {
            throw SignInError.notInvited(email: id.email)
        }
        if person.disabled { throw SignInError.disabled }
        if let i = directory.people.firstIndex(where: { $0.id == person.id }) {
            if !claims.name.isEmpty { directory.people[i].name = claims.name }
            directory.people[i].lastSeenAt = Date()
            person = directory.people[i]
        }
        try save()
        return person
    }

    // MARK: Providers

    /// The ID token came straight from the token endpoint over TLS, so its issuer is the provider (OIDC Core
    /// 3.1.3.7); the audience, expiry and organisation are still checked.
    static func microsoftClaims(_ json: [String: Any], clientID: String) throws -> Claims {
        guard let idToken = json["id_token"] as? String, let c = jwtClaims(idToken) else {
            throw SignInError.provider((json["error_description"] as? String).map { String($0.prefix(300)) } ?? "Microsoft didn't return an ID token.")
        }
        guard (c["aud"] as? String) == clientID else { throw SignInError.provider("The Microsoft token was for another app.") }
        if let exp = c["exp"] as? Double, Date(timeIntervalSince1970: exp) < Date() { throw SignInError.provider("The Microsoft token has expired.") }
        guard let oid = c["oid"] as? String, let tid = c["tid"] as? String,
              let email = (c["email"] as? String) ?? (c["preferred_username"] as? String), email.contains("@") else {
            throw SignInError.provider("Microsoft didn't say who you are.")
        }
        return Claims(identity: LinkedIdentity(provider: .microsoft, subject: oid, email: email, tenantID: tid),
                      name: (c["name"] as? String) ?? email)
    }

    static func googleClaims(_ json: [String: Any], clientID: String) throws -> Claims {
        guard let idToken = json["id_token"] as? String, let c = jwtClaims(idToken) else {
            throw SignInError.provider((json["error_description"] as? String) ?? "Google didn't return an ID token.")
        }
        guard (c["aud"] as? String) == clientID else { throw SignInError.provider("The Google token was for another app.") }
        guard ["accounts.google.com", "https://accounts.google.com"].contains(c["iss"] as? String ?? "") else { throw SignInError.provider("That token wasn't issued by Google.") }
        if let exp = c["exp"] as? Double, Date(timeIntervalSince1970: exp) < Date() { throw SignInError.provider("The Google token has expired.") }
        let verified = (c["email_verified"] as? Bool) ?? ((c["email_verified"] as? String) == "true")
        guard let sub = c["sub"] as? String, let email = c["email"] as? String, verified else {
            throw SignInError.provider("Google didn't confirm your email address.")
        }
        return Claims(identity: LinkedIdentity(provider: .google, subject: sub, email: email), name: (c["name"] as? String) ?? email)
    }

    private func githubClaims(deviceCode: String, clientID: String, interval: TimeInterval, until: Date) async throws -> Claims {
        var wait = max(interval, 5)
        var token: String?
        while token == nil {
            guard Date() < until else { throw SignInError.provider("The GitHub code expired. Start again.") }
            try await Task.sleep(for: .seconds(wait))
            let json = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "device_code": deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let t = json["access_token"] as? String { token = t; break }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": wait += 5
            case "access_denied": throw SignInError.provider("You declined the GitHub sign-in.")
            default: throw SignInError.provider((json["error_description"] as? String) ?? "GitHub sign-in failed.")
            }
        }
        let user = try await getJSON("https://api.github.com/user", token: token!)
        let emails = try await getJSONArray("https://api.github.com/user/emails", token: token!)
        guard let id = user["id"] as? Int,
              let email = emails.first(where: { ($0["primary"] as? Bool) == true && ($0["verified"] as? Bool) == true })?["email"] as? String else {
            throw SignInError.provider("GitHub didn't share a verified email address.")
        }
        let name = (user["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (user["login"] as? String) ?? email
        return Claims(identity: LinkedIdentity(provider: .github, subject: String(id), email: email), name: name)
    }

    // MARK: Helpers

    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func googleRedirect(_ clientID: String) -> String {
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        return reversed + ":/oauth2redirect"
    }

    static func scheme(of uri: String) -> String { uri.components(separatedBy: ":").first ?? uri }

    static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }

    private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func getJSON(_ url: String, token: String) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await get(url, token: token))) as? [String: Any] ?? [:]
    }

    private func getJSONArray(_ url: String, token: String) async throws -> [[String: Any]] {
        (try JSONSerialization.jsonObject(with: try await get(url, token: token))) as? [[String: Any]] ?? []
    }

    private func get(_ url: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pennant", forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request).0
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A salted PBKDF2-SHA256 password hash.
struct PasswordHash: Codable, Sendable {
    var salt: Data
    var hash: Data
    var iterations: Int

    static let defaultIterations = 310_000

    static func make(_ password: String, iterations: Int = defaultIterations) -> PasswordHash {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PasswordHash(salt: salt, hash: derive(password, salt: salt, iterations: iterations), iterations: iterations)
    }

    func matches(_ password: String) -> Bool {
        let candidate = Self.derive(password, salt: salt, iterations: iterations)
        guard candidate.count == hash.count else { return false }
        // Constant time: every byte is compared.
        return zip(candidate, hash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func derive(_ password: String, salt: Data, iterations: Int) -> Data {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { outBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     outBytes.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }
}
