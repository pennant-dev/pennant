import PennantClientKit
import PennantCore
import Foundation

// Connected services (MCP servers): adding them, signing in, and the catalog.

func describe(_ s: MCPServerStatus) -> String {
    let auth = s.authDetail.map { "\(s.authState.rawValue) · \($0)" } ?? s.authState.rawValue
    let error = s.lastError.map { " — \($0.prefix(100))" } ?? ""
    let name = s.config.name.padding(toLength: 20, withPad: " ", startingAt: 0)
    let state = s.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
    return "\(name) \(state) tools=\(s.toolCount)  \(s.config.auth.label): \(auth)  [\(shortID(s.id.rawValue))]\(error)"
}

func describe(_ e: MCPCatalogEntry) -> String {
    let location = e.url ?? ([e.command ?? ""] + e.arguments).joined(separator: " ")
    let verified = e.verified ? "verified" : "unverified"
    return "\(e.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(e.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(e.auth.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(location)  [\(verified)]"
}

/// Resolves `<id|name>` against the server list: exact id, then case-insensitive name, then id prefix.
@MainActor
func findMCPServer(_ session: HostSession, _ ident: String) -> MCPServerStatus? {
    let lower = ident.lowercased()
    let list = session.state.mcpServers
    return list.first { $0.id.rawValue == ident }
        ?? list.first { $0.config.name.lowercased() == lower }
        ?? list.first { $0.id.rawValue.hasPrefix(ident) }
}

@MainActor
func requireMCPServer(_ session: HostSession, _ ident: String?) async throws -> MCPServerStatus {
    guard let ident else { await session.disconnect(); fail("Usage: pennant mcp <command> <id|name>") }
    try await session.loadMCPServers()
    guard let server = findMCPServer(session, ident) else {
        let names = session.state.mcpServers.map(\.config.name).joined(separator: ", ")
        await session.disconnect()
        fail("No MCP server '\(ident)'.\(names.isEmpty ? "" : " Servers: \(names)")")
    }
    return server
}

/// `pennant mcp list|add|connect|key|signout|remove|catalog …`.
@MainActor
func runMCP(_ sub: String, args: [String], options: CLIOptions) async throws {
    let session = try await connect(options)
    switch sub {
    case "list":
        try await session.loadMCPServers()
        if session.state.mcpServers.isEmpty { out("No MCP servers. Add one with `pennant mcp add <name> <url>` or see `pennant mcp catalog`.") }
        for s in session.state.mcpServers { out(describe(s)) }

    case "catalog":
        let entries = try await session.mcpCatalog()
        if entries.isEmpty { out("The catalog is empty.") }
        for e in entries { out(describe(e)) }

    case "add":
        var positional: [String] = []
        var flags: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") { flags[String(name[..<eq])] = String(name[name.index(after: eq)...]) }
                else { i += 1; flags[name] = i < args.count ? args[i] : "" }
            } else {
                positional.append(a)
            }
            i += 1
        }
        guard positional.count >= 2, let url = URL(string: positional[1].trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
            await session.disconnect()
            fail("Usage: pennant mcp add <name> <url> [--auth none|key|oauth] [--header H] [--prefix P] [--scopes a,b] [--client-id ID] [--client-secret S]")
        }
        let auth: MCPAuth
        switch flags["auth"] ?? "none" {
        case "none": auth = .none
        case "key", "apikey", "api-key":
            let header = flags["header"] ?? "Authorization"
            let prefix = flags["prefix"] ?? (header.lowercased() == "authorization" ? "Bearer " : "")
            auth = .apiKey(header: header, prefix: prefix)
        case "oauth":
            let scopes = (flags["scopes"] ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            auth = .oauth(scopes: scopes, clientID: flags["client-id"], clientSecret: flags["client-secret"])
        default:
            await session.disconnect()
            fail("--auth must be none, key, or oauth")
        }
        let config = MCPServerConfig(name: positional[0], transport: .http(url: url), auth: auth)
        let list = try await session.addMCPServer(config)
        if let s = list.first(where: { $0.id == config.id }) { out(describe(s)) }
        switch auth {
        case .none: break
        case .apiKey: out("Store the key with: pennant mcp key \(shortID(config.id.rawValue)) <secret>")
        case .oauth: out("Sign in with: pennant mcp connect \(shortID(config.id.rawValue))")
        }

    case "connect":
        let server = try await requireMCPServer(session, args.first)
        guard server.config.isHTTP else { await session.disconnect(); fail("\(server.config.name) is a local server; it needs no sign-in.") }
        guard case .oauth = server.config.auth else {
            await session.disconnect()
            fail("\(server.config.name) uses \(server.config.auth.label.lowercased()); store a key with `pennant mcp key \(shortID(server.id.rawValue)) <secret>`.")
        }
        let url = try await session.beginMCPAuth(server.id)
        out("Open this link to sign in to \(server.config.name):")
        out(url.absoluteString)
        openInBrowser(url)
        out("Waiting for the browser (up to 5 minutes)…")
        let deadline = Date().addingTimeInterval(300)
        var last: MCPServerStatus?
        while Date() < deadline {
            try await session.loadMCPServers()
            guard let s = findMCPServer(session, server.id.rawValue) else { break }
            last = s
            switch s.authState {
            case .signedIn:
                out("Signed in to \(s.config.name)\(s.authDetail.map { " (\($0))" } ?? "").")
                // Give the reconnect a moment so the tool count is real.
                let connectDeadline = Date().addingTimeInterval(20)
                while Date() < connectDeadline {
                    try await session.loadMCPServers()
                    if let c = findMCPServer(session, server.id.rawValue), c.state == .connected || c.state == .failed { last = c; break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                if let c = last { out(describe(c)) }
                await session.disconnect()
                return
            case .failed, .expired:
                await session.disconnect()
                fail("Sign-in to \(s.config.name) failed: \(s.authDetail ?? "unknown error")")
            default:
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        await session.disconnect()
        fail("Timed out waiting for the sign-in to \(server.config.name) (\(last?.authDetail ?? "no reply")). Run `pennant mcp connect` again.")

    case "key":
        let server = try await requireMCPServer(session, args.first)
        guard var secret = args.count > 1 ? args[1] : nil else { await session.disconnect(); fail("Usage: pennant mcp key <id|name> <secret|->") }
        if secret == "-" {
            secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !secret.isEmpty else { await session.disconnect(); fail("The secret is empty.") }
        let list = try await session.setMCPCredential(server.id, secret: secret)
        if let s = list.first(where: { $0.id == server.id }) { out(describe(s)) }

    case "signout":
        let server = try await requireMCPServer(session, args.first)
        let list = try await session.signOutMCP(server.id)
        if let s = list.first(where: { $0.id == server.id }) { out(describe(s)) }

    case "remove":
        let server = try await requireMCPServer(session, args.first)
        let r = try await session.send(.removeMCPServer(server.id), timeout: 60)
        guard case .mcpServers = r else { await session.disconnect(); fail(replyError(r)) }
        out("Removed \(server.config.name).")

    default:
        await session.disconnect()
        fail("Unknown mcp subcommand '\(sub)'. Try: list, add, connect, key, signout, remove, catalog")
    }
    await session.disconnect()
}
