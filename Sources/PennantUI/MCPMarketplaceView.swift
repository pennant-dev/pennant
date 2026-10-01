import PennantCore
import SwiftUI

/// The marketplace: search, category chips, and a grid of services Pennant knows how to connect. A card shows
/// Connect until a server made from it exists; then it mirrors that server's live state and offers Manage. An
/// entry with an alternate sign-in also offers that route under its chips, and a provider without dynamic client
/// registration gets the registered-client sheet before `onConnect` (the entry then carries the client).
struct MCPMarketplaceView: View {
    var entries: [MCPCatalogEntry]
    var servers: [MCPServerStatus]
    var enabled: Bool
    var busy: [String: String]
    var errors: [String: String]
    var onConnect: (MCPCatalogEntry) -> Void
    var onManage: (MCPServerStatus) -> Void
    var onCancel: (MCPServerStatus) -> Void

    @State private var query = ""
    @State private var category = "All"
    /// How you connect: sign in with the browser, paste a key, nothing to set up, or a server on this Mac.
    @State private var method = "All"
    @State private var showingAll = false
    /// The entry (as its OAuth route) waiting for a hand-registered client id.
    @State private var registeredClient: MCPCatalogEntry?

    /// Cards shown before "Show all": enough to fill a couple of rows without burying the servers below.
    private static let collapsedCount = 6

    private var filtered: [MCPCatalogEntry] {
        MCPCatalog.search(query, category: category == "All" ? nil : category, in: entries).filter { method == "All" || Self.method(of: $0) == method }
    }

    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || category != "All" || method != "All" }

    static func method(of entry: MCPCatalogEntry) -> String {
        if entry.isLocal { return "On this Mac" }
        switch entry.auth {
        case .oauth: return "Sign in"
        case .apiKey: return "API key"
        case .none: return "No setup"
        }
    }

    private var methodOptions: [ChoiceOption<String>] {
        ["All", "Sign in", "API key", "No setup", "On this Mac"].map { ChoiceOption($0, title: $0 == "All" ? "Any sign-in" : $0) }
    }

    private var visible: [MCPCatalogEntry] {
        let all = filtered
        guard !isFiltering, !showingAll, all.count > Self.collapsedCount else { return all }
        // Connected services stay visible; verified entries come first among the rest.
        let connected = all.filter { server(for: $0) != nil }
        let rest = all.filter { server(for: $0) == nil }.sorted { $0.verified && !$1.verified }
        return Array((connected + rest).prefix(Self.collapsedCount))
    }

    private var categoryOptions: [ChoiceOption<String>] {
        [ChoiceOption("All", title: "All")] + MCPCatalog.categories.map { ChoiceOption($0, title: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchField("Search services", text: $query)
            ChipRow(selection: $category, options: categoryOptions)
            ChipRow(selection: $method, options: methodOptions)
            if filtered.isEmpty {
                Text(entries.isEmpty ? "The catalog is empty." : "Nothing matches. Add it as a custom server below.")
                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(visible) { entry in
                        MCPMarketplaceCard(
                            entry: entry,
                            server: server(for: entry),
                            enabled: enabled,
                            busyStep: busy[entry.id],
                            error: errors[entry.id],
                            onConnect: { connect(entry) },
                            onConnectAlternate: entry.alternate.map { alternate in { connect(alternate) } },
                            onManage: { if let s = server(for: entry) { onManage(s) } },
                            onCancel: { if let s = server(for: entry) { onCancel(s) } }
                        )
                    }
                }
                if !isFiltering, filtered.count > Self.collapsedCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showingAll.toggle() }
                    } label: {
                        Label(showingAll ? "Show fewer" : "Show all \(filtered.count) services", systemImage: showingAll ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.pennantGhostCompact)
                }
            }
        }
        .sheet(item: $registeredClient) { entry in
            MCPRegisteredClientSheet(entry: entry) { id, secret, values in onConnect(entry.withRegisteredClient(id: id, secret: secret, values: values)) }
        }
    }

    /// Hands the entry (or its alternate) to the flow, collecting a registered client first when the provider
    /// has no dynamic registration.
    private func connect(_ entry: MCPCatalogEntry) {
        if entry.needsClientBeforeSignIn { registeredClient = entry } else { onConnect(entry) }
    }

    /// The newest server made from this entry, if any.
    private func server(for entry: MCPCatalogEntry) -> MCPServerStatus? {
        servers.filter { $0.config.catalogID == entry.id }.max { $0.config.createdAt < $1.config.createdAt }
    }
}

/// One service: its mark, name and publisher, a line about it, the sign-in chip, and Connect or the live state.
/// An entry with an alternate sign-in shows it as a link under the chips until a server exists.
struct MCPMarketplaceCard: View {
    var entry: MCPCatalogEntry
    var server: MCPServerStatus?
    var enabled: Bool
    var busyStep: String?
    var error: String?
    var onConnect: () -> Void
    var onConnectAlternate: (() -> Void)? = nil
    var onManage: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                BrandIcon(entry: entry, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    Text(entry.publisher).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                trailing
            }
            Text(entry.summary)
                .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Chip(entry.signInLabel, color: signInTint)
                if let live { Chip(live.text, color: live.tint) }
                if !entry.verified { unverifiedChip }
                Spacer(minLength: 0)
            }
            if let alternateLabel = entry.alternateSignInLabel, let onConnectAlternate, server == nil, busyStep == nil {
                Button(alternateLabel) { onConnectAlternate() }
                    .buttonStyle(.plain)
                    .font(.zoomed(.callout))
                    .foregroundStyle(enabled ? InspectorTint.info : PennantTheme.inkTertiary)
                    .disabled(!enabled)
                    .accessibilityHint("Connects \(entry.name) with the other sign-in method")
            }
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(InspectorTint.danger).lineLimit(3).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(elevated: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name) by \(entry.publisher)")
    }

    @ViewBuilder private var trailing: some View {
        if let busyStep {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busyStep).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            }
            .padding(.top, 4)
        } else if let server {
            HStack(spacing: 4) {
                if server.authState == .authorizing {
                    Button("Cancel") { onCancel() }.buttonStyle(.pennantGhostCompact).disabled(!enabled)
                }
                Button("Manage") { onManage() }.buttonStyle(.pennantCompact)
            }
        } else {
            Button("Connect") { onConnect() }.buttonStyle(.pennantPrimaryCompact).disabled(!enabled)
        }
    }

    @ViewBuilder private var unverifiedChip: some View {
        if let docs = entry.docsURL, let url = URL(string: docs) {
            Link(destination: url) { Chip("Unverified", color: PennantTheme.inkTertiary) }
                .help("Not checked against the publisher's documentation yet. Opens the docs.")
        } else {
            Chip("Unverified", color: PennantTheme.inkTertiary)
        }
    }

    private var signInTint: Color {
        if entry.isLocal { return PennantTheme.inkSecondary }
        switch entry.auth {
        case .none: return PennantTheme.inkSecondary
        case .apiKey: return InspectorTint.paused
        case .oauth: return InspectorTint.info
        }
    }

    /// The server's state in one chip, once it exists.
    private var live: (text: String, tint: Color)? {
        guard let server else { return nil }
        return MCPServerPhrase.live(server)
    }
}

/// One tint per category, from the palette, so a glance tells developer tools from data sources.
enum MCPCategoryTint {
    static func color(for category: String) -> Color {
        let name: String
        switch category {
        case "Developer": name = "Ocean"
        case "Productivity": name = "Violet"
        case "Business": name = "Moss"
        case "Design": name = "Rose"
        case "Data": name = "Lagoon"
        case "Web": name = "Tangerine"
        case "Local": name = "Slate"
        default: name = "Ocean"
        }
        return PennantPalette.swatches.first { $0.name == name }?.color ?? PennantTheme.info
    }
}

/// Words and tints for a server's connection and sign-in state, shared by the marketplace cards and the
/// server cards so the same server reads the same in both places.
enum MCPServerPhrase {
    /// Marketplace chip: the sign-in state when it needs attention, else the connection.
    static func live(_ server: MCPServerStatus) -> (text: String, tint: Color) {
        switch server.authState {
        case .authorizing: return ("Waiting in browser…", InspectorTint.info)
        case .signedOut: return ("Sign in needed", InspectorTint.warning)
        case .expired: return ("Expired", InspectorTint.warning)
        case .failed: return ("Sign-in failed", InspectorTint.danger)
        case .notRequired, .signedIn: break
        }
        switch server.state {
        case .connected:
            return (server.toolCount > 0 ? "Connected · \(server.toolCount) tools" : "Connected", InspectorTint.success)
        case .connecting: return ("Connecting…", InspectorTint.info)
        case .disconnected: return ("Disconnected", PennantTheme.inkTertiary)
        case .failed: return ("Failed", InspectorTint.danger)
        }
    }

    /// Server card auth chip; nil when the server needs no credentials.
    static func auth(_ server: MCPServerStatus) -> (text: String, tint: Color)? {
        switch server.authState {
        case .notRequired: return nil
        case .signedOut: return ("Sign in needed", InspectorTint.warning)
        case .authorizing: return ("Waiting in browser…", InspectorTint.info)
        case .signedIn:
            if case .apiKey = server.config.auth { return ("Key in Keychain", InspectorTint.success) }
            return ("Signed in", InspectorTint.success)
        case .expired: return ("Expired", InspectorTint.warning)
        case .failed: return ("Sign-in failed", InspectorTint.danger)
        }
    }
}
