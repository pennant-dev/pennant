import PennantClientKit
import PennantCore
import Foundation

// The host itself: status, the agent, coding, the health review, signing in, macOS permissions, moving to another
// Mac, and diagnostics.

@MainActor
func exportCommand(_ options: CLIOptions) async throws {
    // pennant export [--to <folder>] [--passphrase <p>]
    let session = try await connect(options)
    var folder: String?, passphrase: String?
    var i = 0
    while i < options.args.count {
        if options.args[i] == "--to", i + 1 < options.args.count { folder = options.args[i + 1]; i += 2; continue }
        if options.args[i] == "--passphrase", i + 1 < options.args.count { passphrase = options.args[i + 1]; i += 2; continue }
        i += 1
    }
    let r = try await session.exportData(folder: folder, passphrase: passphrase)
    out("Exported to \(r.path) (\(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)), \(r.secrets) sealed secret(s))")
    await session.disconnect()
}

@MainActor
func importCommand(_ options: CLIOptions) async throws {
    guard let folder = options.args.first else { fail("Usage: pennant import <export folder> [--passphrase <p>]") }
    let session = try await connect(options)
    let passphrase = options.args.firstIndex(of: "--passphrase").flatMap { $0 + 1 < options.args.count ? options.args[$0 + 1] : nil }
    try await session.importData(folder: folder, passphrase: passphrase)
    out("Staged; the host restarts and swaps it in. The previous data is kept in the Pennant folder as before-import-….")
    await session.disconnect()
}

@MainActor
func chromeSignInsCommand(_ options: CLIOptions) async throws {
    // pennant chrome-signins                         → list Chrome profiles
    // pennant chrome-signins <site>… [--profile P]   → import those sites' sign-ins into Pennant's browser
    let session = try await connect(options)
    var sites: [String] = []
    var profile = "Default"
    var i = 0
    while i < options.args.count {
        if options.args[i] == "--profile", i + 1 < options.args.count { profile = options.args[i + 1]; i += 2; continue }
        sites.append(options.args[i]); i += 1
    }
    if sites.isEmpty {
        for p in try await session.chromeProfiles() { out("\(p.id)  \(p.name)\(p.account.map { "  (\($0))" } ?? "")") }
    } else {
        let result = try await session.importChromeSignIns(profile: profile, sites: sites)
        out("Imported \(result.cookies) cookie(s) from Chrome \(result.profile): " + result.perSite.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
    }
    await session.disconnect()
}

@MainActor
func chromeCommand(_ options: CLIOptions) async throws {
    // pennant chrome [status]                 → whether Pennant's extension is connected, and the sites it may use
    // pennant chrome setup [--browser <id>]   → Pennant adds its extension to Chrome on the host's Mac
    // pennant chrome forget <site>            → Pennant asks again before it uses that site
    let session = try await connect(options)
    func show(_ s: ChromeStatus) {
        out(s.connected ? "Connected · \(s.browser ?? "Chrome")" : "Not connected")
        if let folder = s.folder { out("Extension folder: \(folder)") }
        out(s.sites.isEmpty ? "No sites allowed yet." : "Sites: " + s.sites.joined(separator: ", "))
    }
    switch options.args.first ?? "status" {
    case "setup":
        let browser = options.args.firstIndex(of: "--browser").flatMap { $0 + 1 < options.args.count ? options.args[$0 + 1] : nil }
        out("Adding Pennant to Chrome; Chrome comes to the front for a moment to pick the folder…")
        show(try await session.chromeSetup(browser: browser))
    case "forget":
        guard options.args.count >= 2 else { fail("Usage: pennant chrome forget <site>") }
        let sites = try await session.chromeForgetSite(options.args[1])
        out(sites.isEmpty ? "No sites allowed now." : "Sites: " + sites.joined(separator: ", "))
    default:
        show(try await session.chromeStatus())
    }
    await session.disconnect()
}

@MainActor
func pushCommand(_ options: CLIOptions) async throws {
    // pennant push status | key <AuthKey_XXXXXXXXXX.p8> [--team <Team ID>] | test
    let session = try await connect(options)
    func show(_ s: PushStatus) {
        out("Key: \(s.keyConfigured ? "added (\(s.keyID ?? ""))" : "none")  Team: \(s.teamID ?? "unknown")")
        for d in s.devices { out("  \(d.name)  \(d.environment)  since \(ISO8601.format(d.registeredAt))") }
        if s.devices.isEmpty { out("  No iPhone registered yet.") }
        if let e = s.lastError { out("Last error: \(e)") }
    }
    switch options.args.first ?? "status" {
    case "key":
        guard options.args.count >= 2 else { fail("Usage: pennant push key <AuthKey_XXXXXXXXXX.p8> [--team <Team ID>]") }
        let url = URL(fileURLWithPath: (options.args[1] as NSString).expandingTildeInPath)
        let p8 = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        let keyID = name.hasPrefix("AuthKey_") ? String(name.dropFirst(8)) : name
        let team = options.args.firstIndex(of: "--team").flatMap { $0 + 1 < options.args.count ? options.args[$0 + 1] : nil }
        show(try await session.setPushKey(keyID: keyID, teamID: team, p8: p8))
    case "test":
        show(try await session.sendTestPush())
    default:
        show(try await session.pushStatus())
    }
    await session.disconnect()
}

@MainActor
func statusCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    if let h = session.state.host {
        out("Host: \(h.hostName)  v\(h.version)  mode=\(h.mode.rawValue)  up since \(ISO8601.format(h.startedAt))")
        out("Inference: \(h.inferenceModel) @ \(h.inferenceEndpoint) (\(h.inferenceReachable ? "reachable" : "unreachable"))")
        out("Clients: \(h.connectedClients)  Active tasks: \(h.activeTaskCount)")
        if let addresses = h.addresses, !addresses.isEmpty { out("Addresses: \(addresses.joined(separator: ", "))") }
    }
    let d = session.state.desktop
    out("Desktop: owner=\(d.owner) paused=\(d.pausedByHuman) accessibility=\(d.permissions.accessibility) screenRecording=\(d.permissions.screenRecording) inputMonitoring=\(d.permissions.inputMonitoring)")
    out("Permissions granted to '\(d.permissions.grantee)'; missing: \(d.permissions.missing.isEmpty ? "none" : d.permissions.missing.joined(separator: ", "))")
    out("")
    if let agent = session.state.leadAgent { out(describe(agent)) }
    let active = session.state.tasks.filter { !$0.state.isTerminal }
    if !active.isEmpty {
        out("")
        out("Active tasks:")
        for t in active { out("  " + describe(t)) }
    }
    await session.disconnect()
}

@MainActor
func healthCommand(_ options: CLIOptions) async throws {
    // pennant health enable: the daily health review, on the agent you talk to, with the review tools granted.
    guard options.args.first == "enable" else { fail("Usage: pennant health enable") }
    let session = try await connect(options)
    guard var lead = session.state.leadAgent else { await session.disconnect(); fail("There's no agent yet to run the review.") }
    lead.grantedTools = Array(Set(lead.grantedTools ?? []).union(HealthReview.grantedTools)).sorted()
    let r = try await session.send(.updateAgent(lead), timeout: 60)
    if case .error = r { await session.disconnect(); fail(replyError(r)) }
    if !session.state.schedules.contains(where: { $0.agentID == lead.id && $0.name == HealthReview.jobName }) {
        let job = ScheduledJob(name: HealthReview.jobName, agentID: lead.id, prompt: HealthReview.jobPrompt, schedule: HealthReview.jobSchedule)
        let s = try await session.send(.upsertSchedule(job), timeout: 60)
        if case .error = s { await session.disconnect(); fail(replyError(s)) }
    }
    await session.disconnect()
    out("\(lead.name) reviews its own health \(HealthReview.jobSchedule) and posts \"\(lead.name) health\". Fixes come as cards; nothing changes until you approve.")
    return
}

@MainActor
func codingCommand(_ options: CLIOptions) async throws {
    // pennant coding [folder <dir> [--name N] | folders | folder remove <name> | engine claude-code|pennant |
    //                 model <profile|default> | mode <mode> | github --app-id N --installation N --vault ENTRY --slug SLUG | github --off]
    let session = try await connect(options)
    var c = try await session.getConfig().config
    var coding = c.coding ?? HostConfig.Coding()
    var rest = Array(options.args.dropFirst())
    func take(_ flag: String) -> String? {
        guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
        let v = rest[i + 1]; rest.removeSubrange(i...(i + 1)); return v
    }
    func misuse(_ text: String) async -> Never { await session.disconnect(); fail("Usage: pennant coding \(text)") }
    switch options.args.first {
    case nil:
        await session.disconnect()
        guard let current = c.coding else { out("Coding isn't set up. Start with: pennant coding folder <dir>"); return }
        describeCoding(current, config: c).forEach(out)
        return
    case "folders":
        await session.disconnect()
        projectLines(c.coding?.projects ?? []).forEach(out)
        return
    case "folder" where rest.first == "remove" && rest.count > 1:
        let name = rest.dropFirst().joined(separator: " ")
        guard let project = coding.project(named: name) else {
            await session.disconnect()
            fail("There's no coding project called \(name). Projects: \(coding.projects.map(\.name).joined(separator: ", ")).")
        }
        coding.projects.removeAll { $0.path == project.path }
    case "folder":
        let name = take("--name")
        guard let dir = rest.first else { await misuse("folder <dir> [--name <name>] | folder remove <name>") }
        coding.addProject(path: ((dir as NSString).expandingTildeInPath as NSString).standardizingPath, name: name, asDefault: true)
    case "engine":
        switch rest.first?.lowercased() {
        case "claude-code", "claudecode", "claude": coding.engine = .claudeCode
        case "pennant": coding.engine = .pennant
        default: await misuse("engine claude-code|pennant")
        }
    case "model":
        let wanted = rest.joined(separator: " ")
        if wanted.isEmpty { await misuse("model <profile name or id>|default") }
        if wanted.lowercased() == "default" {
            coding.modelProfileID = nil
        } else if let profile = c.profile(matching: wanted) {
            coding.modelProfileID = profile.id
        } else {
            await session.disconnect()
            fail("There's no model called \(wanted). Models (Settings › Models): \(c.inferenceProfiles.map(\.name).joined(separator: ", ")).")
        }
    case "mode":
        guard let name = rest.first, let mode = CodingMode(rawValue: name) else { await misuse("mode \(CodingMode.allCases.map(\.rawValue).joined(separator: "|"))") }
        coding.mode = mode == .acceptEdits ? nil : mode
    case "github":
        if rest.contains("--off") {
            coding.gitHubApp = nil
        } else {
            guard let app = take("--app-id").flatMap(Int.init), let inst = take("--installation").flatMap(Int.init), let vault = take("--vault"), let slug = take("--slug") else {
                await misuse("github --app-id <id> --installation <id> --vault <entry> --slug <app-slug> | --off")
            }
            coding.gitHubApp = GitHubAppIdentity(appID: app, installationID: inst, vaultEntry: vault, slug: slug)
        }
    default:
        await misuse("[folder <dir> [--name N] | folders | folder remove <name> | engine claude-code|pennant | model <profile>|default | mode <mode> | github … | github --off]")
    }
    c.coding = coding
    c = try await session.updateConfig(c).config
    await session.disconnect()
    describeCoding(c.coding ?? coding, config: c).forEach(out)
}

/// How coding is set up, a line each: engine and model, the projects, how runs ask, and who they are on GitHub.
private func describeCoding(_ coding: HostConfig.Coding, config: HostConfig) -> [String] {
    var lines: [String] = []
    switch coding.engine {
    case .claudeCode:
        lines.append("Engine: Claude Code (the claude program on the host; each thread picks its model)")
    case .pennant:
        let model = config.profile(coding.modelProfileID)?.name ?? "the default model (\(config.defaultProfile?.name ?? config.inference.model))"
        lines.append("Engine: Pennant, on \(model)")
    }
    lines += projectLines(coding.projects)
    lines.append("Asks: \((coding.mode ?? .acceptEdits).title)")
    lines.append("On GitHub: \(coding.gitHubApp.map { "\($0.botLogin), its own App" } ?? "no identity: it doesn't push or open pull requests")")
    return lines
}

private func projectLines(_ projects: [CodingProject]) -> [String] {
    guard !projects.isEmpty else { return ["Projects: none yet. Add one with: pennant coding folder <dir>"] }
    return ["Projects:"] + projects.enumerated().map { i, p in
        "  \(p.name)  \((p.path as NSString).abbreviatingWithTildeInPath)\(i == 0 ? "  (default)" : "")"
    }
}

@MainActor
func agentCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    guard var agent = session.state.leadAgent else { await session.disconnect(); fail("There's no agent yet.") }
    // pennant agent edit [--name <name>] [--role <text>] [--instructions-stdin]
    if options.args.first == "edit" {
        var rest = Array(options.args.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
            let v = rest[i + 1]; rest.removeSubrange(i...(i + 1)); return v
        }
        let name = take("--name"), role = take("--role")
        let fromStdin = rest.contains("--instructions-stdin")
        guard name != nil || role != nil || fromStdin else {
            await session.disconnect()
            fail("Usage: pennant agent edit [--name <name>] [--role <text>] [--instructions-stdin]")
        }
        if let name { agent.name = name }
        if let role { agent.role = role }
        if fromStdin { agent.instructions = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let r = try await session.send(.updateAgent(agent), timeout: 30)
        await session.disconnect()
        if case .error(_, let message) = r { fail(message) }
        out("Updated \(agent.name).")
        return
    }
    out(describe(agent))
    await session.disconnect()
}

@MainActor
func loginCommand(_ options: CLIOptions) async throws {
    // pennant login <email>: signs in to a host on another Mac with a password (asked for, not echoed).
    guard let email = options.args.first else { fail("Usage: pennant --host <mac> login <email>") }
    guard let entered = getpass("Password for \(email): ").map({ String(cString: $0) }), !entered.isEmpty else { fail("No password entered") }
    let (transport, inbound) = try await openRaw(options)
    let clientID = ClientCredentials.deviceClientID()
    let command = ClientCommand(body: .signInWithPassword(email: email, password: entered, clientID: clientID, clientName: "pennant CLI on \(Host.current().localizedName ?? "Mac")", platform: "macos-cli"))
    try await transport.send(.command(command))
    for await item in inbound {
        guard case .message(.reply(let reply)) = item, reply.commandID == command.id else {
            if case .closed(let reason) = item { fail("connection closed: \(reason)") }
            continue
        }
        switch reply.result {
        case .signedIn(let signedIn):
            try ClientCredentials.save(ClientCredentials(clientID: clientID, token: signedIn.token, hostName: signedIn.hostName), for: options.endpoint)
            out("Signed in to \(signedIn.hostName) as \(signedIn.person.name). Token stored for \(options.endpoint.id).")
            await transport.close()
            return
        case .error(let c, let m):
            fail("\(c): \(m)")
        default:
            fail("Unexpected reply")
        }
    }
}

@MainActor
func githubCommand(_ options: CLIOptions) async throws {
    // pennant github client-id <id> [--secret-stdin]: the GitHub app people link for PR reviews from chats.
    guard options.args.count >= 2, options.args[0] == "client-id" else { fail("Usage: pennant github client-id <client id> [--secret-stdin]") }
    var secret: String?
    if options.args.contains("--secret-stdin") {
        secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let session = try await connect(options)
    let r = try await session.send(.setReviewsGitHubApp(clientID: options.args[1], secret: secret), timeout: 30)
    await session.disconnect()
    guard case .ok = r else { fail(replyError(r)) }
    out("GitHub reviews: set up\(secret == nil ? "" : " (with its client secret)"). Link people by asking Pennant to \"link <name> for reviews\".")
}

@MainActor
func screenshotCommand(_ options: CLIOptions) async throws {
    guard let path = options.args.first else { fail("Usage: pennant screenshot <out.jpg>") }
    let session = try await connect(options)
    let data = try await session.screenshot()
    try data.write(to: URL(fileURLWithPath: path))
    out("Saved \(data.count) bytes to \(path)")
    await session.disconnect()
}

@MainActor
func permissionsCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    var status: DesktopStatus = session.state.desktop
    if let action = options.args.first {
        let target = options.args.count > 1 ? options.args[1] : ""
        switch action {
        case "request": status = try await session.requestPermissions(target.isEmpty ? [] : [target])
        case "reset":
            guard !target.isEmpty else { await session.disconnect(); fail("Usage: pennant permissions reset <target>") }
            status = try await session.resetPermission(target)
        case "recheck": status = try await session.recheckPermissions()
        default: await session.disconnect(); fail("Usage: pennant permissions [request|reset|recheck [target]]")
        }
    } else {
        status = try await session.recheckPermissions()
    }
    let p = status.permissions
    out("Grantee: \(p.grantee)")
    out("Accessibility: \(p.accessibility ? "granted" : "missing")")
    out("Screen Recording: \(p.screenRecording ? "granted" : "missing")")
    out("Input Monitoring: \(p.inputMonitoring ? "granted" : "missing")")
    for (target, state) in p.automationTargets.sorted(by: { $0.key < $1.key }) { out("Automation \(target): \(state.rawValue)") }
    await session.disconnect()
}

@MainActor
func diagCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    let report = try await session.diagnostics()
    out(String(decoding: try JSONCodec.prettyEncoder.encode(report), as: UTF8.self))
    await session.disconnect()
}
