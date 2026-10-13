import PennantCore
import PennantPluginKit
import Foundation

/// Plugins on this host (docs/PLUGINS.md). Installs them, keeps the owner's grants and settings, runs each enabled one
/// as its own sandboxed process, puts its tools in the broker, and answers what it asks Pennant for, within its grants.
/// Every request a plugin makes is logged, allowed or not.
public actor PluginManager {
    /// What's kept per plugin in `plugins/plugins.json`.
    struct Record: Codable, Sendable {
        var id: String
        var enabled: Bool
        /// Capability key → what it holds: a vault item's name for a secret slot, the command for a credential
        /// helper, "" for an ability.
        var grants: [String: String]
        var settings: JSONValue
        var installedAt: Date
    }

    /// Starts a plugin and hands back its connection. Pennant launches a sandboxed process; tests serve a plugin in-process.
    public typealias Launcher = @Sendable (_ bundle: PluginBundle, _ sandbox: String?, _ environment: [String: String],
                                           _ onLog: @escaping @Sendable (String) -> Void, _ onExit: @escaping @Sendable (Int32) -> Void) throws -> any PluginConnection

    public static let processLauncher: Launcher = { bundle, sandbox, environment, onLog, onExit in
        try PluginProcess(executable: bundle.executableURL, sandbox: sandbox, environment: environment, onLog: onLog, onExit: onExit)
    }

    private let folder: URL
    private let broker: ToolBroker
    private let vault: VaultService?
    private let hostName: String
    private let sandboxed: Bool
    private let launcher: Launcher
    /// Posts a plugin's note in the Pennant chat: (the plugin's name, the text).
    private var postToChat: (@Sendable (String, String) async -> Void)?

    private var records: [String: Record] = [:]
    private var bundles: [String: PluginBundle] = [:]
    private var loadErrors: [String: String] = [:]
    private var running: [String: any PluginConnection] = [:]
    private var states: [String: PluginStatus.State] = [:]
    private var lastErrors: [String: String] = [:]
    private var activity: [String: [PluginStatus.Activity]] = [:]
    private var credentials: [String: (output: String, until: Date)] = [:]
    private var crashes: [String: Int] = [:]
    /// Bumped on every start and stop, so an old process's exit doesn't touch a newer one.
    private var generations: [String: Int] = [:]

    static let maxStorage = 1 << 20
    static let maxRestarts = 5

    public init(root: URL, broker: ToolBroker, vault: VaultService?, hostName: String, sandboxed: Bool = true, launcher: @escaping Launcher = PluginManager.processLauncher) {
        self.folder = root.appendingPathComponent("plugins", isDirectory: true)
        self.broker = broker
        self.vault = vault
        self.hostName = hostName
        self.sandboxed = sandboxed
        self.launcher = launcher
    }

    public func setChatPoster(_ post: @escaping @Sendable (String, String) async -> Void) { postToChat = post }

    /// Tells the apps when a plugin is installed, removed, granted something, starts, stops or fails.
    private var onChange: (@Sendable ([PluginStatus]) async -> Void)?
    public func setChangeHandler(_ handler: @escaping @Sendable ([PluginStatus]) async -> Void) { onChange = handler }
    private func changed() async { await onChange?(statuses()) }

    nonisolated var registryURL: URL { folder.appendingPathComponent("plugins.json") }
    nonisolated func installedURL(_ id: String) -> URL { folder.appendingPathComponent("installed/\(id)", isDirectory: true) }
    nonisolated func dataURL(_ id: String) -> URL { folder.appendingPathComponent("data/\(id)", isDirectory: true) }

    // MARK: Lifecycle

    /// Loads what's installed and starts the enabled plugins.
    public func start() async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: registryURL) {
            do {
                let list = try decoder.decode([Record].self, from: data)
                records = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            } catch {
                log.error("Plugins: couldn't read \(registryURL.path): \(error)", category: "plugins")
            }
        }
        for id in records.keys.sorted() {
            loadBundle(id)
            if records[id]?.enabled == true { await launch(id) }
        }
        if !records.isEmpty { await changed() }
    }

    public func stop() async {
        for id in Array(running.keys) { await halt(id) }
    }

    private func loadBundle(_ id: String) {
        let dir = installedURL(id)
        let url = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "plugin" }
        do {
            guard let url else { throw PluginBundle.LoadError.noManifest(dir) }
            bundles[id] = try PluginBundle.load(url)
            loadErrors[id] = nil
        } catch {
            bundles[id] = nil
            loadErrors[id] = String(describing: error)
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records.values.sorted { $0.id < $1.id }).write(to: registryURL, options: .atomic)
    }

    // MARK: The owner's changes

    /// Installs the bundle at `path` (a `.plugin` folder), or updates the one with its id. Grants and settings carry
    /// over for what the new version still declares.
    public func install(path: String) async throws -> [PluginStatus] {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let bundle: PluginBundle
        do { bundle = try PluginBundle.load(source) } catch {
            guard Self.keptPrivate(source) else { throw error }
            throw HostCommandError.invalid("Pennant can't read \(source.path): macOS keeps that folder to the apps you allow there. Install it from the Plugins page or with `pennant plugin install`, which hand it over, or move it to another folder.")
        }
        let id = bundle.manifest.id
        guard source.pathExtension == "plugin" else { throw HostCommandError.invalid("A plugin is a folder whose name ends in .plugin.") }
        await halt(id)
        let fm = FileManager.default
        let target = installedURL(id)
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target.appendingPathComponent(source.lastPathComponent))
        try fm.createDirectory(at: dataURL(id), withIntermediateDirectories: true)
        let declared = Set(bundle.manifest.capabilities.map(\.key))
        var record = records[id] ?? Record(id: id, enabled: true, grants: [:], settings: .object([:]), installedAt: Date())
        record.grants = record.grants.filter { declared.contains($0.key) }
        record.installedAt = Date()
        records[id] = record
        try save()
        loadBundle(id)
        crashes[id] = 0
        log.info("Plugin \(id) \(bundle.manifest.version) installed from \(source.path)", category: "plugins")
        if record.enabled { await launch(id) }
        await changed()
        return statuses()
    }

    /// Whether macOS's privacy rules (Documents, Desktop, Downloads…) keep the host from opening a bundle. Only opening
    /// tells: permission checks pass, then the open fails with EPERM.
    static func keptPrivate(_ url: URL) -> Bool {
        for path in [url.appendingPathComponent("Contents/Resources/plugin.json"), url.appendingPathComponent("plugin.json"), url] {
            let fd = open(path.path, O_RDONLY)
            if fd >= 0 { close(fd); continue }
            if errno == EPERM { return true }
        }
        return false
    }

    public func remove(_ id: String) async throws -> [PluginStatus] {
        guard records[id] != nil else { throw HostCommandError.invalid("No plugin \(id).") }
        await halt(id)
        records[id] = nil
        bundles[id] = nil
        try? FileManager.default.removeItem(at: installedURL(id))
        try? FileManager.default.removeItem(at: dataURL(id))
        try save()
        log.info("Plugin \(id) removed", category: "plugins")
        await changed()
        return statuses()
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async throws -> [PluginStatus] {
        guard var record = records[id] else { throw HostCommandError.invalid("No plugin \(id).") }
        record.enabled = enabled
        records[id] = record
        try save()
        crashes[id] = 0
        if enabled { await restart(id) } else { await halt(id); states[id] = .stopped }
        await changed()
        return statuses()
    }

    /// Grants a capability the plugin declared. A secret slot takes a vault item's name; a credential helper takes the
    /// command to run (the plugin's suggestion when nil). The plugin restarts with it.
    public func grant(_ id: String, capability key: String, value: String?) async throws -> [PluginStatus] {
        guard var record = records[id], let bundle = bundles[id] else { throw HostCommandError.invalid("No plugin \(id).") }
        guard let capability = bundle.manifest.capabilities.first(where: { $0.key == key }) else {
            let keys = bundle.manifest.capabilities.map(\.key).joined(separator: ", ")
            throw HostCommandError.invalid("\(bundle.manifest.name) doesn't ask for \(key). It asks for: \(keys.isEmpty ? "nothing" : keys).")
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch capability {
        case .secret(let slot, _):
            guard let given = trimmed, !given.isEmpty else { throw HostCommandError.invalid("Name the vault item to put in \(slot).") }
            // As the Vault names its items.
            let name = given.lowercased().replacingOccurrences(of: " ", with: "-")
            if let vault, !(await vault.items()).contains(where: { $0.name == name }) {
                throw HostCommandError.invalid("There's no vault item named \(name). Add it in Settings › Vault first.")
            }
            record.grants[key] = name
        case .credential(let name, _, let suggest):
            guard let command = (trimmed?.isEmpty == false ? trimmed : suggest), !command.isEmpty else {
                throw HostCommandError.invalid("Give the command for \(name): it prints the token.")
            }
            record.grants[key] = command
        case .ability:
            record.grants[key] = ""
        }
        records[id] = record
        try save()
        credentials = credentials.filter { !$0.key.hasPrefix(id + "|") }
        log.info("Plugin \(id): granted \(key)", category: "plugins")
        if record.enabled { await restart(id) }
        await changed()
        return statuses()
    }

    public func revoke(_ id: String, capability key: String) async throws -> [PluginStatus] {
        guard var record = records[id] else { throw HostCommandError.invalid("No plugin \(id).") }
        record.grants[key] = nil
        records[id] = record
        try save()
        credentials = credentials.filter { !$0.key.hasPrefix(id + "|") }
        log.info("Plugin \(id): revoked \(key)", category: "plugins")
        if record.enabled { await restart(id) }
        await changed()
        return statuses()
    }

    public func setSettings(_ id: String, _ settings: JSONValue) async throws -> [PluginStatus] {
        guard var record = records[id] else { throw HostCommandError.invalid("No plugin \(id).") }
        guard case .object = settings else { throw HostCommandError.invalid("Settings are a JSON object.") }
        record.settings = settings
        records[id] = record
        try save()
        if record.enabled { await restart(id) }
        await changed()
        return statuses()
    }

    // MARK: Status

    public func statuses() -> [PluginStatus] {
        records.values.sorted { $0.id < $1.id }.map(status)
    }

    func status(_ record: Record) -> PluginStatus {
        let manifest = bundles[record.id]?.manifest
        let prefix = manifest?.toolPrefix ?? ""
        let tools = (manifest?.contributes.tools ?? []).map {
            PluginStatus.Tool(name: "\(prefix)__\($0.name)", description: $0.description, readOnly: $0.readOnly ?? false, asksFirst: $0.asksFirst ?? false)
        }
        let capabilities = (manifest?.capabilities ?? []).map { c -> PluginStatus.Capability in
            var suggest: String?
            if case .credential(_, _, let s) = c { suggest = s }
            return PluginStatus.Capability(key: c.key, why: c.why, suggest: suggest, granted: record.grants[c.key] != nil, value: record.grants[c.key].flatMap { $0.isEmpty ? nil : $0 })
        }
        return PluginStatus(id: record.id, name: manifest?.name ?? record.id, version: manifest?.version ?? "?", publisher: manifest?.publisher ?? "",
                            summary: manifest?.description ?? "", path: bundles[record.id]?.url.path ?? installedURL(record.id).path,
                            enabled: record.enabled, state: states[record.id] ?? .stopped, lastError: loadErrors[record.id] ?? lastErrors[record.id],
                            tools: tools, capabilities: capabilities, settings: record.settings,
                            settingsSchema: manifest?.contributes.settings.flatMap { try? JSONValue.from(encodable: $0) },
                            activity: Array((activity[record.id] ?? []).reversed().prefix(20)))
    }

    // MARK: Running

    private func restart(_ id: String) async {
        await halt(id)
        await launch(id)
    }

    private func launch(_ id: String) async {
        guard let record = records[id], record.enabled, running[id] == nil else { return }
        guard let bundle = bundles[id] else {
            states[id] = .failed
            lastErrors[id] = loadErrors[id] ?? "Not installed"
            return
        }
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        states[id] = .starting
        lastErrors[id] = nil
        let data = dataURL(id)
        try? FileManager.default.createDirectory(at: data.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        let sandbox = sandboxed ? PluginSandbox.profile(executable: bundle.executableURL, bundle: bundle.url, data: data, network: record.grants["network"] != nil) : nil
        let connection: any PluginConnection
        do {
            connection = try launcher(bundle, sandbox, ["HOME": data.path, "TMPDIR": data.appendingPathComponent("tmp").path + "/"],
                                      { line in log.info("[\(id)] \(line)", category: "plugins") },
                                      { [weak self] status in Task { await self?.exited(id, generation: generation, status: status) } })
        } catch {
            states[id] = .failed
            lastErrors[id] = "Couldn't start: \(error)"
            return
        }
        running[id] = connection
        await connection.channel.start(handler: { [weak self] method, params in
            guard let self else { throw PluginRPCError.closed }
            return try await self.answer(id, method, params)
        })
        do {
            let reply = try await connection.channel.request(PluginMethod.initialize, [
                "host": .string(hostName), "api": .string(PluginAPI.version),
                "granted": .array(record.grants.keys.sorted().map { .string($0) }),
                "settings": (try? PluginValue.from(record.settings)) ?? .object([:]),
            ], timeout: 20)
            guard generations[id] == generation else { return }
            let served = Set(reply["tools"]?.array?.compactMap(\.string) ?? [])
            let declared = bundle.manifest.contributes.tools
            for missing in declared where !served.contains(missing.name) {
                log.warn("Plugin \(id) declares \(missing.name) but doesn't serve it", category: "plugins")
            }
            let tools = declared.filter { served.isEmpty || served.contains($0.name) }.map { PluginToolProxy(manager: self, pluginID: id, manifest: bundle.manifest, declaration: $0) }
            let skipped = await broker.registerPluginTools(tools, plugin: id)
            for name in skipped { log.warn("Plugin \(id): a tool named \(name) already exists; its own isn't added", category: "plugins") }
            states[id] = .running
            log.info("Plugin \(id) running with \(tools.count - skipped.count) tools", category: "plugins")
        } catch {
            guard generations[id] == generation else { return }
            lastErrors[id] = "Didn't start: \(error)"
            await halt(id)
            states[id] = .failed
        }
    }

    /// Stops a plugin and takes its tools away.
    private func halt(_ id: String) async {
        generations[id, default: 0] += 1
        await broker.unregisterPluginTools(plugin: id)
        if let connection = running.removeValue(forKey: id) { await connection.stop(grace: 2) }
        if states[id] == .running || states[id] == .starting { states[id] = .stopped }
    }

    /// A plugin's process ended without being asked: its tools go, and it starts again a few times, further apart.
    private func exited(_ id: String, generation: Int, status: Int32) async {
        guard generations[id] == generation else { return }
        running[id] = nil
        await broker.unregisterPluginTools(plugin: id)
        let count = (crashes[id] ?? 0) + 1
        crashes[id] = count
        states[id] = .failed
        lastErrors[id] = "Stopped unexpectedly (exit \(status))"
        log.warn("Plugin \(id) exited (\(status)), crash \(count)", category: "plugins")
        await changed()
        guard count <= Self.maxRestarts, records[id]?.enabled == true else {
            lastErrors[id] = "Stopped unexpectedly \(count) times; turn it off and on to try again"
            return
        }
        try? await Task.sleep(for: .seconds(Double(1 << min(count, 5))))
        guard generations[id] == generation, running[id] == nil else { return }
        await launch(id)
        await changed()
    }

    // MARK: Calls

    /// Runs one of a plugin's tools for the model.
    func callTool(_ id: String, tool: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        guard let connection = running[id], states[id] == .running else {
            let name = bundles[id]?.manifest.name ?? id
            throw ToolError.failed("The \(name) plugin isn't running\(lastErrors[id].map { ": \($0)" } ?? "."). The owner can check it with `pennant plugin list`.")
        }
        note(id, "tool \(tool)", allowed: true)
        let reply = try await connection.channel.request(PluginMethod.toolCall, ["name": .string(tool), "arguments": try PluginValue.from(arguments)], timeout: 300)
        return (reply["text"]?.string ?? "", reply["isError"]?.bool ?? false)
    }

    /// Answers what a plugin asks of Pennant, within its grants.
    func answer(_ id: String, _ method: String, _ params: PluginValue) async throws -> PluginValue {
        guard let record = records[id] else { throw PluginRPCError.closed }
        func require(_ key: String) throws -> String {
            guard let value = record.grants[key] else {
                note(id, "\(method) \(key)", allowed: false)
                throw PluginRPCError.notGranted(key)
            }
            return value
        }
        switch method {
        case PluginMethod.secretGet:
            let slot = params["slot"]?.string ?? ""
            let item = try require("secret:\(slot)")
            guard let vault else { throw PluginRPCError.failed("The Vault isn't available.") }
            let resolved = await vault.resolve([item])
            guard let entry = resolved.entries[item] else { throw PluginRPCError.failed("The vault item \(item) for \(slot) is gone.") }
            note(id, "\(method) \(slot)", allowed: true)
            return .object(entry.mapValues { .string($0) })

        case PluginMethod.credentialGet:
            let name = params["name"]?.string ?? ""
            let command = try require("credential:\(name)")
            note(id, "\(method) \(name)", allowed: true)
            return ["output": .string(try await runHelper(id, name: name, command: command))]

        case PluginMethod.settingsGet:
            return (try? PluginValue.from(record.settings)) ?? .object([:])

        case PluginMethod.storageGet:
            return storage(id)[params["key"]?.string ?? ""] ?? .null

        case PluginMethod.storageSet:
            guard let key = params["key"]?.string, !key.isEmpty else { throw PluginRPCError.failed("storage/set needs a key") }
            var all = storage(id)
            let value = params["value"] ?? .null
            all[key] = value.isNull ? nil : value
            let data = try JSONEncoder().encode(all)
            guard data.count <= Self.maxStorage else { throw PluginRPCError.failed("A plugin keeps at most 1 MB.") }
            try data.write(to: dataURL(id).appendingPathComponent("storage.json"), options: .atomic)
            return .null

        case PluginMethod.chatPost:
            _ = try require("chat.post")
            let text = (params["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw PluginRPCError.failed("chat/post needs text") }
            note(id, method, allowed: true)
            await postToChat?(bundles[id]?.manifest.name ?? id, String(text.prefix(4000)))
            return .null

        case PluginMethod.log:
            log.info("[\(id)] \(params["message"]?.string ?? "")", category: "plugins")
            return .null

        default:
            note(id, method, allowed: false)
            throw PluginRPCError.unknownMethod(method)
        }
    }

    private func storage(_ id: String) -> [String: PluginValue] {
        guard let data = try? Data(contentsOf: dataURL(id).appendingPathComponent("storage.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: PluginValue].self, from: data)) ?? [:]
    }

    /// Runs the owner's command for a credential helper, as the owner, outside the sandbox. Its output is kept until
    /// the token in it expires (five minutes before), or for five minutes when it doesn't say.
    private func runHelper(_ id: String, name: String, command: String) async throws -> String {
        let key = "\(id)|\(name)"
        if let cached = credentials[key], cached.until > Date() { return cached.output }
        let result = try await BrowserRunner.run(executable: "/bin/zsh", arguments: ["-lc", command], cwd: FileManager.default.homeDirectoryForCurrentUser, stdin: nil, timeout: 60)
        guard result.status == 0 else {
            let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            throw PluginRPCError.failed("The \(name) helper failed (exit \(result.status))\(why.isEmpty ? "" : ": \(why)")")
        }
        let output = result.stdout
        credentials[key] = (output, Self.expiry(of: output)?.addingTimeInterval(-300) ?? Date().addingTimeInterval(300))
        return output
    }

    /// When the token a helper printed expires, if it says: `expires_on` (epoch seconds) or `expiresOn` in its JSON.
    static func expiry(of output: String) -> Date? {
        guard let data = output.data(using: .utf8), let json = try? JSONDecoder().decode(PluginValue.self, from: data) else { return nil }
        if let epoch = json["expires_on"]?.number ?? json["expires_on"]?.string.flatMap(Double.init) { return Date(timeIntervalSince1970: epoch) }
        return nil
    }

    private func note(_ id: String, _ what: String, allowed: Bool) {
        activity[id, default: []].append(PluginStatus.Activity(what: what, allowed: allowed))
        if activity[id]!.count > 100 { activity[id]!.removeFirst(activity[id]!.count - 100) }
        if !allowed { log.warn("Plugin \(id) was refused: \(what)", category: "plugins") }
    }
}

/// A plugin's tool, as the broker holds it.
struct PluginToolProxy: Tool {
    let manager: PluginManager
    let pluginID: String
    let manifest: PluginManifest
    let declaration: PluginToolDeclaration

    var spec: ToolSpec {
        let schema = (try? JSONValue.from(encodable: declaration.inputSchema)) ?? JSONSchema.object([:])
        return ToolSpec(name: "\(manifest.toolPrefix)__\(declaration.name)", description: "[\(manifest.name)] \(declaration.description)", inputSchema: schema,
                        isConsequential: declaration.readOnly != true, source: "plugin:\(pluginID)", asksFirst: declaration.asksFirst == true)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let result = try await manager.callTool(pluginID, tool: declaration.name, arguments: arguments)
        return ToolResult(callID: ToolCallID("pending"), name: spec.name, content: [.text(result.text.isEmpty ? "(no content)" : result.text)], isError: result.isError)
    }
}
