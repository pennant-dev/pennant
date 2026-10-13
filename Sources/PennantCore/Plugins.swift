import Foundation

/// A plugin installed on the host, as the owner sees it: what it is, what it may use, and how it's doing.
public struct PluginStatus: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var publisher: String
    public var summary: String
    /// Where it's installed on the host.
    public var path: String
    public var enabled: Bool
    public var state: State
    public var lastError: String?
    public var tools: [Tool]
    public var capabilities: [Capability]
    public var settings: JSONValue
    public var settingsSchema: JSONValue?
    /// Its latest requests to Pennant, newest first.
    public var activity: [Activity]

    public enum State: String, Codable, Sendable { case running, starting, stopped, failed }

    public struct Tool: Hashable, Codable, Sendable {
        /// As the model calls it: "azure__costs".
        public var name: String
        public var description: String
        public var readOnly: Bool
        public var asksFirst: Bool
        public init(name: String, description: String, readOnly: Bool, asksFirst: Bool) {
            self.name = name; self.description = description; self.readOnly = readOnly; self.asksFirst = asksFirst
        }
    }

    public struct Capability: Hashable, Codable, Sendable {
        /// "secret:<slot>", "credential:<name>", or an ability ("network", "chat.post", "storage").
        public var key: String
        public var why: String?
        /// For a credential helper: the command the plugin suggests.
        public var suggest: String?
        public var granted: Bool
        /// What the grant holds: the vault item's name for a secret, the approved command for a credential helper.
        public var value: String?
        public init(key: String, why: String? = nil, suggest: String? = nil, granted: Bool, value: String? = nil) {
            self.key = key; self.why = why; self.suggest = suggest; self.granted = granted; self.value = value
        }
        public var kind: String { key.hasPrefix("secret:") ? "secret" : key.hasPrefix("credential:") ? "credential" : "ability" }
    }

    public struct Activity: Hashable, Codable, Sendable {
        public var at: Date
        /// "secrets/get azure-service-principal", "tool azure__costs".
        public var what: String
        public var allowed: Bool
        public init(at: Date = Date(), what: String, allowed: Bool) { self.at = at; self.what = what; self.allowed = allowed }
    }

    public init(id: String, name: String, version: String, publisher: String, summary: String, path: String, enabled: Bool, state: State,
                lastError: String? = nil, tools: [Tool] = [], capabilities: [Capability] = [], settings: JSONValue = .object([:]),
                settingsSchema: JSONValue? = nil, activity: [Activity] = []) {
        self.id = id; self.name = name; self.version = version; self.publisher = publisher; self.summary = summary; self.path = path
        self.enabled = enabled; self.state = state; self.lastError = lastError; self.tools = tools; self.capabilities = capabilities
        self.settings = settings; self.settingsSchema = settingsSchema; self.activity = activity
    }
}
