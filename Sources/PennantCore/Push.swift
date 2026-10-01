import Foundation

/// An iPhone that asked for notifications: its APNs token, whose it is, and which APNs environment it lives in
/// (a debug build is "development", TestFlight and the App Store "production").
public struct PushDevice: Hashable, Codable, Sendable, Identifiable {
    public var token: String
    public var environment: String
    public var personID: PersonID?
    public var name: String
    public var bundleID: String
    public var registeredAt: Date
    public var id: String { token }

    public init(token: String, environment: String, personID: PersonID?, name: String, bundleID: String, registeredAt: Date = Date()) {
        self.token = token; self.environment = environment; self.personID = personID; self.name = name; self.bundleID = bundleID; self.registeredAt = registeredAt
    }
}

/// Whether the host can send notifications, and to how many devices.
public struct PushStatus: Hashable, Codable, Sendable {
    public var keyConfigured: Bool
    public var keyID: String?
    public var teamID: String?
    public var devices: [PushDevice]
    public var lastError: String?

    public init(keyConfigured: Bool, keyID: String?, teamID: String?, devices: [PushDevice], lastError: String?) {
        self.keyConfigured = keyConfigured; self.keyID = keyID; self.teamID = teamID; self.devices = devices; self.lastError = lastError
    }
}
