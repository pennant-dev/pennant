import PennantClientKit
import PennantCore
import SwiftUI

/// MCP servers the host owns: a marketplace of services to connect, then each server's state, tool count,
/// sign-in, and the add/remove/reconnect actions.
public struct ConnectionsView: View {
    @Environment(\.hostSession) private var session
    @State private var adding = false
    @State private var flow = MCPConnectFlow()
    @State private var catalog = MCPCatalog.entries
    @State private var highlighted: MCPServerID?
    /// The ChatGPT account behind inference, loaded when the host runs on one.
    @State private var chatGPTAccount: ChatGPTAccount?

    public init() {}

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InspectorSection("Connect a service") {
                        MCPMarketplaceView(
                            entries: catalog,
                            servers: session.state.mcpServers,
                            enabled: session.connection.isConnected,
                            busy: flow.busy,
                            errors: flow.errors,
                            onConnect: { flow.connect($0, session: session) },
                            onManage: { jump(to: $0, proxy: proxy) },
                            onCancel: { flow.cancelAuth($0, session: session) }
                        )
                    }
                    InspectorSection("MCP servers") {
                        Button { adding = true } label: { Label("Add server", systemImage: "plus") }
                            .buttonStyle(.pennantPrimaryCompact)
                            .disabled(!session.connection.isConnected)
                    } content: {
                        if session.state.mcpServers.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No MCP servers yet").font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink)
                                Text("Connect a service above, or add a local command or a remote HTTP server. The host runs it and its tools appear to agents on demand.")
                                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card(elevated: true)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(session.state.mcpServers) { server in
                                    ServerCard(
                                        server: server,
                                        enabled: session.connection.isConnected,
                                        busyStep: flow.step(for: server),
                                        error: flow.errors[server.id.rawValue],
                                        highlighted: highlighted == server.id,
                                        onSignIn: { flow.signIn(server, session: session) },
                                        onSetKey: { flow.sheet = .serverKey(server) },
                                        onSignOut: { flow.signOut(server, session: session) },
                                        onCancelAuth: { flow.cancelAuth(server, session: session) },
                                        onReconnect: { flow.reconnect(server, session: session) },
                                        onRemove: { flow.remove(server, session: session) }
                                    )
                                    .id(server.id)
                                }
                            }
                        }
                    }
                    InspectorSection("Inference") {
                        InspectorListCard(inferenceRows, emptyText: "Not connected") { InspectorKeyValueRow(item: $0) }
                    }
                }
                .padding(16)
            }
        }
        .background(PennantTheme.panelBackground)
        .sheet(isPresented: $adding) { AddMCPServerSheet { config, secret in flow.addCustom(config, secret: secret, session: session) } }
        .sheet(item: $flow.sheet) { sheet in
            switch sheet {
            case .apiKey(let entry):
                MCPAPIKeySheet(title: "Connect \(entry.name)", summary: entry.summary, keyHelpURL: entry.keyHelpURL, mark: BrandIcon(entry: entry, size: 28)) { secret in
                    flow.connectAPIKey(entry, secret: secret, session: session)
                }
            case .local(let entry):
                MCPLocalSetupSheet(entry: entry) { values in flow.connectLocal(entry, values: values, session: session) }
            case .serverKey(let server):
                MCPAPIKeySheet(title: "Key for \(server.config.name)", summary: keySummary(for: server), keyHelpURL: server.config.catalogID.flatMap { MCPCatalog.entry($0)?.keyHelpURL }, mark: BrandIcon(server: server.config, size: 28)) { secret in
                    flow.setKey(server, secret: secret, session: session)
                }
            case .handoff(let url, let name):
                MCPSignInHandoffSheet(url: url, name: name)
            }
        }
        .task {
            guard session.connection.isConnected else { return }
            try? await session.loadMCPServers()
            // The host's catalog wins when it answers (it may be newer than this app); the built-in one is the fallback.
            if let entries = try? await session.mcpCatalog(), !entries.isEmpty { catalog = entries }
            await loadChatGPTAccount()
        }
        .onChange(of: session.state.host?.inferenceProvider) { _, _ in Task { await loadChatGPTAccount() } }
    }

    private var inferenceProvider: String { session.state.host?.inferenceProvider ?? HostConfig.Inference.openAIProvider }

    /// Provider first; then the account (ChatGPT), "On this Mac" (Apple), or the preset and endpoint;
    /// the model; and whether the host can reach it.
    private var inferenceRows: [InspectorKeyValue] {
        guard let host = session.state.host else { return [] }
        let provider = inferenceProvider
        var rows = [InspectorKeyValue(label: "Provider", value: InferenceProviderLabel.title(for: provider))]
        if provider == HostConfig.Inference.chatGPTProvider {
            if chatGPTAccount?.signedIn == true, let who = chatGPTAccount?.email, !who.isEmpty {
                rows.append(InspectorKeyValue(label: "Account", value: who, style: .mono))
            } else {
                rows.append(InspectorKeyValue(label: "Account", value: "Signed out", style: .chip(InspectorTint.warning)))
            }
        } else if provider == HostConfig.Inference.appleProvider {
            rows.append(InspectorKeyValue(label: "Endpoint", value: "On this Mac"))
        } else {
            if let preset = InferencePresets.preset(for: host.inferenceEndpoint) {
                rows.append(InspectorKeyValue(label: "Preset", value: preset.name))
            }
            rows.append(InspectorKeyValue(label: "Endpoint", value: host.inferenceEndpoint, style: .mono))
        }
        rows.append(InspectorKeyValue(label: "Model", value: host.inferenceModel, style: .mono))
        rows.append(InspectorKeyValue(label: "Status", value: host.inferenceReachable ? "Reachable" : "Unreachable", style: .chip(host.inferenceReachable ? InspectorTint.success : InspectorTint.danger)))
        return rows
    }

    private func loadChatGPTAccount() async {
        guard session.connection.isConnected, inferenceProvider == HostConfig.Inference.chatGPTProvider else { chatGPTAccount = nil; return }
        chatGPTAccount = try? await session.chatGPTAccount()
    }

    private func keySummary(for server: MCPServerStatus) -> String? {
        guard case .apiKey(let header, let prefix) = server.config.auth else { return nil }
        let shown = prefix.trimmingCharacters(in: .whitespaces)
        return "Sent on every request as \(header): \(shown.isEmpty ? "<key>" : "\(shown) <key>")."
    }

    /// Manage on a card: scroll to the server and flash its outline.
    private func jump(to server: MCPServerStatus, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(server.id, anchor: .center) }
        highlighted = server.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == server.id { withAnimation(.easeOut(duration: 0.4)) { highlighted = nil } }
        }
    }
}

/// One server: its mark with a status dot, name and chips, the transport line, the sign-in line, then compact actions.
struct ServerCard: View {
    var server: MCPServerStatus
    var enabled: Bool = true
    var busyStep: String?
    var error: String?
    var highlighted: Bool = false
    var onSignIn: () -> Void = {}
    var onSetKey: () -> Void = {}
    var onSignOut: () -> Void = {}
    var onCancelAuth: () -> Void = {}
    var onReconnect: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                mark
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(server.config.name).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink)
                        Chip(stateLabel, color: tint)
                        if server.toolCount > 0 { Chip("\(server.toolCount) tools", color: InspectorTint.info) }
                        if !server.config.enabled { Chip("Disabled") }
                    }
                    Text(transportLabel).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1).truncationMode(.middle)
                    if let auth = MCPServerPhrase.auth(server) {
                        HStack(spacing: 6) {
                            Chip(server.config.auth.label, color: PennantTheme.inkSecondary)
                            Chip(auth.text, color: auth.tint)
                            if let detail = server.authDetail {
                                Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                            }
                        }
                    }
                    if let info = server.serverInfo { Text(info).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                    if let err = server.lastError { Text(err).font(.zoomed(.caption)).foregroundStyle(InspectorTint.danger).lineLimit(2) }
                    if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(InspectorTint.danger).lineLimit(3).textSelection(.enabled) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let busyStep {
                    ProgressView().controlSize(.small)
                    Text(busyStep).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                } else {
                    authButtons
                    Button { onReconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        .buttonStyle(.pennantCompact)
                    Button(role: .destructive) { onRemove() } label: { Label("Remove", systemImage: "trash") }
                        .buttonStyle(.pennantCompact)
                }
            }
            .disabled(!enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(elevated: true)
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(InspectorTint.info, lineWidth: highlighted ? 2 : 0))
    }

    /// The catalog entry's mark, or a generic one for custom servers, with the status dot as a badge.
    private var mark: some View {
        ZStack(alignment: .bottomTrailing) {
            if let brand = BrandIcon(server: server.config, size: 32) {
                brand
            } else {
                InspectorTintedSymbol(symbol: server.config.isHTTP ? "network" : "terminal", tint: MCPCategoryTint.color(for: "Local"), size: 32)
            }
            StatusDot(color: tint, pulsing: server.state == .connecting || server.authState == .authorizing)
                .padding(2)
                .background(Circle().fill(PennantTheme.cardElevated))
                .offset(x: 2, y: 2)
        }
        // The state chip beside the name already says what the dot shows.
        .accessibilityHidden(true)
    }

    /// Sign-in actions by auth kind and state; none for servers that need no credentials.
    @ViewBuilder private var authButtons: some View {
        switch (server.config.auth, server.authState) {
        case (.none, _), (_, .notRequired):
            EmptyView()
        case (_, .authorizing):
            Button { onCancelAuth() } label: { Label("Cancel", systemImage: "xmark") }.buttonStyle(.pennantCompact)
        case (.oauth, .signedOut), (.oauth, .expired), (.oauth, .failed):
            Button { onSignIn() } label: { Label("Sign in", systemImage: "person.crop.circle") }.buttonStyle(.pennantPrimaryCompact)
        case (.apiKey, .signedOut), (.apiKey, .expired), (.apiKey, .failed):
            Button { onSetKey() } label: { Label("Set key…", systemImage: "key") }.buttonStyle(.pennantPrimaryCompact)
        case (.apiKey, .signedIn):
            Button { onSetKey() } label: { Label("Change key…", systemImage: "key") }.buttonStyle(.pennantCompact)
            Button { onSignOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }.buttonStyle(.pennantCompact)
        case (.oauth, .signedIn):
            Button { onSignOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }.buttonStyle(.pennantCompact)
        }
    }

    private var tint: Color {
        switch server.state {
        case .connected: return InspectorTint.success
        case .connecting: return InspectorTint.info
        case .disconnected: return server.authState == .authorizing ? InspectorTint.info : PennantTheme.inkTertiary
        case .failed: return InspectorTint.danger
        }
    }

    private var stateLabel: String {
        switch server.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .failed: return "Failed"
        }
    }

    private var transportLabel: String {
        switch server.config.transport {
        case .stdio(let cmd, let args, _): return ([cmd] + args).joined(separator: " ")
        case .http(let url): return url.absoluteString
        case .builtin: return "Built into Pennant · talks to \(server.config.name) directly"
        }
    }
}

// MARK: - Add server

/// Server templates: choose one, then fill in only what it needs.
enum MCPTemplate: String, CaseIterable, Hashable, Identifiable {
    case filesystem, github, fetch, playwright, remoteHTTP, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .filesystem: return "Filesystem"
        case .github: return "GitHub"
        case .fetch: return "Fetch"
        case .playwright: return "Playwright"
        case .remoteHTTP: return "Remote HTTP"
        case .custom: return "Custom command"
        }
    }

    var subtitle: String {
        switch self {
        case .filesystem: return "Read and write files in one folder"
        case .github: return "Issues, pull requests, and repositories"
        case .fetch: return "Fetch web pages as text"
        case .playwright: return "Drive a browser"
        case .remoteHTTP: return "A server you reach over HTTP"
        case .custom: return "Any command the host can run"
        }
    }

    var symbol: String {
        switch self {
        case .filesystem: return "folder"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .fetch: return "globe"
        case .playwright: return "macwindow"
        case .remoteHTTP: return "network"
        case .custom: return "terminal"
        }
    }

    var defaultName: String {
        switch self {
        case .filesystem: return "Filesystem"
        case .github: return "GitHub"
        case .fetch: return "Fetch"
        case .playwright: return "Playwright"
        case .remoteHTTP: return "Remote server"
        case .custom: return ""
        }
    }

    static var options: [ChoiceOption<MCPTemplate>] { allCases.map { ChoiceOption($0, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol) } }
}

/// How a remote server signs in, for the custom sheet.
enum MCPSignInChoice: String, CaseIterable, Hashable, Identifiable {
    case none, apiKey, oauth
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "No sign-in"
        case .apiKey: return "API key"
        case .oauth: return "OAuth"
        }
    }

    var subtitle: String {
        switch self {
        case .none: return "The server is open or on your network"
        case .apiKey: return "A secret sent in a header on every request"
        case .oauth: return "Sign in with the browser; tokens refresh on their own"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "lock.open"
        case .apiKey: return "key"
        case .oauth: return "person.crop.circle.badge.checkmark"
        }
    }

    static var options: [ChoiceOption<MCPSignInChoice>] { allCases.map { ChoiceOption($0, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol) } }
}

/// Where an API key goes: the common headers, or one you name.
enum MCPKeyHeaderChoice: String, CaseIterable, Hashable, Identifiable {
    case bearer, xAPIKey, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bearer: return "Authorization: Bearer"
        case .xAPIKey: return "X-API-Key"
        case .custom: return "Custom header"
        }
    }

    var subtitle: String? {
        switch self {
        case .bearer: return "Most servers"
        case .xAPIKey: return "Key on its own, no prefix"
        case .custom: return nil
        }
    }

    static var options: [ChoiceOption<MCPKeyHeaderChoice>] { allCases.map { ChoiceOption($0, title: $0.title, subtitle: $0.subtitle) } }
}

struct AddMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The config to add and, for API-key servers, the secret to store right after.
    var onAdd: (MCPServerConfig, String?) -> Void
    @State private var template: MCPTemplate
    @State private var name: String
    @State private var folder = ""
    @State private var githubToken = ""
    @State private var url = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var environment = ""
    // Remote sign-in
    @State private var signIn: MCPSignInChoice = .none
    @State private var keyHeader: MCPKeyHeaderChoice = .bearer
    @State private var customHeader = ""
    @State private var customPrefix = ""
    @State private var secret = ""
    @State private var scopes = ""
    @State private var hasRegisteredClient = false
    @State private var clientID = ""
    @State private var clientSecret = ""

    init(template: MCPTemplate = .filesystem, signIn: MCPSignInChoice = .none, onAdd: @escaping (MCPServerConfig, String?) -> Void) {
        self.onAdd = onAdd
        _template = State(initialValue: template)
        _name = State(initialValue: template.defaultName)
        _signIn = State(initialValue: signIn)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Add MCP server")
            InspectorHairline(inset: 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ChoiceMenu("Server", selection: $template, options: MCPTemplate.options)
                    PennantTextField("Name", placeholder: "What agents will call it", text: $name)
                    templateFields
                    if let preview {
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel("Runs")
                            Text(preview).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkSecondary).textSelection(.enabled)
                        }
                    }
                    Text("The host owns the process and its credentials. Tools appear to agents on demand.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                }
                .padding(20)
            }
            InspectorHairline(inset: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pennantSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { submit() }
                    .buttonStyle(.pennantPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(PennantTheme.panelBackground)
        .frame(minWidth: 480, minHeight: 380)
        .onChange(of: template) { old, new in
            if name.isEmpty || name == old.defaultName { name = new.defaultName }
        }
    }

    @ViewBuilder private var templateFields: some View {
        switch template {
        case .filesystem:
            #if os(macOS)
            PathField("Folder", path: $folder)
            #else
            PennantTextField("Folder on the Mac", placeholder: "/Users/you/Documents", text: $folder)
            #endif
        case .github:
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Personal access token")
                SecureField("ghp_…", text: $githubToken)
                    .textFieldStyle(.plain)
                    .pennantField()
            }
        case .fetch:
            Text("Needs uv on the host; the first run downloads the server.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
        case .playwright:
            Text("Needs Node on the host; the first run downloads the server and a browser.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
        case .remoteHTTP:
            PennantTextField("URL", placeholder: "https://example.com/mcp", text: $url)
            ChoiceMenu("Sign-in", selection: $signIn, options: MCPSignInChoice.options)
            signInFields
        case .custom:
            PennantTextField("Command", placeholder: "npx", text: $command)
            PennantTextField("Arguments", placeholder: "-y @modelcontextprotocol/server-filesystem ~/Documents", text: $arguments)
            PennantTextField("Environment", placeholder: "KEY=value, one per line", text: $environment, lines: 1 ... 4)
        }
    }

    @ViewBuilder private var signInFields: some View {
        switch signIn {
        case .none:
            EmptyView()
        case .apiKey:
            ChoiceMenu("Header", selection: $keyHeader, options: MCPKeyHeaderChoice.options)
            if keyHeader == .custom {
                HStack(spacing: 10) {
                    PennantTextField("Header name", placeholder: "X-Auth-Token", text: $customHeader)
                    PennantTextField("Value prefix", placeholder: "Token ", text: $customPrefix)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("API key")
                SecureField("Paste the key", text: $secret)
                    .textFieldStyle(.plain)
                    .pennantField()
            }
        case .oauth:
            PennantTextField("Scopes", placeholder: "Optional, comma-separated; blank uses what the server advertises", text: $scopes)
            PennantDisclosure("I have a registered client", subtitle: "For providers that do not register clients themselves", isExpanded: $hasRegisteredClient) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Register this redirect URL with the provider first: http://127.0.0.1:47831/callback").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).textSelection(.enabled)
                    PennantTextField("Client ID", placeholder: "From the server's developer settings", text: $clientID)
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Client secret")
                        SecureField("Optional", text: $clientSecret)
                            .textFieldStyle(.plain)
                            .pennantField()
                    }
                }
            }
            Text("Without one, Pennant registers itself with the server (dynamic client registration) and signs you in with PKCE.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var valid: Bool {
        guard !trimmedName.isEmpty else { return false }
        switch template {
        case .filesystem: return !folder.trimmingCharacters(in: .whitespaces).isEmpty
        case .github: return !githubToken.isEmpty
        case .fetch, .playwright: return true
        case .remoteHTTP:
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let u = URL(string: trimmed), u.host != nil else { return false }
            switch signIn {
            case .none, .oauth: return true
            case .apiKey:
                if keyHeader == .custom, customHeader.trimmingCharacters(in: .whitespaces).isEmpty { return false }
                return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .custom: return !command.isEmpty
        }
    }

    /// What the host will run, for the stdio templates.
    private var preview: String? {
        guard let parts = stdioParts else { return nil }
        return ([parts.command] + parts.arguments).joined(separator: " ")
    }

    private var stdioParts: (command: String, arguments: [String])? {
        switch template {
        case .filesystem: return ("npx", ["-y", "@modelcontextprotocol/server-filesystem", folderPath])
        case .github: return ("npx", ["-y", "@modelcontextprotocol/server-github"])
        case .fetch: return ("uvx", ["mcp-server-fetch"])
        case .playwright: return ("npx", ["-y", "@playwright/mcp"])
        case .remoteHTTP, .custom: return nil
        }
    }

    private var folderPath: String {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        #if os(macOS)
        // The host runs on this Mac, so a tilde means the same home folder.
        return (trimmed as NSString).expandingTildeInPath
        #else
        return trimmed
        #endif
    }

    /// The auth for a remote server, from the sign-in choice and its fields.
    private var remoteAuth: MCPAuth {
        switch signIn {
        case .none: return .none
        case .apiKey:
            switch keyHeader {
            case .bearer: return .bearerKey
            case .xAPIKey: return .apiKey(header: "X-API-Key", prefix: "")
            case .custom: return .apiKey(header: customHeader.trimmingCharacters(in: .whitespaces), prefix: customPrefix)
            }
        case .oauth:
            let list = scopes.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let id = clientID.trimmingCharacters(in: .whitespaces)
            let secretValue = clientSecret.trimmingCharacters(in: .whitespaces)
            return .oauth(scopes: list, clientID: hasRegisteredClient && !id.isEmpty ? id : nil, clientSecret: hasRegisteredClient && !secretValue.isEmpty ? secretValue : nil)
        }
    }

    private func submit() {
        let transport: MCPServerConfig.Transport
        var auth: MCPAuth = .none
        var storedSecret: String?
        switch template {
        case .filesystem, .fetch, .playwright:
            guard let parts = stdioParts else { return }
            transport = .stdio(command: parts.command, arguments: parts.arguments, environment: [:])
        case .github:
            guard let parts = stdioParts else { return }
            // The official server reads GITHUB_PERSONAL_ACCESS_TOKEN; GITHUB_TOKEN covers forks that read that.
            transport = .stdio(command: parts.command, arguments: parts.arguments, environment: ["GITHUB_TOKEN": githubToken, "GITHUB_PERSONAL_ACCESS_TOKEN": githubToken])
        case .remoteHTTP:
            guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            transport = .http(url: u)
            auth = remoteAuth
            if signIn == .apiKey { storedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines) }
        case .custom:
            let args = arguments.split(separator: " ").map(String.init)
            var env: [String: String] = [:]
            for line in environment.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { env[parts[0]] = parts[1] }
            }
            transport = .stdio(command: command, arguments: args, environment: env)
        }
        onAdd(MCPServerConfig(name: trimmedName, transport: transport, auth: auth), storedSecret)
        dismiss()
    }
}
