import PennantClientKit
import PennantCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Drives the connect and sign-in flows for MCP servers: add the server, store a key or open the browser,
/// then refresh. Progress and errors are kept per catalog entry (while a card is being connected) and per
/// server (for the server cards), so each card reports its own outcome.
@MainActor
@Observable
final class MCPConnectFlow {
    enum Sheet: Identifiable {
        /// Ask for a key before adding a catalog entry (one whose primary or alternate sign-in is a key).
        case apiKey(MCPCatalogEntry)
        /// Fill the placeholders of a local (stdio) entry.
        case local(MCPCatalogEntry)
        /// Set or replace the key of an existing server.
        case serverKey(MCPServerStatus)
        /// The browser step cannot finish on this device; hand the URL over.
        case handoff(URL, name: String)

        var id: String {
            switch self {
            case .apiKey(let e): return "key:\(e.id)"
            case .local(let e): return "local:\(e.id)"
            case .serverKey(let s): return "server-key:\(s.id.rawValue)"
            case .handoff(let url, _): return "handoff:\(url.absoluteString)"
            }
        }
    }

    var sheet: Sheet?
    /// The redirect URL the host uses for hand-registered clients (`MCPManager.fixedRedirectURI`): what the user
    /// types into the provider's developer console.
    static let fixedRedirectURI = "http://127.0.0.1:47831/callback"
    /// Catalog id → what is happening ("Adding…", "Opening the browser…").
    var busy: [String: String] = [:]
    /// Catalog id or server id → the last failure, shown under the card until the next attempt.
    var errors: [String: String] = [:]

    // MARK: Catalog entries

    /// Starts the flow that fits the entry: a sheet for keys and local parameters, otherwise add straight away.
    /// An entry's alternate route arrives as `entry.alternate` (its `auth` is the alternate), and an OAuth entry
    /// at a provider without dynamic registration arrives with the hand-registered client already on `auth`
    /// (the marketplace collects it in `MCPRegisteredClientSheet` first).
    func connect(_ entry: MCPCatalogEntry, session: HostSession) {
        errors[entry.id] = nil
        if entry.isLocal {
            if entry.parameters.isEmpty { connectLocal(entry, values: [:], session: session) } else { sheet = .local(entry) }
            return
        }
        switch entry.auth {
        case .none: addRemote(entry, session: session)
        case .apiKey: sheet = .apiKey(entry)
        case .oauth:
            if entry.needsClientBeforeSignIn {
                errors[entry.id] = "\(entry.publisher) has no automatic client registration: an app registered with the redirect URL \(Self.fixedRedirectURI) and its client id are needed before signing in."
                return
            }
            connectOAuth(entry, session: session)
        }
    }

    func connectLocal(_ entry: MCPCatalogEntry, values: [String: String], session: HostSession) {
        guard let config = entry.makeConfig(values: values) else { errors[entry.id] = "This entry has no usable command."; return }
        run(entry.id, step: "Adding…", session: session) { _ = try await session.addMCPServer(config) }
    }

    /// Adds the entry with the key stored. The key sign-in may be the entry's alternate (a token beside OAuth); the
    /// config is built from whichever side is the key.
    func connectAPIKey(_ entry: MCPCatalogEntry, secret: String, session: HostSession) {
        let keyed: MCPCatalogEntry
        if case .apiKey = entry.auth {
            keyed = entry
        } else if let alternate = entry.alternate, case .apiKey = alternate.auth {
            keyed = alternate
        } else {
            errors[entry.id] = "\(entry.name) does not sign in with a key."
            return
        }
        guard let config = keyed.makeConfig() else { errors[entry.id] = "This entry has no usable address."; return }
        run(entry.id, step: "Adding…", session: session) {
            let server = try await self.added(config, session: session)
            self.busy[entry.id] = "Storing the key…"
            _ = try await session.setMCPCredential(server.id, secret: secret)
        }
    }

    func connectOAuth(_ entry: MCPCatalogEntry, session: HostSession) {
        guard let config = entry.makeConfig() else { errors[entry.id] = "This entry has no usable address."; return }
        run(entry.id, step: "Adding…", session: session) {
            let server = try await self.added(config, session: session)
            self.busy[entry.id] = "Opening the browser…"
            let url = try await session.beginMCPAuth(server.id)
            self.open(url, name: entry.name)
        }
    }

    private func addRemote(_ entry: MCPCatalogEntry, session: HostSession) {
        guard let config = entry.makeConfig() else { errors[entry.id] = "This entry has no usable address."; return }
        run(entry.id, step: "Adding…", session: session) { _ = try await session.addMCPServer(config) }
    }

    /// Adds the server and returns its status from the host's reply.
    private func added(_ config: MCPServerConfig, session: HostSession) async throws -> MCPServerStatus {
        let list = try await session.addMCPServer(config)
        guard let server = list.first(where: { $0.id == config.id }) ?? list.first(where: { $0.config.catalogID == config.catalogID }) else {
            throw MCPConnectError.notAdded
        }
        return server
    }

    // MARK: Existing servers

    func signIn(_ server: MCPServerStatus, session: HostSession) {
        run(server.id.rawValue, step: "Opening the browser…", session: session, refresh: false) {
            let url = try await session.beginMCPAuth(server.id)
            self.open(url, name: server.config.name)
        }
    }

    func setKey(_ server: MCPServerStatus, secret: String, session: HostSession) {
        run(server.id.rawValue, step: "Storing the key…", session: session) { _ = try await session.setMCPCredential(server.id, secret: secret) }
    }

    func signOut(_ server: MCPServerStatus, session: HostSession) {
        run(server.id.rawValue, step: "Signing out…", session: session) { _ = try await session.signOutMCP(server.id) }
    }

    func cancelAuth(_ server: MCPServerStatus, session: HostSession) {
        run(server.id.rawValue, step: "Cancelling…", session: session) { try await session.cancelMCPAuth(server.id) }
    }

    func reconnect(_ server: MCPServerStatus, session: HostSession) {
        run(server.id.rawValue, step: "Reconnecting…", session: session, refresh: false) { _ = try await session.send(.reconnectMCPServer(server.id)) }
    }

    func remove(_ server: MCPServerStatus, session: HostSession) {
        run(server.id.rawValue, step: "Removing…", session: session) { _ = try await session.send(.removeMCPServer(server.id)) }
    }

    /// Adds a hand-written server, storing its key right after when one was typed.
    func addCustom(_ config: MCPServerConfig, secret: String?, session: HostSession) {
        run(config.id.rawValue, step: "Adding…", session: session) {
            let server = try await self.added(config, session: session)
            if let secret, !secret.isEmpty { _ = try await session.setMCPCredential(server.id, secret: secret) }
        }
    }

    // MARK: Plumbing


    /// The step the flow is on for a server, if any.
    func step(for server: MCPServerStatus) -> String? { busy[server.id.rawValue] }

    private func run(_ key: String, step: String, session: HostSession, refresh: Bool = true, _ work: @escaping @MainActor () async throws -> Void) {
        errors[key] = nil
        busy[key] = step
        Task { @MainActor in
            defer { busy[key] = nil }
            do {
                try await work()
                if refresh { try await session.loadMCPServers() }
            } catch {
                errors[key] = Self.describe(error)
            }
        }
    }

    /// Opens the sign-in page. Only the Mac that runs the host can finish the flow (the redirect lands on its
    /// loopback), so other devices get the URL to carry over instead.
    private func open(_ url: URL, name: String) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        sheet = .handoff(url, name: name)
        #endif
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

enum MCPConnectError: LocalizedError {
    case notAdded
    var errorDescription: String? {
        switch self {
        case .notAdded: return "The host did not report the new server."
        }
    }
}

// MARK: - Sheets

/// Asks for an API key: what the service is, a secure field, and where to get a key.
struct MCPAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var summary: String?
    var keyHelpURL: String?
    var placeholder: String = "Paste the key"
    /// The service's mark for the header, when the sheet is for a catalog entry.
    var mark: BrandIcon?
    var onSubmit: (String) -> Void
    @State private var secret = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title) { if let mark { mark } }
            InspectorHairline(inset: 0)
            VStack(alignment: .leading, spacing: 14) {
                if let summary { Text(summary).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary) }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("API key")
                    SecureField(placeholder, text: $secret)
                        .textFieldStyle(.plain)
                        .pennantField()
                }
                if let keyHelpURL, let url = URL(string: keyHelpURL) {
                    Link(destination: url) { Label("Where do I get a key?", systemImage: "questionmark.circle") }
                        .font(.zoomed(.callout))
                        .foregroundStyle(InspectorTint.info)
                }
                Text("The key is stored in the host's Keychain and sent only to this server.")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            }
            .padding(20)
            Spacer(minLength: 0)
            InspectorHairline(inset: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantSecondary).keyboardShortcut(.cancelAction)
                Button("Connect") { onSubmit(secret); dismiss() }
                    .buttonStyle(.pennantPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
        .frame(minWidth: 440, minHeight: 280)
    }
}

/// Collects the client id (and secret, and any values such as a tenant) of an app the user registered with a
/// provider that has no dynamic client registration (`needsRegisteredClient`): the provider's setup steps, the
/// redirect URL to give it, and the fields. "Sign in" hands them to the OAuth flow, which opens the browser.
/// The client id and values (never the secret) are remembered per publisher, so a second Microsoft server starts filled in.
struct MCPRegisteredClientSheet: View {
    @Environment(\.dismiss) private var dismiss
    var entry: MCPCatalogEntry
    var onSubmit: (_ clientID: String, _ clientSecret: String, _ values: [String: String]) -> Void
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var values: [String: String] = [:]
    @State private var copied = false

    private var redirectURI: String { entry.oauthServer?.redirectURIToRegister ?? MCPConnectFlow.fixedRedirectURI }
    private var fields: [MCPCatalogEntry.Parameter] { entry.parameters.filter { $0.kind != "secret" } }
    /// Entra public clients must present no secret at all; everyone else may have one (Reddit's script apps do).
    private var showsSecret: Bool {
        entry.needsClientSecret || entry.oauthServer == nil || entry.oauthServer?.basicAuthWithEmptySecret == true
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Sign in to \(entry.name)") { BrandIcon(entry: entry, size: 28) }
            InspectorHairline(inset: 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.summary).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.setupSteps.isEmpty {
                        Text("\(entry.publisher) does not register clients automatically. Create an app in its developer console, give it the redirect URL below, and paste the app's client id and secret here.")
                            .font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(entry.setupSteps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(index + 1)")
                                        .font(.zoomed(.caption).weight(.semibold).monospacedDigit())
                                        .foregroundStyle(PennantTheme.inkSecondary)
                                        .frame(width: 18, height: 18)
                                        .background(PennantTheme.cardBackground, in: Circle())
                                    Text(step).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if let docs = entry.docsURL, let url = URL(string: docs) {
                        Link(destination: url) { Label("Open \(entry.publisher)'s documentation", systemImage: "arrow.up.right.square") }
                            .font(.zoomed(.callout))
                            .foregroundStyle(InspectorTint.info)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Redirect URL to register")
                        HStack(spacing: 8) {
                            Text(redirectURI)
                                .font(.zoomed(.callout).monospaced()).foregroundStyle(PennantTheme.ink)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button { copy() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                                .buttonStyle(.pennantCompact)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    ForEach(fields) { p in
                        PennantTextField(p.label, placeholder: p.placeholder, text: Binding(get: { values[p.key] ?? "" }, set: { values[p.key] = $0 }))
                    }
                    PennantTextField("Client ID", placeholder: "From the app's settings", text: $clientID)
                    if showsSecret {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(entry.needsClientSecret ? "Client secret" : "Client secret (optional)")
                            SecureField(entry.needsClientSecret ? "The app's client secret" : "Leave empty: this app type has none", text: $clientSecret).textFieldStyle(.plain).pennantField()
                        }
                    }
                    Text("The id stays on the server's config on the host and the tokens in its Keychain. Sign in opens the browser; the sign-in page sends you back to the redirect URL.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            InspectorHairline(inset: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantSecondary).keyboardShortcut(.cancelAction)
                Button("Sign in") { submit() }
                    .buttonStyle(.pennantPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear(perform: restore)
    }

    private var ready: Bool {
        func filled(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return filled(clientID) && (!entry.needsClientSecret || filled(clientSecret)) && fields.allSatisfy { filled(values[$0.key]) }
    }

    private func submit() {
        remember()
        onSubmit(clientID, clientSecret, values)
        dismiss()
    }

    // MARK: Remembered per publisher (client id and values only; never the secret)

    private var memoryKey: String { "pennant.registeredClient.\(entry.publisher.lowercased())" }

    private func restore() {
        guard clientID.isEmpty, let saved = UserDefaults.standard.dictionary(forKey: memoryKey) as? [String: String] else { return }
        clientID = saved["clientID"] ?? ""
        for p in fields { if let v = saved["value." + p.key] { values[p.key] = v } }
    }

    private func remember() {
        var saved = ["clientID": clientID.trimmingCharacters(in: .whitespacesAndNewlines)]
        for (k, v) in values { saved["value." + k] = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        UserDefaults.standard.set(saved, forKey: memoryKey)
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redirectURI, forType: .string)
        #else
        UIPasteboard.general.string = redirectURI
        #endif
        copied = true
    }
}

/// Fills the blanks of a local entry: a folder picker, a secure field, or a text field per parameter.
struct MCPLocalSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var entry: MCPCatalogEntry
    var onSubmit: ([String: String]) -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Set up \(entry.name)") { BrandIcon(entry: entry, size: 28) }
            InspectorHairline(inset: 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.summary).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    ForEach(entry.parameters) { p in
                        field(for: p)
                    }
                    if entry.parameters.contains(where: { $0.kind == "secret" }), let help = entry.keyHelpURL, let url = URL(string: help) {
                        Link(destination: url) { Label("Where do I get a token?", systemImage: "questionmark.circle") }
                            .font(.zoomed(.callout))
                            .foregroundStyle(InspectorTint.info)
                    }
                    if let preview {
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel("Runs")
                            Text(preview).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkSecondary).textSelection(.enabled)
                        }
                    }
                    Text("The host runs this command on the Mac. The first run may download the server.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                }
                .padding(20)
            }
            InspectorHairline(inset: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantSecondary).keyboardShortcut(.cancelAction)
                Button("Connect") { onSubmit(resolved); dismiss() }
                    .buttonStyle(.pennantPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
        .frame(minWidth: 460, minHeight: 320)
    }

    @ViewBuilder private func field(for p: MCPCatalogEntry.Parameter) -> some View {
        let binding = Binding(get: { values[p.key] ?? "" }, set: { values[p.key] = $0 })
        switch p.kind {
        case "folder":
            #if os(macOS)
            PathField(p.label, path: binding, placeholder: p.placeholder.isEmpty ? "Choose a folder…" : p.placeholder)
            #else
            PennantTextField("\(p.label) on the Mac", placeholder: p.placeholder, text: binding)
            #endif
        case "secret":
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(p.label)
                SecureField(p.placeholder, text: binding).textFieldStyle(.plain).pennantField()
            }
        default:
            PennantTextField(p.label, placeholder: p.placeholder, text: binding)
        }
    }

    private var valid: Bool {
        entry.parameters.allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Trimmed values, with folders expanded the way the host will see them.
    private var resolved: [String: String] {
        var out: [String: String] = [:]
        for p in entry.parameters {
            var v = (values[p.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            #if os(macOS)
            if p.kind == "folder" { v = (v as NSString).expandingTildeInPath }
            #endif
            out[p.key] = v
        }
        return out
    }

    private var preview: String? {
        guard let config = entry.makeConfig(values: redacted), case .stdio(let cmd, let args, _) = config.transport else { return nil }
        return ([cmd] + args).joined(separator: " ")
    }

    /// The command line with secrets hidden, for the preview.
    private var redacted: [String: String] {
        var out = resolved
        for p in entry.parameters where p.kind == "secret" { out[p.key] = "••••" }
        for p in entry.parameters where (out[p.key] ?? "").isEmpty { out[p.key] = "{\(p.key)}" }
        return out
    }
}

/// Shown on devices that cannot finish the browser step: the host's redirect lands on the Mac.
struct MCPSignInHandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    var url: URL
    var name: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Sign in to \(name)")
            InspectorHairline(inset: 0)
            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in from the Mac app: the browser step needs your Mac's Pennant.")
                    .font(.zoomed(.body)).foregroundStyle(PennantTheme.ink)
                Text("The sign-in page sends you back to the host running on your Mac, so a browser on this device cannot finish it. Copy the link and open it in a browser on that Mac, or press Sign in on the same server there.")
                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                Text(url.absoluteString)
                    .font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                Button { copy() } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.pennantCompact)
            }
            .padding(20)
            Spacer(minLength: 0)
            InspectorHairline(inset: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.pennantPrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
        .frame(minWidth: 440, minHeight: 280)
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.string = url.absoluteString
        #endif
        copied = true
    }
}
