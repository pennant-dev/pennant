import AppKit
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

struct SettingsView: View {
    @Environment(\.hostSession) private var session
    @Environment(HostLauncher.self) private var launcher
    @State private var host = AppSettings.endpoint.host
    @State private var port = AppSettings.endpoint.port
    @State private var token = AppSettings.token(for: AppSettings.endpoint) ?? ""
    @State private var discovery = HostDiscovery()

    @AppStorage("pennant.settings.pane") private var paneRaw = Pane.general.rawValue

    /// The settings sections, in sidebar order.
    enum Pane: String, CaseIterable, Identifiable {
        case general, pennant, connection, host, people, iphone, channels, models, usage, hostSettings, permissions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .pennant: return "Pennant"
            case .connection: return "Connection"
            case .host: return "Host"
            case .people: return "People"
            case .iphone: return "iPhone"
            case .channels: return "Channels"
            case .models: return "Models"
            case .usage: return "Usage"
            case .hostSettings: return "Host settings"
            case .permissions: return "Permissions"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .pennant: return "flag"
            case .connection: return "network"
            case .host: return "desktopcomputer"
            case .people: return "person.2"
            case .iphone: return "iphone"
            case .channels: return "bubble.left.and.bubble.right"
            case .models: return "cpu"
            case .usage: return "chart.bar"
            case .hostSettings: return "slider.horizontal.3"
            case .permissions: return "lock.shield"
            }
        }
    }

    private var pane: Pane { Pane(rawValue: paneRaw) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(PennantTheme.divider).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title)
                    .font(.zoomed(.title2).weight(.semibold))
                    .foregroundStyle(PennantTheme.ink)
                    .padding(.horizontal, 20)
                    .padding(.top, 40)
                    .padding(.bottom, 4)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(PennantTheme.panelBackground)
        }
        .frame(width: 900, height: 640)
        // No title band: the sidebar and the pane's own title fill the window, as in the main window.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases) { p in
                Button { paneRaw = p.rawValue } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol).frame(width: 20).foregroundStyle(pane == p ? PennantTheme.ink : PennantTheme.inkSecondary)
                        Text(p.title).foregroundStyle(PennantTheme.ink)
                        Spacer(minLength: 0)
                    }
                    .font(.zoomed(.body))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(pane == p ? PennantTheme.selection : .clear, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PennantTheme.sidebarBackground)
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: appearanceTab
        case .pennant: PennantAgentSettings()
        case .connection: connectionTab
        case .host: hostTab
        case .people: PeopleSettingsView()
        case .iphone: IPhoneSettingsView()
        case .channels: ChannelsSettingsView()
        case .models: ModelsSettingsView()
        case .usage: UsageView()
        case .hostSettings: HostConfigView()
        case .permissions: permissionsTab
        }
    }

    // MARK: Connection

    private static let localHost = "127.0.0.1"
    private static let defaultPort = HostEndpoint.local.port

    /// Discovered hosts that have resolved to an address, one per address.
    private var discovered: [(name: String, endpoint: HostEndpoint)] {
        var seen = Set<String>()
        return discovery.hosts.compactMap { h in
            guard let e = h.endpoint, !seen.contains(e.host) else { return nil }
            seen.insert(e.host)
            return (h.serviceName, e)
        }
    }

    private var hostOptions: [ChoiceOption<String>] {
        var out = [ChoiceOption(Self.localHost, title: "This Mac", subtitle: Self.localHost, symbol: "desktopcomputer")]
        for d in discovered where d.endpoint.host != Self.localHost && d.endpoint.host != "localhost" {
            out.append(ChoiceOption(d.endpoint.host, title: d.name, subtitle: "\(d.endpoint.host):\(d.endpoint.port) · found on the network", symbol: "wifi"))
        }
        if !host.isEmpty, !out.contains(where: { $0.value == host }) {
            out.append(ChoiceOption(host, title: host, subtitle: "Typed address", symbol: "pencil"))
        }
        return out
    }

    private var portOptions: [ChoiceOption<Int>] {
        var out = [ChoiceOption(Self.defaultPort, title: "\(Self.defaultPort)", subtitle: "Default port")]
        for d in discovered where !out.contains(where: { $0.value == d.endpoint.port }) {
            out.append(ChoiceOption(d.endpoint.port, title: "\(d.endpoint.port)", subtitle: d.name))
        }
        if !out.contains(where: { $0.value == port }) { out.append(ChoiceOption(port, title: "\(port)", subtitle: "Custom")) }
        return out
    }

    private var hostSelection: Binding<String?> {
        Binding(get: { host.isEmpty ? nil : host }, set: { host = $0 ?? Self.localHost })
    }

    private var portSelection: Binding<Int?> {
        Binding(get: { port }, set: { port = $0 ?? Self.defaultPort })
    }

    private var appearanceTab: some View {
        SettingsPage {
            SettingsCard("Appearance") {
                AppearancePicker()
                SettingsNote("Match system follows the Mac's light or dark setting. The iPhone app has its own choice.")
            }
            UpdatesSettingsCard()
        }
    }

    private var connectionTab: some View {
        SettingsPage {
            SettingsCard("Host") {
                SearchablePicker("Address", selection: hostSelection, options: hostOptions, placeholder: "Choose a host…") { typed in
                    let t = typed.trimmingCharacters(in: .whitespaces)
                    return t.isEmpty ? nil : t
                }
                SettingsNote(discoveryHint, tone: PennantTheme.inkTertiary)
                SearchablePicker("Port", selection: portSelection, options: portOptions, placeholder: "\(Self.defaultPort)") { typed in
                    guard let p = Int(typed.trimmingCharacters(in: .whitespaces)), (1 ... 65535).contains(p) else { return nil }
                    return p
                }
                SettingsSecureField(label: "Token", placeholder: "Paste the host's token", text: $token)
                HStack {
                    Button("Use this Mac's local token") { if let t = ClientCredentials.readLocalHostToken() { token = t } }
                        .buttonStyle(.pennantCompact)
                        .disabled(ClientCredentials.readLocalHostToken() == nil)
                    Spacer()
                    Button("Apply and reconnect") { apply() }.buttonStyle(.pennantPrimaryCompact)
                }
                SettingsRow("Status") {
                    HStack(spacing: 8) {
                        StatusDot(color: SettingsTone.color(for: session.connection), pulsing: SettingsTone.isBusy(session.connection))
                        Text(session.connectionLabel).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                    }
                }
            }
            MovePennantCard()
            SettingsCard("Deployment") {
                SettingsRow("Mode", value: session.state.host?.mode == .dedicated ? "Dedicated Mac (operated remotely)" : "Everyday Mac (shares your desktop)")
                Toggle("Pause agents when I use the mouse or keyboard", isOn: Binding(
                    get: { session.state.desktop.pauseOnHumanInput },
                    set: { v in Task { try? await session.setPauseOnHumanInput(v) } }
                ))
                .toggleStyle(.switch)
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: host) { _, new in
            // Picking a discovered host also picks the port it advertises.
            if let d = discovered.first(where: { $0.endpoint.host == new }) { port = d.endpoint.port }
        }
    }

    private var discoveryHint: String {
        let n = discovered.count
        if n > 0 { return "\(n) host\(n == 1 ? "" : "s") found on this network. Type a Tailscale or LAN name to use another." }
        if discovery.isBrowsing { return "Looking for hosts on this network… Type a Tailscale or LAN name to use another." }
        if let e = discovery.lastError { return "Network discovery is unavailable (\(e)). Type an address instead." }
        return "Type a Tailscale or LAN name to reach a host on another Mac."
    }

    // MARK: Host

    private var hostTab: some View {
        SettingsPage {
            SettingsCard("Host service") {
                SettingsRow("Running as", value: launcher.mode.rawValue)
                if let p = launcher.binaryPath {
                    SettingsRow("Binary") { Text(p).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.ink).truncationMode(.middle).lineLimit(1) }
                }
                SettingsRow("Login item", value: launcher.agentStatusLabel)
                HStack(spacing: 8) {
                    Button("Register as login item") { launcher.registerAgent() }.buttonStyle(.pennantCompact)
                    Button("Unregister") { launcher.unregisterAgent() }.buttonStyle(.pennantCompact)
                    Spacer()
                    Button("Start host now") { Task { await launcher.ensureHostRunning(port: session.endpoint.port); session.connect() } }.buttonStyle(.pennantCompact)
                    Button("Restart host") { Task { await launcher.restartHost(port: session.endpoint.port); session.connect() } }.buttonStyle(.pennantPrimaryCompact)
                }
                if let e = launcher.lastError { SettingsNote(e, tone: SettingsTone.danger) }
                SettingsNote("The host keeps working when this window is closed. Registering it as a login item keeps it running after a restart. Grant Accessibility and Screen Recording to pennant-host in System Settings > Privacy & Security.")
            }
            SettingsCard("Host details") {
                if let h = session.state.host {
                    SettingsRow("Name", value: h.hostName)
                    SettingsRow("Version", value: h.version)
                    SettingsRow("Model", value: h.inferenceModel)
                    SettingsRow("Endpoint", value: InferenceProviderLabel.endpointLine(provider: h.inferenceProvider, endpoint: h.inferenceEndpoint))
                    SettingsRow("Database") { Text(h.databasePath).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.ink).truncationMode(.middle).lineLimit(1) }
                } else {
                    Text("Not connected").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                }
            }
        }
    }

    // MARK: Permissions

    private var permissionsTab: some View {
        ScrollView {
            PermissionsView(onRestartHost: {
                await session.disconnect()
                await launcher.restartHost(port: session.endpoint.port)
                session.connect()
            })
            .padding(16)
        }
        .background(PennantTheme.panelBackground)
    }

    private func apply() {
        let name = discovered.first { $0.endpoint.host == host }?.name ?? (host == Self.localHost ? "This Mac" : host)
        let endpoint = HostEndpoint(host: host.trimmingCharacters(in: .whitespaces), port: port, name: name)
        AppSettings.endpoint = endpoint
        AppSettings.setToken(token.isEmpty ? nil : token, for: endpoint)
        session.token = token.isEmpty ? ClientCredentials.readLocalHostToken() : token
        Task {
            await session.disconnect()
            session.connect(to: endpoint)
        }
    }
}

/// Edits the host's config.json through the API. Restarts the host when the reply says it is required.
struct HostConfigView: View {
    @Environment(\.hostSession) private var session
    @Environment(HostLauncher.self) private var launcher
    @State private var config: HostConfig?
    @State private var apiPort = 0
    @State private var autoResume = 0
    @State private var maxSteps = 0
    @State private var maxTokens = 0
    @State private var maxDuration = 0
    @State private var maxDelegations = 0
    @State private var compactAt = 0
    @State private var keepRecent = 0
    @State private var restartRequired = false
    @State private var status: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Group {
            if config != nil {
                form
            } else {
                VStack(spacing: 10) {
                    if busy { ProgressView() }
                    Text(session.connection.isConnected ? (error ?? "Loading host settings…") : "Connect to the host to edit its settings.")
                        .font(.zoomed(.callout))
                        .foregroundStyle(error == nil ? PennantTheme.inkSecondary : SettingsTone.danger)
                    Button("Reload") { load() }.buttonStyle(.pennantCompact).disabled(busy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PennantTheme.panelBackground)
            }
        }
        .task { load() }
    }

    // MARK: Choices

    static let apiPortPresets = [HostEndpoint.local.port, 7777, 8787, 9090]
    static let stepPresets: [(Int, String)] = [(30, "30 steps"), (60, "60 steps"), (120, "120 steps"), (200, "200 steps"), (500, "500 steps"), (1000, "1,000 steps"), (0, "No limit")]
    static let tokenPresets: [(Int, String)] = [(400_000, "400k tokens"), (1_000_000, "1M tokens"), (2_000_000, "2M tokens"), (5_000_000, "5M tokens"), (10_000_000, "10M tokens"), (25_000_000, "25M tokens"), (0, "No limit")]
    static let durationPresets: [(Int, String)] = [(900, "15 minutes"), (1800, "30 minutes"), (3600, "1 hour"), (7200, "2 hours"), (14400, "4 hours"), (28800, "8 hours"), (0, "No limit")]
    static let compactPresets: [(Int, String)] = [(32_000, "32k tokens"), (64_000, "64k tokens"), (96_000, "96k tokens"), (128_000, "128k tokens"), (200_000, "200k tokens"), (256_000, "256k tokens"), (512_000, "512k tokens"), (0, "Only at 75% of the window")]
    static let keepRecentPresets: [(Int, String)] = [(4, "4 messages"), (8, "8 messages"), (12, "12 messages"), (20, "20 messages"), (40, "40 messages")]
    static let delegationPresets: [(Int, String)] = [(0, "None"), (1, "1 worker"), (2, "2 workers"), (3, "3 workers"), (5, "5 workers"), (10, "10 workers")]

    private func limitOptions(_ presets: [(Int, String)], current: Int, unit: String) -> [ChoiceOption<Int>] {
        var out = presets.map { ChoiceOption($0.0, title: $0.1) }
        if !out.contains(where: { $0.value == current }) {
            out.append(ChoiceOption(current, title: "\(current.formatted()) \(unit)", subtitle: "Current"))
        }
        return out
    }

    static let autoResumePresets: [(seconds: Int, title: String)] = [
        (0, "Never"), (10, "10 seconds"), (30, "30 seconds"), (60, "60 seconds"), (120, "2 minutes"), (300, "5 minutes"),
    ]

    private var apiPortOptions: [ChoiceOption<Int>] {
        var out = Self.apiPortPresets.map { ChoiceOption($0, title: "\($0)", subtitle: $0 == HostEndpoint.local.port ? "Default port" : nil) }
        if !out.contains(where: { $0.value == apiPort }) { out.insert(ChoiceOption(apiPort, title: "\(apiPort)", subtitle: "Current"), at: 0) }
        return out
    }

    private var autoResumeOptions: [ChoiceOption<Int>] {
        var out = Self.autoResumePresets.map { ChoiceOption($0.seconds, title: $0.title) }
        if !out.contains(where: { $0.value == autoResume }) {
            out.append(ChoiceOption(autoResume, title: "\(autoResume) seconds", subtitle: "Current"))
            out.sort { $0.value < $1.value }
        }
        return out
    }

    private static let modeOptions: [ChoiceOption<DeploymentMode>] = [
        ChoiceOption(.everyday, title: "Everyday Mac", symbol: "person.crop.circle"),
        ChoiceOption(.dedicated, title: "Dedicated Mac", symbol: "server.rack"),
    ]

    private func modeNote(_ mode: DeploymentMode) -> String {
        switch mode {
        case .everyday: return "Agents share your desktop and pause when you use the mouse or keyboard."
        case .dedicated: return "This Mac is operated remotely; agents keep the desktop to themselves."
        }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        let binding = Binding(get: { config ?? HostConfig() }, set: { config = $0 })
        let apiPortSelection = Binding<Int?>(get: { apiPort }, set: { apiPort = $0 ?? HostEndpoint.local.port })
        SettingsPage {
            SettingsCard("Models") {
                SettingsNote("Models, the default model, fallbacks and prices are in the Models tab.")
            }
            SettingsCard("House rules") {
                houseRulesSection(binding)
            }
            SettingsCard("Deployment") {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Mode")
                    ChipRow(selection: binding.mode, options: Self.modeOptions)
                    SettingsNote(modeNote(binding.wrappedValue.mode))
                }
            }
            SettingsCard("API") {
                SearchablePicker("Port", selection: apiPortSelection, options: apiPortOptions, placeholder: "\(HostEndpoint.local.port)") { typed in
                    guard let p = Int(typed.trimmingCharacters(in: .whitespaces)), (1 ... 65535).contains(p) else { return nil }
                    return p
                }
                Toggle("Accept connections from the network (needed for iPhone)", isOn: binding.api.listenOnNetwork).toggleStyle(.switch)
                Toggle("Advertise on the local network (Bonjour)", isOn: binding.api.advertiseBonjour).toggleStyle(.switch)
            }
            SettingsCard("Desktop") {
                Toggle("Pause agents on human input", isOn: binding.desktop.pauseOnHumanInput).toggleStyle(.switch)
                ChoiceMenu("Auto-resume after inactivity", selection: $autoResume, options: autoResumeOptions)
            }
            SettingsCard("Compaction") {
                HStack(alignment: .top, spacing: 12) {
                    ChoiceMenu("Compact when the context reaches", selection: $compactAt, options: limitOptions(Self.compactPresets, current: compactAt, unit: "tokens"))
                    ChoiceMenu("Keep verbatim after compacting", selection: $keepRecent, options: limitOptions(Self.keepRecentPresets, current: keepRecent, unit: "messages"))
                }
                SettingsNote("The agent folds older history into a checkpoint when the context reaches this size or 75% of the model's window, whichever comes first. Long-context models drift and hallucinate well before their window is full, so keep this well under it.")
            }
            SettingsCard("Task limits") {
                HStack(alignment: .top, spacing: 12) {
                    ChoiceMenu("Steps per task", selection: $maxSteps, options: limitOptions(Self.stepPresets, current: maxSteps, unit: "steps"))
                    ChoiceMenu("New tokens per task", selection: $maxTokens, options: limitOptions(Self.tokenPresets, current: maxTokens, unit: "tokens"))
                }
                HStack(alignment: .top, spacing: 12) {
                    ChoiceMenu("Time per task", selection: $maxDuration, options: limitOptions(Self.durationPresets, current: maxDuration, unit: "seconds"))
                    ChoiceMenu("Workers per task", selection: $maxDelegations, options: limitOptions(Self.delegationPresets, current: maxDelegations, unit: "workers"))
                }
                SettingsNote("When a task reaches a limit the agent pauses and asks you whether to keep going. Replying grants it the same allowance again. Tokens count what the task adds (new messages, tool results, screenshots, and the model's replies), not the conversation it re-reads every turn, so compaction and long threads don't use them up. Steps and time still stop a task that goes round in circles.")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Reload") { load() }.buttonStyle(.pennantCompact)
                    Spacer()
                    if restartRequired {
                        Button("Restart host") { restart() }.buttonStyle(.pennantCompact)
                    }
                    Button("Save") { save() }.buttonStyle(.pennantPrimaryCompact)
                }
                .disabled(busy)
                if let status { SettingsNote(status, tone: restartRequired ? SettingsTone.warning : PennantTheme.inkSecondary) }
                if let error { SettingsNote(error, tone: SettingsTone.danger) }
            }
        }
    }

    // MARK: Host calls

    private func load() {
        guard session.connection.isConnected else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let (c, restart) = try await session.getConfig()
                apply(c, restart: restart)
            } catch { self.error = String(describing: error) }
        }
    }

    private func apply(_ c: HostConfig, restart: Bool) {
        config = c
        apiPort = c.api.port
        autoResume = Int(c.desktop.autoResumeAfterSeconds)
        maxSteps = c.defaultBudget.maxSteps
        maxTokens = c.defaultBudget.maxTokens
        maxDuration = Int(c.defaultBudget.maxDuration)
        maxDelegations = c.defaultBudget.maxDelegations
        compactAt = c.compaction.triggerTokens
        keepRecent = c.compaction.keepRecentMessages
        restartRequired = restart
        status = restart ? "The host needs a restart to apply the saved settings." : nil
    }

    // MARK: House rules

    @ViewBuilder private func houseRulesSection(_ binding: Binding<HostConfig>) -> some View {
        let isDefault = (binding.wrappedValue.houseRules ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        SettingsNote("How every agent works, in its system prompt under \"How to work\". Each agent's own role, voice and standing instructions come on top, and \"See what an agent sees\" in its menu shows the whole prompt. Keep it short: every line is sent on every turn.")
        TextEditor(text: Binding(
            get: { binding.wrappedValue.houseRules ?? HouseRules.default },
            set: { binding.wrappedValue.houseRules = ($0 == HouseRules.default) ? nil : $0 }
        ))
        .font(.zoomed(.callout, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: 260)
        .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        HStack(spacing: 10) {
            Text(isDefault ? "Using Pennant's default rules." : "Customised. About \(((binding.wrappedValue.houseRules ?? "").count + 3) / 4) tokens per turn.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            Spacer()
            Button("Reset to default") { binding.wrappedValue.houseRules = nil }
                .buttonStyle(.pennantCompact)
                .disabled(isDefault)
        }
        SettingsNote("Saved with the Save button below; running agents use the new rules from their next step.")
    }

    // MARK: Profiles

    private func save() {
        guard var c = config else { return }
        c.api.port = apiPort > 0 ? apiPort : c.api.port
        c.desktop.autoResumeAfterSeconds = Double(autoResume)
        c.defaultBudget = TaskBudget(maxSteps: maxSteps, maxTokens: maxTokens, maxDuration: Double(maxDuration), maxDelegations: maxDelegations)
        c.compaction.triggerTokens = compactAt
        c.compaction.keepRecentMessages = max(1, keepRecent)
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                // Models are edited in the Models tab, and coding in Settings › Pennant: keep the host's current
                // ones, never this page's copy.
                let fresh = try await session.getConfig().config
                c.inference = fresh.inference
                c.inferenceProfiles = fresh.inferenceProfiles
                c.defaultProfileID = fresh.defaultProfileID
                c.fallbackProfileIDs = fresh.fallbackProfileIDs
                c.coding = fresh.coding
                let (saved, restart) = try await session.updateConfig(c)
                apply(saved, restart: restart)
                if !restart { status = "Saved and applied." }
            } catch { self.error = String(describing: error) }
        }
    }

    private func restart() {
        busy = true
        status = "Restarting the host…"
        let port = config?.api.port ?? session.endpoint.port
        Task {
            defer { busy = false }
            await session.disconnect()
            await launcher.restartHost(port: session.endpoint.port)
            if port != session.endpoint.port {
                var endpoint = session.endpoint
                endpoint.port = port
                AppSettings.endpoint = endpoint
                session.connect(to: endpoint)
            } else {
                session.connect()
            }
            restartRequired = false
            status = launcher.lastError ?? "Host restarted."
            if launcher.lastError != nil { error = launcher.lastError }
        }
    }
}
