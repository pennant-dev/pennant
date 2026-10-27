import PennantClientKit
import PennantCore
import Foundation

// Models: what an endpoint serves, and the ChatGPT account used for inference.

func describe(_ a: ChatGPTAccount) -> String {
    guard a.signedIn else { return "ChatGPT: not signed in" + (a.detail.map { " (\($0))" } ?? "") }
    var parts: [String] = ["ChatGPT: signed in"]
    if let email = a.email { parts.append("as \(email)") }
    if let plan = a.plan { parts.append("(\(plan))") }
    if let id = a.accountID { parts.append("account \(shortID(id))…") }
    if let source = a.source { parts.append("via \(source == "codex-cli" ? "the Codex CLI login" : "Pennant sign-in")") }
    if let exp = a.expiresAt { parts.append("· session expires \(ISO8601.format(exp))") }
    if let detail = a.detail { parts.append("· \(detail)") }
    return parts.joined(separator: " ")
}

/// `pennant chatgpt login|import|status|logout|models`.
@MainActor
func runChatGPT(_ sub: String, options: CLIOptions) async throws {
    let session = try await connect(options)
    switch sub {
    case "login":
        let url = try await session.beginChatGPTSignIn()
        out("Open this link to sign in with your ChatGPT account:")
        out(url.absoluteString)
        openInBrowser(url)
        out("Waiting for the browser (up to 5 minutes)…")
        let deadline = Date().addingTimeInterval(300)
        var last: ChatGPTAccount?
        while Date() < deadline {
            let account = try await session.chatGPTAccount()
            last = account
            let detail = account.detail ?? ""
            if detail.hasPrefix("Waiting") || detail.hasPrefix("Exchanging") {
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            if detail.hasPrefix("Sign-in failed") {
                await session.disconnect()
                fail(detail)
            }
            if account.signedIn {
                out(describe(account))
                await session.disconnect()
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        await session.disconnect()
        fail("Timed out waiting for the sign-in (\(last?.detail ?? "no reply")). Run `pennant chatgpt login` again.")

    case "import":
        let account = try await session.importCodexLogin()
        out(describe(account))
        out("Note: Pennant and the Codex CLI now share one session; whichever refreshes first invalidates the other's copy. `pennant chatgpt login` gives Pennant its own.")

    case "status":
        let account = try await session.chatGPTAccount()
        out(describe(account))
        if let h = session.state.host {
            out("Inference provider: \(h.inferenceProvider)  model: \(h.inferenceModel)  (\(h.inferenceReachable ? "reachable" : "unreachable"))")
        }

    case "logout", "signout":
        let account = try await session.signOutChatGPT()
        out(describe(account))

    case "models":
        var configured: String?
        if case .config(let cfg, _) = try await session.send(.getConfig), cfg.inference.provider == HostConfig.Inference.chatGPTProvider { configured = cfg.inference.model }
        let (models, note) = try await session.chatGPTModels()
        if let note { out(note) }
        for m in models {
            out("\(m.id == configured ? "*" : " ") \(m.id)  \(m.title)  context \(m.contextWindowTokens / 1000)k\(m.supportsVision ? "" : "  (no vision)")")
        }
        out("Any other model id can be typed in Settings › Models (Other model…); it is sent to the backend as is.")

    default:
        await session.disconnect()
        fail("Unknown chatgpt subcommand '\(sub)'. Try: login, import, status, logout, models")
    }
    await session.disconnect()
}

@MainActor
func modelsCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    if let which = options.args.first, which == "default" || which == "worker" {
        try await setModel(which, to: options.args.dropFirst().joined(separator: " "), session: session)
        return
    }
    if options.args.first == "chat" || options.args.first == "threads" {
        try await setChatModel(to: options.args.dropFirst().joined(separator: " "), threads: options.args.first == "threads", session: session)
        return
    }
    if options.args.first == "fallbacks" {
        try await setFallbacks(to: options.args.dropFirst().joined(separator: " "), session: session)
        return
    }
    var baseURL = options.args.first
    if baseURL == nil, case .config(let cfg, _) = try await session.send(.getConfig) { baseURL = cfg.inference.baseURL }
    guard let url = baseURL else { await session.disconnect(); fail("Usage: pennant models [baseURL] [apiKey]") }
    let reply = try await session.send(.listModels(baseURL: url, apiKey: options.args.count > 1 ? options.args[1] : nil), timeout: 20)
    guard case .models(let models) = reply else { await session.disconnect(); fail("Unexpected reply") }
    out("\(models.count) model(s) at \(url)")
    for m in models { out("  \(m.id)\(m.ownedBy.map { "  (\($0))" } ?? "")") }
    await session.disconnect()
}

/// `pennant models default <profile>` and `pennant models worker <profile>|default`: what Settings › Models sets.
@MainActor
private func setModel(_ which: String, to wanted: String, session: HostSession) async throws {
    guard case .config(var c, _) = try await session.send(.getConfig) else { await session.disconnect(); fail("Unexpected reply") }
    if wanted.isEmpty { await session.disconnect(); fail("Usage: pennant models \(which) <profile name or id>\(which == "worker" ? "|default" : "")") }
    if which == "worker", wanted.lowercased() == "default" {
        c.workerProfileID = nil
    } else if let profile = c.profile(matching: wanted) {
        if which == "worker" { c.workerProfileID = profile.id } else { c.defaultProfileID = profile.id }
    } else {
        await session.disconnect()
        fail("There's no model called \(wanted). Models (Settings › Models): \(c.inferenceProfiles.map(\.name).joined(separator: ", ")).")
    }
    c = try await session.updateConfig(c).config
    await session.disconnect()
    out("Default model: \(c.profile(c.defaultProfileID)?.name ?? "none")")
    out("Worker model: \(c.profile(c.workerProfileID)?.name ?? "the default")")
}

/// `pennant models chat <profile>|same`: the model Pennant's chat replies run on (its threads keep the agent's own).
/// `pennant models threads <profile>|default`: the agent's own model, which its threads and jobs run on.
@MainActor
private func setChatModel(to wanted: String, threads: Bool, session: HostSession) async throws {
    guard case .config(let c, _) = try await session.send(.getConfig) else { await session.disconnect(); fail("Unexpected reply") }
    guard var lead = session.state.leadAgent else { await session.disconnect(); fail("There's no agent yet.") }
    if wanted.isEmpty { await session.disconnect(); fail(threads ? "Usage: pennant models threads <profile name or id>|default" : "Usage: pennant models chat <profile name or id>|same") }
    if wanted.lowercased() == (threads ? "default" : "same") {
        if threads { lead.modelProfileID = nil } else { lead.chatModelProfileID = nil }
    } else if let profile = c.profile(matching: wanted) {
        if threads { lead.modelProfileID = profile.id } else { lead.chatModelProfileID = profile.id }
    } else {
        await session.disconnect()
        fail("There's no model called \(wanted). Models (Settings › Models): \(c.inferenceProfiles.map(\.name).joined(separator: ", ")).")
    }
    let r = try await session.send(.updateAgent(lead), timeout: 30)
    if case .error = r { await session.disconnect(); fail(replyError(r)) }
    await session.disconnect()
    out("Chat model: \(c.profile(lead.chatModelProfileID)?.name ?? "the same as \(lead.name)'s threads")")
    out("\(lead.name)'s threads: \(c.profile(lead.modelProfileID)?.name ?? "the default model")")
}

/// `pennant models fallbacks <profile>[, <profile>…]|none`: what a task moves to when its model fails, in order.
@MainActor
private func setFallbacks(to wanted: String, session: HostSession) async throws {
    guard case .config(var c, _) = try await session.send(.getConfig) else { await session.disconnect(); fail("Unexpected reply") }
    if wanted.isEmpty { await session.disconnect(); fail("Usage: pennant models fallbacks <profile>[, <profile>…]|none") }
    if wanted.lowercased() == "none" {
        c.fallbackProfileIDs = []
    } else {
        var ids: [String] = []
        for name in wanted.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            guard let profile = c.profile(matching: name) else {
                await session.disconnect()
                fail("There's no model called \(name). Models (Settings › Models): \(c.inferenceProfiles.map(\.name).joined(separator: ", ")).")
            }
            if !ids.contains(profile.id) { ids.append(profile.id) }
        }
        c.fallbackProfileIDs = ids
    }
    c = try await session.updateConfig(c).config
    await session.disconnect()
    out("Fallbacks: \(c.fallbackProfileIDs.isEmpty ? "none" : c.fallbackProfileIDs.compactMap { c.profile($0)?.name }.joined(separator: ", "))")
}
