import PennantCore
import Foundation

/// An API key kept in the Vault instead of the config: read for each request (the Vault is the Keychain, so this is
/// cheap), sent as a bearer token or in a header of its own (Azure's `api-key`).
public struct VaultKeyAuthority: EndpointAuthority {
    let entry: String
    let baseURL: String
    /// Nil: `Authorization: Bearer <key>`.
    let header: String?
    let vault: VaultService

    public init(entry: String, baseURL: String, header: String? = nil, vault: VaultService) {
        self.entry = entry
        self.baseURL = baseURL
        self.header = header
        self.vault = vault
    }

    public func credential() async throws -> EndpointCredential {
        let key = try await Self.key(entry, in: vault)
        if let header { return EndpointCredential(bearer: "", baseURL: baseURL, headers: [header: key]) }
        return EndpointCredential(bearer: key, baseURL: baseURL)
    }

    /// The entry may have been updated since the request started; read it again once.
    public func refreshCredential(rejected: EndpointCredential) async throws -> EndpointCredential { try await credential() }

    /// The key in a Vault entry: its secret, else its password.
    static func key(_ entry: String, in vault: VaultService) async throws -> String {
        let found = await vault.resolve([entry]).entries[entry.lowercased()]
        guard let key = (found?["secret"] ?? found?["password"])?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw InferenceError.unreachable(found == nil ? "The Vault has no entry named \(entry)." : "The Vault entry \(entry) has no secret or password to use as the key.")
        }
        return key
    }
}
