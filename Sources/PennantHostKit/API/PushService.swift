import CryptoKit
import Foundation
import PennantCore

/// Notifications on people's iPhones through Apple's push service (APNs), when something needs them: an approval
/// card, a question, a choice. The host signs with the owner's APNs key (a .p8 from the Apple Developer account,
/// kept in the Keychain) and talks HTTP/2 to Apple. Devices register themselves when their person signs in.
public actor PushService {
    private let paths: HostPaths
    private let keychain: KeychainStore
    private let session: URLSession
    private var devices: [PushDevice] = []
    private var jwt: (token: String, madeAt: Date)?
    private var lastError: String?
    /// What was already announced (an approval, a question), so an event seen twice notifies once.
    private var sent: [String] = []

    private var devicesURL: URL { paths.root.appendingPathComponent("push-devices.json") }

    public init(paths: HostPaths, keychain: KeychainStore, session: URLSession = .shared) {
        self.paths = paths
        self.keychain = keychain
        self.session = session
        if let data = try? Data(contentsOf: paths.root.appendingPathComponent("push-devices.json")),
           let saved = try? JSONCodec.decode([PushDevice].self, from: data) { devices = saved }
    }

    // MARK: Setup

    public func status() -> PushStatus {
        PushStatus(keyConfigured: keychain.get(account: "p8") != nil, keyID: keychain.get(account: "keyID"), teamID: keychain.get(account: "teamID"),
                   devices: devices, lastError: lastError)
    }

    /// Stores the APNs key. `p8` is the .p8 file's PEM text; it must parse as a P-256 key.
    public func setKey(keyID: String, teamID: String?, p8: String) throws {
        let keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyID.count == 10 else { throw PushError.badKey("The Key ID is the 10 characters in the file name AuthKey_<Key ID>.p8.") }
        _ = try Self.privateKey(p8)
        try keychain.set(account: "p8", value: p8)
        try keychain.set(account: "keyID", value: keyID)
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), !teamID.isEmpty { try keychain.set(account: "teamID", value: teamID) }
        jwt = nil
        lastError = nil
    }

    /// A device's token for a person. The app sends its Team ID too, so nobody has to type it.
    public func register(_ device: PushDevice, teamID: String?) throws {
        devices.removeAll { $0.token == device.token }
        devices.append(device)
        if let teamID, !teamID.isEmpty, keychain.get(account: "teamID") == nil { try? keychain.set(account: "teamID", value: teamID) }
        try save()
    }

    public func unregister(token: String) throws {
        devices.removeAll { $0.token == token }
        try save()
    }

    private func save() throws {
        try JSONCodec.encode(devices).write(to: devicesURL, options: .atomic)
    }

    // MARK: Sending

    /// Sends to the devices of `personIDs` (all devices when empty). `key` makes it once-only. Returns how many went.
    @discardableResult
    public func notify(title: String, body: String, to personIDs: [PersonID], key: String?, info: [String: String] = [:], thread: String? = nil) async -> Int {
        if let key {
            if sent.contains(key) { return 0 }
            sent.append(key)
            if sent.count > 500 { sent.removeFirst(sent.count - 500) }
        }
        let targets = personIDs.isEmpty ? devices : devices.filter { $0.personID.map(personIDs.contains) ?? false }
        guard !targets.isEmpty, keychain.get(account: "p8") != nil else { return 0 }
        var delivered = 0
        for device in targets {
            do {
                try await send(title: title, body: body, info: info, thread: thread, to: device)
                delivered += 1
            } catch PushError.goneDevice {
                try? unregister(token: device.token)
            } catch {
                lastError = "\(error)"
                log.warn("Push to \(device.name) failed: \(error)", category: "push")
            }
        }
        return delivered
    }

    private func send(title: String, body: String, info: [String: String], thread: String?, to device: PushDevice) async throws {
        let host = device.environment == "development" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(device.token)")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(try token())", forHTTPHeaderField: "authorization")
        request.setValue(device.bundleID, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default", "interruption-level": "time-sensitive"]
        if let thread { aps["thread-id"] = thread }
        var payload: [String: Any] = ["aps": aps]
        for (k, v) in info { payload[k] = v }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code != 200 else { return }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? "HTTP \(code)"
        if code == 410 || reason == "BadDeviceToken" || reason == "Unregistered" { throw PushError.goneDevice }
        if reason == "ExpiredProviderToken" { jwt = nil }
        throw PushError.rejected(reason)
    }

    /// The provider token Apple wants: an ES256 JWT, reused for up to 50 minutes.
    func token(now: Date = Date()) throws -> String {
        if let jwt, now.timeIntervalSince(jwt.madeAt) < 50 * 60 { return jwt.token }
        guard let p8 = keychain.get(account: "p8"), let keyID = keychain.get(account: "keyID") else { throw PushError.badKey("No APNs key yet.") }
        guard let teamID = keychain.get(account: "teamID") else { throw PushError.badKey("The Team ID isn't known yet; open the iPhone app once.") }
        let key = try Self.privateKey(p8)
        func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let header = b64(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID]))
        let claims = b64(try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(now.timeIntervalSince1970)]))
        let signature = try key.signature(for: Data("\(header).\(claims)".utf8))
        let token = "\(header).\(claims).\(b64(signature.rawRepresentation))"
        jwt = (token, now)
        return token
    }

    static func privateKey(_ p8: String) throws -> P256.Signing.PrivateKey {
        do { return try P256.Signing.PrivateKey(pemRepresentation: p8.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { throw PushError.badKey("That isn't an APNs key file (.p8).") }
    }
}

public enum PushError: Error, CustomStringConvertible {
    case badKey(String)
    case rejected(String)
    case goneDevice
    public var description: String {
        switch self {
        case .badKey(let s): return s
        case .rejected(let r): return "Apple refused the notification: \(r)"
        case .goneDevice: return "The device is no longer registered"
        }
    }
}
