import PennantClientKit
import PennantCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Plugins on the host: each one's state, what it may use (granted here, one by one), its settings, its tools and what
/// it asked for lately. Installing happens on the Mac that runs the host.
public struct PluginsView: View {
    @Environment(\.hostSession) private var session
    @State private var vault: [VaultItem] = []
    @State private var busy: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var installError: String?
    @State private var installing = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection("Installed") {
                    if canInstall {
                        Button { install() } label: { Label(installing ? "Installing…" : "Install…", systemImage: "plus") }
                            .buttonStyle(.pennantPrimaryCompact)
                            .disabled(installing || !session.connection.isConnected)
                    }
                } content: {
                    if let installError {
                        Text(installError).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).textSelection(.enabled)
                    }
                    if session.state.plugins.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No plugins yet").font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink)
                            Text(canInstall
                                 ? "A plugin is a program that runs beside Pennant, in a sandbox of its own, and adds tools. It gets only what you allow here. Install a .plugin to start."
                                 : "A plugin is a program that runs beside Pennant, in a sandbox of its own, and adds tools. Install plugins on the Mac that runs Pennant; you can allow what they use from here.")
                                .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(elevated: true)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(session.state.plugins) { plugin in
                                PluginCard(plugin: plugin, vault: vault, busy: busy.contains(plugin.id), error: errors[plugin.id],
                                           enabled: session.connection.isConnected) { command in await run(plugin.id, command) }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(PennantTheme.panelBackground)
        // Loads when the page opens and again whenever the host connection comes back.
        .task(id: session.connection.isConnected) {
            guard session.connection.isConnected else { return }
            try? await session.loadPlugins()
            vault = (try? await session.listVault()) ?? []
        }
    }

    /// The host is on this Mac, so a bundle picked here is a path the host can read.
    private var canInstall: Bool {
        #if os(macOS)
        return session.endpoint.isLoopback
        #else
        return false
        #endif
    }

    private func run(_ id: String, _ command: CommandBody) async {
        busy.insert(id)
        errors[id] = nil
        do { try await session.plugins(command) } catch { errors[id] = PluginPhrase.message(error) }
        busy.remove(id)
    }

    private func install() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Install a plugin"
        panel.prompt = "Install"
        panel.message = "Choose a .plugin bundle."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "plugin" else { installError = "\(url.lastPathComponent) isn't a plugin: its name should end in .plugin."; return }
        installing = true
        installError = nil
        Task {
            do { try await session.installPlugin(from: url) } catch { installError = PluginPhrase.message(error) }
            installing = false
        }
        #endif
    }
}

/// One plugin: its mark and state, the switch that turns it on, what it may use, and its details.
struct PluginCard: View {
    var plugin: PluginStatus
    var vault: [VaultItem]
    var busy: Bool
    var error: String?
    var enabled: Bool
    var send: (CommandBody) async -> Void
    @State private var details = PluginCard.detailsOpen
    @State private var confirmRemove = false

    /// Debug builds can open every card's details (`PENNANT_DEBUG_PLUGIN_DETAILS=1`), for screenshots.
    static var detailsOpen: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PENNANT_DEBUG_PLUGIN_DETAILS"] != nil
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                mark
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(plugin.name).font(.zoomed(.body).weight(.medium)).foregroundStyle(PennantTheme.ink)
                        Chip(PluginPhrase.state(plugin), color: PluginPhrase.tint(plugin))
                        if !plugin.tools.isEmpty { Chip("\(plugin.tools.count) tools", color: InspectorTint.info) }
                    }
                    Text(plugin.summary).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    Text("\(plugin.version)\(plugin.publisher.isEmpty ? "" : " · \(plugin.publisher)")").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    if let last = plugin.lastError, plugin.enabled {
                        Text(last).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).lineLimit(3).textSelection(.enabled)
                    }
                    if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).lineLimit(4).textSelection(.enabled) }
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                Toggle("On", isOn: Binding(get: { plugin.enabled }, set: { on in Task { await send(.setPluginEnabled(id: plugin.id, enabled: on)) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("\(plugin.name) on")
            }
            if !plugin.capabilities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Can use").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                        if missing > 0 { Chip("\(missing) not allowed yet", color: InspectorTint.warning) }
                    }
                    InspectorListCard(plugin.capabilities.map { PluginCapabilityItem(capability: $0) }) { item in
                        PluginCapabilityRow(capability: item.capability, pluginName: plugin.name, vault: vault) { value in
                            Task { await send(.grantPlugin(id: plugin.id, capability: item.capability.key, value: value)) }
                        } onRevoke: {
                            Task { await send(.revokePlugin(id: plugin.id, capability: item.capability.key)) }
                        }
                    }
                }
            }
            PennantDisclosure("Details", subtitle: "Settings, tools, and what it asked for lately", isExpanded: $details) {
                PluginDetails(plugin: plugin) { settings in
                    Task { await send(.setPluginSettings(id: plugin.id, settings: settings)) }
                } onRemove: {
                    confirmRemove = true
                }
                .padding(.top, 6)
            }
        }
        .disabled(!enabled || busy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(elevated: true)
        .confirmationDialog("Remove \(plugin.name)?", isPresented: $confirmRemove) {
            Button("Remove \(plugin.name)", role: .destructive) { Task { await send(.removePlugin(id: plugin.id)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tools go, along with what you allowed it and the data it kept. You can install it again later.")
        }
    }

    private var missing: Int { plugin.capabilities.filter { !$0.granted }.count }

    private var mark: some View {
        ZStack(alignment: .bottomTrailing) {
            InspectorTintedSymbol(symbol: "puzzlepiece.extension", tint: PennantTheme.brand, size: 32)
            StatusDot(color: PluginPhrase.tint(plugin), pulsing: plugin.state == .starting)
                .padding(2)
                .background(Circle().fill(PennantTheme.cardElevated))
                .offset(x: 2, y: 2)
        }
        .accessibilityHidden(true)
    }
}

struct PluginCapabilityItem: Identifiable {
    var capability: PluginStatus.Capability
    var id: String { capability.key }
}

/// One thing a plugin asks for, and the control that allows it: a switch for an ability, a vault item for a secret, a
/// command (shown before it's allowed, and editable) for a sign-in helper.
struct PluginCapabilityRow: View {
    var capability: PluginStatus.Capability
    var pluginName: String
    var vault: [VaultItem]
    var onGrant: (String?) -> Void
    var onRevoke: () -> Void
    @State private var editing = false
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: PluginPhrase.symbol(capability)).foregroundStyle(capability.granted ? PennantTheme.brand : PennantTheme.inkTertiary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PluginPhrase.title(capability)).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                    if let why = PluginPhrase.why(capability, pluginName: pluginName) {
                        Text(why).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if capability.kind != "secret" {
                    Toggle(PluginPhrase.title(capability), isOn: Binding(get: { capability.granted }, set: { on in
                        if on { onGrant(capability.kind == "credential" ? (capability.value ?? capability.suggest) : nil) } else { onRevoke() }
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            switch capability.kind {
            case "secret": secretPicker
            case "credential": commandLine
            default: EmptyView()
            }
        }
        .padding(.leading, 0)
    }

    /// Choose the vault item; choosing none takes it away.
    @ViewBuilder private var secretPicker: some View {
        if vault.isEmpty {
            Text("Add the item in Vault first, then choose it here.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).padding(.leading, 30)
        } else {
            ChoiceMenu(selection: Binding(get: { capability.value ?? "" }, set: { name in name.isEmpty ? onRevoke() : onGrant(name) }),
                       options: [ChoiceOption("", title: "Not allowed", symbol: "nosign")]
                           + vault.map { ChoiceOption($0.name, title: $0.name, subtitle: $0.username, symbol: $0.kind == .login ? "person.badge.key" : "key") })
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.leading, 30)
        }
    }

    /// The command Pennant runs for the token: what will run before it's allowed, what runs once it is, and a way to change it.
    @ViewBuilder private var commandLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                PennantTextField(placeholder: "A command that prints a token", text: $command)
                    .font(.zoomed(.caption).monospaced())
                HStack(spacing: 8) {
                    Button("Allow with this command") { onGrant(command.trimmingCharacters(in: .whitespacesAndNewlines)); editing = false }
                        .buttonStyle(.pennantPrimaryCompact)
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false }.buttonStyle(.pennantCompact)
                }
            } else if let shown = capability.value ?? capability.suggest {
                HStack(spacing: 8) {
                    Text(capability.granted ? "Runs" : "Would run").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    Spacer(minLength: 0)
                    Button("Change…") { command = shown; editing = true }.buttonStyle(.pennantCompact)
                }
                Text(shown)
                    .font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PennantTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text("Pennant runs it as you, outside the plugin's sandbox, and hands the plugin only what it prints.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
        .padding(.leading, 30)
    }
}

/// Under Details: the settings form, the tools, the latest requests, where it's installed, and Remove.
struct PluginDetails: View {
    var plugin: PluginStatus
    var onSave: (JSONValue) -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !PluginSettingsForm.fields(plugin.settingsSchema).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Settings")
                    PluginSettingsForm(schema: plugin.settingsSchema, settings: plugin.settings, onSave: onSave)
                }
            }
            if !plugin.tools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Tools")
                    InspectorListCard(plugin.tools.map { PluginToolItem(tool: $0) }) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.tool.name).font(.zoomed(.callout).monospaced()).foregroundStyle(PennantTheme.ink)
                                if item.tool.asksFirst { Chip("Asks you first", color: PennantTheme.brand) }
                                else if item.tool.readOnly { Chip("Reads only", color: InspectorTint.info) }
                            }
                            Text(item.tool.description).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Lately")
                InspectorListCard(plugin.activity.prefix(12).enumerated().map { PluginActivityItem(index: $0.offset, activity: $0.element) }, emptyText: "It hasn't asked for anything yet.") { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.activity.at, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
                        Text(PluginPhrase.activity(item.activity.what)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.ink)
                        Spacer(minLength: 0)
                        if !item.activity.allowed { Chip("Refused", color: PennantTheme.danger) }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(plugin.path).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Button(role: .destructive) { onRemove() } label: { Label("Remove", systemImage: "trash") }.buttonStyle(.pennantCompact)
            }
        }
    }
}

struct PluginToolItem: Identifiable {
    var tool: PluginStatus.Tool
    var id: String { tool.name }
}

struct PluginActivityItem: Identifiable {
    var index: Int
    var activity: PluginStatus.Activity
    var id: Int { index }
}

/// A plugin's settings, drawn from the schema in its manifest: a menu for a choice, a switch for yes or no, a list of
/// names, or a field. Edits are kept here until Save (the plugin restarts with them).
struct PluginSettingsForm: View {
    var schema: JSONValue?
    var settings: JSONValue
    var onSave: (JSONValue) -> Void
    @State private var draft: [String: JSONValue] = [:]
    @State private var adding: [String: String] = [:]

    struct Field: Identifiable {
        var key: String
        var schema: JSONValue
        var id: String { key }
        var type: String { schema["type"]?.stringValue ?? "string" }
        var choices: [String]? { schema["enum"]?.arrayValue?.compactMap(\.stringValue) }
        var description: String? { schema["description"]?.stringValue }
        var title: String {
            let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            return spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
        }
    }

    static func fields(_ schema: JSONValue?) -> [Field] {
        (schema?["properties"]?.objectValue ?? [:]).map { Field(key: $0.key, schema: $0.value) }.sorted { $0.key < $1.key }
    }

    private var current: [String: JSONValue] { settings.objectValue ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.fields(schema)) { field in
                VStack(alignment: .leading, spacing: 4) {
                    control(field)
                    if let d = field.description { Text(d).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if draft != current {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Revert") { draft = current }.buttonStyle(.pennantCompact)
                    Button("Save settings") { onSave(.object(draft)) }.buttonStyle(.pennantPrimaryCompact)
                }
            }
        }
        .onAppear { draft = current }
        .onChange(of: settings) { _, _ in draft = current }
    }

    @ViewBuilder private func control(_ field: Field) -> some View {
        if let choices = field.choices {
            ChoiceMenu(field.title, selection: stringBinding(field.key),
                       options: [ChoiceOption("", title: "Default")] + choices.map { ChoiceOption($0, title: PluginPhrase.choice($0)) })
                .frame(maxWidth: 320, alignment: .leading)
        } else if field.type == "boolean" {
            Toggle(field.title, isOn: Binding(get: { draft[field.key]?.boolValue ?? false }, set: { draft[field.key] = .bool($0) }))
                .toggleStyle(.switch)
        } else if field.type == "array" {
            listField(field)
        } else {
            PennantTextField(field.title, placeholder: field.type == "string" ? "Not set" : "A number", text: field.type == "string" ? stringBinding(field.key) : numberBinding(field.key))
        }
    }

    /// Names as chips, each with a way to take it out, and a field to add one.
    private func listField(_ field: Field) -> some View {
        let items = draft[field.key]?.arrayValue?.compactMap(\.stringValue) ?? []
        return VStack(alignment: .leading, spacing: 6) {
            FieldLabel(field.title)
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            let rest = items.filter { $0 != item }
                            draft[field.key] = rest.isEmpty ? nil : .array(rest.map { .string($0) })
                        } label: {
                            HStack(spacing: 4) {
                                Text(item)
                                Image(systemName: "xmark").font(.zoomed(.caption2).weight(.semibold))
                            }
                            .font(.zoomed(.caption))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(PennantTheme.brandSoft, in: Capsule())
                            .foregroundStyle(PennantTheme.brandInk)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item)")
                    }
                }
            }
            PennantTextField(placeholder: items.isEmpty ? "Add one (empty means all)" : "Add another", text: Binding(get: { adding[field.key] ?? "" }, set: { adding[field.key] = $0 }))
                .onSubmit {
                    let new = (adding[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !new.isEmpty, !items.contains(new) else { return }
                    draft[field.key] = .array((items + [new]).map { .string($0) })
                    adding[field.key] = ""
                }
        }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { draft[key]?.stringValue ?? "" }, set: { draft[key] = $0.isEmpty ? nil : .string($0) })
    }

    private func numberBinding(_ key: String) -> Binding<String> {
        Binding(get: { draft[key]?.doubleValue.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? "" },
                set: { text in draft[key] = Double(text.trimmingCharacters(in: .whitespaces)).map(JSONValue.number) })
    }
}

/// The words the Plugins page uses for states, capabilities and requests.
enum PluginPhrase {
    static func state(_ p: PluginStatus) -> String {
        guard p.enabled else { return "Off" }
        switch p.state {
        case .running: return "Running"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed: return "Stopped working"
        }
    }

    static func tint(_ p: PluginStatus) -> Color {
        guard p.enabled else { return PennantTheme.inkTertiary }
        switch p.state {
        case .running: return InspectorTint.success
        case .starting: return InspectorTint.info
        case .stopped: return PennantTheme.inkTertiary
        case .failed: return InspectorTint.danger
        }
    }

    static func symbol(_ c: PluginStatus.Capability) -> String {
        switch c.kind {
        case "secret": return "key.fill"
        case "credential": return "terminal"
        default: return c.key == "network" ? "globe" : c.key == "chat.post" ? "bubble.left" : "checkmark.shield"
        }
    }

    static func title(_ c: PluginStatus.Capability) -> String {
        switch c.kind {
        case "secret": return "A secret: \(humanized(String(c.key.dropFirst("secret:".count))))"
        case "credential": return "A sign-in: \(humanized(String(c.key.dropFirst("credential:".count))))"
        default:
            switch c.key {
            case "network": return "The internet"
            case "chat.post": return "Notes in the Pennant chat"
            default: return c.key
            }
        }
    }

    static func why(_ c: PluginStatus.Capability, pluginName: String) -> String? {
        if let why = c.why, !why.isEmpty { return why }
        switch c.key {
        case "network": return "Without it, \(pluginName) can reach nothing but Pennant."
        case "chat.post": return "\(pluginName) can leave you a note in the chat, under its name."
        default: return nil
        }
    }

    /// "azure-service-principal" → "Azure service principal".
    static func humanized(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// "servicePrincipal" → "Service principal".
    static func choice(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
    }

    /// "tool azure__costs" → "Used costs"; "secrets/get azure-service-principal" → "Read the secret Azure service principal".
    static func activity(_ what: String) -> String {
        let parts = what.split(separator: " ", maxSplits: 1).map(String.init)
        let detail = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "tool": return "Ran \(detail)"
        case "secrets/get": return "Asked for the secret \(humanized(detail.replacingOccurrences(of: "secret:", with: "")))"
        case "credentials/get": return "Asked for the sign-in \(humanized(detail.replacingOccurrences(of: "credential:", with: "")))"
        case "chat/post": return "Posted in the chat"
        default: return what
        }
    }

    static func message(_ error: Error) -> String {
        if case .hostError(_, let message)? = error as? HostSessionError { return message }
        return String(describing: error)
    }
}
