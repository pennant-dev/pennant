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
    var baseURL = options.args.first
    if baseURL == nil, case .config(let cfg, _) = try await session.send(.getConfig) { baseURL = cfg.inference.baseURL }
    guard let url = baseURL else { await session.disconnect(); fail("Usage: pennant models [baseURL] [apiKey]") }
    let reply = try await session.send(.listModels(baseURL: url, apiKey: options.args.count > 1 ? options.args[1] : nil), timeout: 20)
    guard case .models(let models) = reply else { await session.disconnect(); fail("Unexpected reply") }
    out("\(models.count) model(s) at \(url)")
    for m in models { out("  \(m.id)\(m.ownedBy.map { "  (\($0))" } ?? "")") }
    await session.disconnect()
}
