import PennantCore
import Foundation

/// The Keychain service names from before each rename and what they became: Cove (`io.cove.host…`) became Ayes
/// (`dev.ayes.host…`), which became Pennant (`dev.pennant.host…`). Secrets move lazily: `KeychainStore.host(service:…)`
/// reads an account under its previous name the first time it's missing (and, through that store, under the name
/// before), then copies it over. The renamed host is a different app to macOS, so that first read may ask the user
/// once per secret, while the host is already running (an up-front copy blocked the host's start, and every restart
/// asked again).
public enum KeychainMigration {
    /// Old service → the service that replaced it.
    public static let renamed: [String: String] = [
        "dev.ayes.host": DeviceTokens.keychainService,
        "dev.ayes.host.chatgpt": "dev.pennant.host.chatgpt",
        "dev.ayes.host.vault": "dev.pennant.host.vault",
        "dev.ayes.host.mcp": "dev.pennant.host.mcp",
        "dev.ayes.host.people": "dev.pennant.host.people",
        "io.cove.host": "dev.ayes.host",
        "io.cove.host.chatgpt": "dev.ayes.host.chatgpt",
        "io.cove.host.vault": "dev.ayes.host.vault",
        "io.cove.host.mcp": "dev.ayes.host.mcp",
    ]

    /// The previous name of a service, if it had one.
    public static func legacyName(for service: String) -> String? {
        renamed.first { $0.value == service }?.key
    }
}
