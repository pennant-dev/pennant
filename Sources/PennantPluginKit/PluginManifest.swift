import Foundation

/// What a plugin says about itself, from its `plugin.json`: who it is, what it needs, and what it adds.
public struct PluginManifest: Codable, Hashable, Sendable {
    /// Reverse-DNS, unique in the marketplace: "dev.pennant.azure".
    public var id: String
    public var name: String
    public var version: String
    public var publisher: String
    public var description: String
    /// The plugin API it was built against.
    public var api: String
    /// The Pennant versions it works with, e.g. ">=0.4".
    public var pennant: String?
    /// The executable, relative to the bundle (default: `Contents/MacOS/<the bundle's name>`).
    public var executable: String?
    public var capabilities: [PluginCapability]
    public var contributes: Contributions

    public struct Contributions: Codable, Hashable, Sendable {
        public var tools: [PluginToolDeclaration]
        /// JSON Schema for the plugin's settings; the owner edits them in Pennant.
        public var settings: PluginValue?
        public init(tools: [PluginToolDeclaration] = [], settings: PluginValue? = nil) { self.tools = tools; self.settings = settings }
    }

    public init(id: String, name: String, version: String, publisher: String, description: String, api: String = PluginAPI.version,
                pennant: String? = nil, executable: String? = nil, capabilities: [PluginCapability] = [], contributes: Contributions = Contributions()) {
        self.id = id; self.name = name; self.version = version; self.publisher = publisher; self.description = description
        self.api = api; self.pennant = pennant; self.executable = executable; self.capabilities = capabilities; self.contributes = contributes
    }

    /// The prefix its tools carry for the model: the name, lower case, letters and digits ("azure").
    public var toolPrefix: String {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug.isEmpty ? "plugin" : slug
    }

    /// What's wrong with it, if anything: a manifest that fails here isn't installed.
    public func problems() -> [String] {
        var out: [String] = []
        if id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+){2,}$"#, options: .regularExpression) == nil { out.append("id \"\(id)\" isn't reverse-DNS (like dev.example.tool)") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("name is empty") }
        if version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) == nil { out.append("version \"\(version)\" isn't semver") }
        if api != PluginAPI.version { out.append("built for plugin API \(api); this Pennant speaks \(PluginAPI.version)") }
        var seen = Set<String>()
        for tool in contributes.tools {
            if tool.name.range(of: #"^[a-z][a-z0-9_]{0,48}$"#, options: .regularExpression) == nil { out.append("tool name \"\(tool.name)\" must be lower-case letters, digits and _") }
            if !seen.insert(tool.name).inserted { out.append("tool \"\(tool.name)\" is declared twice") }
            if tool.description.isEmpty { out.append("tool \"\(tool.name)\" has no description") }
            if tool.readOnly == true, tool.asksFirst == true { out.append("tool \"\(tool.name)\" can't be both readOnly and asksFirst") }
        }
        var keys = Set<String>()
        for capability in capabilities {
            if !keys.insert(capability.key).inserted { out.append("capability \(capability.key) is listed twice") }
            if case .ability(let name) = capability, !PluginCapability.abilities.contains(name) {
                out.append("there's no capability \(name) (abilities: \(PluginCapability.abilities.sorted().joined(separator: ", ")))")
            }
        }
        return out
    }
}

/// The plugin API's version. A manifest built for another can't be installed.
public enum PluginAPI {
    public static let version = "1"
}

/// A tool the plugin adds for the model.
public struct PluginToolDeclaration: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: PluginValue
    /// Only reads: never needs the owner's OK.
    public var readOnly: Bool?
    /// Changes something the owner wants to approve every time (scale a node pool, restart an app).
    public var asksFirst: Bool?

    public init(name: String, description: String, inputSchema: PluginValue = ["type": "object", "properties": [:]], readOnly: Bool? = nil, asksFirst: Bool? = nil) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly; self.asksFirst = asksFirst
    }
}

/// Something a plugin needs from Pennant. Each is granted, or not, by the owner.
public enum PluginCapability: Hashable, Sendable, Codable {
    /// A named secret: the owner fills the slot from the Vault.
    case secret(slot: String, why: String)
    /// A named credential helper: the owner approves the command Pennant runs to get a token.
    case credential(name: String, why: String, suggest: String?)
    /// A plain ability: "network", "chat.post", "storage".
    case ability(String)

    /// The abilities a plugin can ask for by name. (Its own storage and settings need no grant.)
    public static let abilities: Set<String> = ["network", "chat.post"]

    /// How grants refer to it: "secret:azure-sp", "credential:azure-management", "chat.post".
    public var key: String {
        switch self {
        case .secret(let slot, _): return "secret:\(slot)"
        case .credential(let name, _, _): return "credential:\(name)"
        case .ability(let name): return name
        }
    }

    public var why: String? {
        switch self {
        case .secret(_, let why), .credential(_, let why, _): return why
        case .ability: return nil
        }
    }

    private enum Keys: String, CodingKey { case secret, credential, why, suggest }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = .ability(name)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        if let slot = try c.decodeIfPresent(String.self, forKey: .secret) { self = .secret(slot: slot, why: why) }
        else if let name = try c.decodeIfPresent(String.self, forKey: .credential) {
            self = .credential(name: name, why: why, suggest: try c.decodeIfPresent(String.self, forKey: .suggest))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "A capability is a name, {\"secret\": …} or {\"credential\": …}"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .ability(let name):
            var c = encoder.singleValueContainer()
            try c.encode(name)
        case .secret(let slot, let why):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(slot, forKey: .secret); try c.encode(why, forKey: .why)
        case .credential(let name, let why, let suggest):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(name, forKey: .credential); try c.encode(why, forKey: .why); try c.encodeIfPresent(suggest, forKey: .suggest)
        }
    }
}

/// A plugin on disk: its manifest and where its executable is. A bundle is `<Name>.plugin/Contents/{Info.plist,
/// MacOS/<exe>, Resources/plugin.json}`; a development folder may keep `plugin.json` at its top.
public struct PluginBundle: Sendable {
    public var url: URL
    public var manifest: PluginManifest
    public var executableURL: URL

    public enum LoadError: Error, CustomStringConvertible {
        case noManifest(URL), unreadable(String), invalid([String]), noExecutable(URL)
        public var description: String {
            switch self {
            case .noManifest(let url): return "No plugin.json in \(url.path) (looked in Contents/Resources and at the top)"
            case .unreadable(let why): return "plugin.json couldn't be read: \(why)"
            case .invalid(let problems): return "plugin.json: " + problems.joined(separator: "; ")
            case .noExecutable(let url): return "No executable at \(url.path)"
            }
        }
    }

    public static func load(_ url: URL) throws -> PluginBundle {
        let fm = FileManager.default
        let candidates = [url.appendingPathComponent("Contents/Resources/plugin.json"), url.appendingPathComponent("plugin.json")]
        guard let file = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { throw LoadError.noManifest(url) }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: file)) }
        catch { throw LoadError.unreadable(String(describing: error)) }
        let problems = manifest.problems()
        guard problems.isEmpty else { throw LoadError.invalid(problems) }
        let exe = url.appendingPathComponent(manifest.executable ?? "Contents/MacOS/\(url.deletingPathExtension().lastPathComponent)")
        guard fm.isExecutableFile(atPath: exe.path) else { throw LoadError.noExecutable(exe) }
        return PluginBundle(url: url, manifest: manifest, executableURL: exe)
    }
}
