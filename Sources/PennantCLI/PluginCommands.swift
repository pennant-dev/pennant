import PennantClientKit
import PennantCore
import Foundation

// Plugins: installing them, what they may use, and their settings.

func describe(_ p: PluginStatus) -> String {
    let state = p.enabled ? p.state.rawValue : "off"
    let missing = p.capabilities.filter { !$0.granted }.count
    let grants = missing == 0 ? "" : "  \(missing) not granted"
    let error = p.lastError.map { " — \($0.prefix(120))" } ?? ""
    return "\(p.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(p.version.padding(toLength: 8, withPad: " ", startingAt: 0)) \(state.padding(toLength: 9, withPad: " ", startingAt: 0)) tools=\(p.tools.count)\(grants)  [\(p.id)]\(error)"
}

func describeInDetail(_ p: PluginStatus) -> [String] {
    var lines = [describe(p), "  \(p.summary)", "  by \(p.publisher), at \(p.path)", "", "  Asks for:"]
    for c in p.capabilities {
        let mark = c.granted ? "granted" : "not granted"
        let value = c.value.map { c.kind == "secret" ? " (vault item \($0))" : " (runs: \($0))" } ?? ""
        lines.append("    \(c.key): \(mark)\(value)\(c.why.map { "\n      \($0)" } ?? "")")
        if !c.granted, let suggest = c.suggest { lines.append("      suggests: \(suggest)") }
    }
    lines.append("")
    lines.append("  Tools:")
    for t in p.tools {
        let kind = t.asksFirst ? " (asks first)" : t.readOnly ? " (reads only)" : ""
        lines.append("    \(t.name)\(kind)")
    }
    if case .object(let o) = p.settings, !o.isEmpty {
        lines.append("")
        lines.append("  Settings: " + JSONCodec.string(p.settings))
    }
    if !p.activity.isEmpty {
        lines.append("")
        lines.append("  Lately:")
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        for a in p.activity.prefix(10) { lines.append("    \(f.string(from: a.at))  \(a.allowed ? "" : "REFUSED ")\(a.what)") }
    }
    return lines
}

enum PluginCLIError {
    static func message(_ error: Error) -> String {
        if case .hostError(_, let message)? = error as? HostSessionError { return message }
        return String(describing: error)
    }
}

/// `pennant plugin list|show|install|remove|enable|disable|grant|revoke|set …`.
@MainActor
func runPlugin(_ sub: String, args: [String], options: CLIOptions) async throws {
    let session = try await connect(options)
    func send(_ body: CommandBody) async throws -> [PluginStatus] {
        let reply = try await session.send(body, timeout: 120)
        guard case .plugins(let list) = reply else { await session.disconnect(); fail(replyError(reply)) }
        return list
    }
    func find(_ ident: String?) async throws -> PluginStatus {
        guard let ident else { await session.disconnect(); fail("Name the plugin: its name or id.") }
        let list = try await send(.listPlugins)
        let lower = ident.lowercased()
        guard let p = list.first(where: { $0.id == ident }) ?? list.first(where: { $0.name.lowercased() == lower }) ?? list.first(where: { $0.id.hasSuffix("." + lower) }) else {
            await session.disconnect()
            fail("No plugin \(ident).\(list.isEmpty ? "" : " Installed: \(list.map(\.name).joined(separator: ", "))")")
        }
        return p
    }
    func show(_ list: [PluginStatus], _ id: String) {
        if let p = list.first(where: { $0.id == id }) { describeInDetail(p).forEach(out) }
    }

    switch sub {
    case "list":
        let list = try await send(.listPlugins)
        if list.isEmpty { out("No plugins. Install one with `pennant plugin install <path to .plugin>`.") }
        for p in list { out(describe(p)) }

    case "show":
        let p = try await find(args.first)
        describeInDetail(p).forEach(out)

    case "install":
        guard let path = args.first else { await session.disconnect(); fail("Usage: pennant plugin install <path to .plugin>") }
        let absolute = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
        let list: [PluginStatus]
        do { list = try await session.installPlugin(from: URL(fileURLWithPath: absolute)) } catch {
            await session.disconnect()
            fail(PluginCLIError.message(error))
        }
        guard let p = list.first(where: { $0.path.hasSuffix("/" + URL(fileURLWithPath: absolute).lastPathComponent) }) ?? list.last else { break }
        describeInDetail(p).forEach(out)
        let wanted = p.capabilities.filter { !$0.granted }
        if !wanted.isEmpty {
            out("")
            out("Grant what you want it to have:")
            for c in wanted {
                switch c.kind {
                case "secret": out("  pennant plugin grant \(p.name) \(c.key) <vault item>")
                case "credential": out("  pennant plugin grant \(p.name) \(c.key)          (runs the suggested command; or add your own)")
                default: out("  pennant plugin grant \(p.name) \(c.key)")
                }
            }
        }

    case "remove":
        let p = try await find(args.first)
        _ = try await send(.removePlugin(id: p.id))
        out("Removed \(p.name).")

    case "enable", "disable":
        let p = try await find(args.first)
        let list = try await send(.setPluginEnabled(id: p.id, enabled: sub == "enable"))
        if let now = list.first(where: { $0.id == p.id }) { out(describe(now)) }

    case "grant":
        guard args.count >= 2 else { await session.disconnect(); fail("Usage: pennant plugin grant <plugin> <capability> [vault item | command]") }
        let p = try await find(args[0])
        let value = args.count > 2 ? args.dropFirst(2).joined(separator: " ") : nil
        let list = try await send(.grantPlugin(id: p.id, capability: args[1], value: value))
        show(list, p.id)

    case "revoke":
        guard args.count >= 2 else { await session.disconnect(); fail("Usage: pennant plugin revoke <plugin> <capability>") }
        let p = try await find(args[0])
        let list = try await send(.revokePlugin(id: p.id, capability: args[1]))
        show(list, p.id)

    case "set":
        // pennant plugin set <plugin> <key> <value…>: a JSON value, or plain text; "" removes the key.
        guard args.count >= 2 else { await session.disconnect(); fail("Usage: pennant plugin set <plugin> <key> [value]   (JSON or text; no value removes it)") }
        let p = try await find(args[0])
        guard case .object(var settings) = p.settings else { await session.disconnect(); fail("\(p.name)'s settings aren't an object.") }
        let raw = args.dropFirst(2).joined(separator: " ")
        if raw.isEmpty {
            settings[args[1]] = nil
        } else if let data = raw.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            settings[args[1]] = json
        } else if raw.contains(",") {
            settings[args[1]] = .array(raw.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        } else {
            settings[args[1]] = .string(raw)
        }
        let list = try await send(.setPluginSettings(id: p.id, settings: .object(settings)))
        show(list, p.id)

    default:
        await session.disconnect()
        fail("Unknown plugin subcommand '\(sub)'. Try: list, show, install, grant, revoke, set, enable, disable, remove")
    }
    await session.disconnect()
}
