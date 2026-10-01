import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Settings › Models: every model Pennant can use, in one place. The default model (what agents use unless they
/// pick their own), the order to fall back through when a model refuses, and each model's connection, prices
/// and a one-click test.
struct ModelsSettingsView: View {
    @Environment(\.hostSession) private var session
    @State private var config: HostConfig?
    @State private var error: String?
    @State private var saving = false
    @State private var editing: InferenceProfile?
    /// The model being added; a new draft each time, so the sheet never shows (or saves over) the last one.
    @State private var draft: InferenceProfile?
    @State private var confirmDelete: InferenceProfile?
    @State private var tests: [String: ModelTestResult] = [:]
    @State private var testing: Set<String> = []

    private var profiles: [InferenceProfile] { config?.inferenceProfiles ?? [] }

    var body: some View {
        Group {
            if let config {
                SettingsPage {
                    routeCard(config)
                    defaultCard(config)
                    fallbackCard(config)
                    workerCard(config)
                    modelsCard(config)
                    if let error { SettingsNote(error, tone: SettingsTone.danger) }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(error ?? "Loading models…").font(.zoomed(.callout)).foregroundStyle(error == nil ? PennantTheme.inkSecondary : SettingsTone.danger)
                    Button("Reload") { Task { await load() } }.buttonStyle(.pennantCompact)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PennantTheme.panelBackground)
            }
        }
        .task { await load() }
        .sheet(item: $editing) { profile in
            ModelEditorSheet(profile: profile, isNew: false) { updated in upsert(updated) }.id(profile.id)
        }
        .sheet(item: $draft) { profile in
            ModelEditorSheet(profile: profile, isNew: true) { created in upsert(created) }.id(profile.id)
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { p in
            Button("Delete", role: .destructive) { delete(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            let users = agentsUsing(p.id)
            Text(users.isEmpty ? "Its usage history stays in the Usage view." : "\(users.map(\.name).joined(separator: ", ")) will use the default model instead.")
        }
    }

    // MARK: Cards

    /// The whole route at a glance: where a task starts, where it goes when a model fails, and what workers use,
    /// with each model's price and why a hop happens.
    private func routeCard(_ c: HostConfig) -> some View {
        let primary = c.profile(c.defaultProfileID)
        let fallbacks = c.fallbackProfileIDs.compactMap { c.profile($0) }
        let worker = c.workerProfileID.flatMap { c.profile($0) }
        return SettingsCard("How tasks are routed") {
            VStack(alignment: .leading, spacing: 0) {
                if let primary { routeNode("Primary", primary) }
                ForEach(Array(fallbacks.enumerated()), id: \.element.id) { i, p in
                    routeHop(i == 0 ? "Fails twice (server error, used-up quota) → that model rests 3 min, the task moves on" : "Still failing → next in line")
                    routeNode("Fallback \(i + 1)", p)
                }
                routeHop("Rate-limited with nowhere to go → the task pauses and resumes by itself in 2 min")
                if let w = worker ?? primary {
                    Divider().padding(.vertical, 10)
                    routeNode("Workers", w, note: worker == nil ? "same as the primary" : "sub-tasks from delegate_task")
                }
            }
        }
    }

    private func routeNode(_ role: String, _ p: InferenceProfile, note: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(role.uppercased()).font(.zoomed(.caption2).weight(.semibold)).kerning(0.5).foregroundStyle(PennantTheme.inkTertiary).frame(width: 78, alignment: .leading)
            Image(systemName: Self.symbol(p.inference.provider)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 22, height: 22)
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.name).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    if p.inference.supportsVision { Chip("reads images", color: PennantTheme.info) }
                }
                Text(note ?? Self.describe(p.inference)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.shortPrice(p)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkSecondary).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
    }

    private func routeHop(_ text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(PennantTheme.border).frame(width: 2, height: 22).padding(.leading, 98)
            Text(text).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(2)
        }
    }

    /// "$0.04 in / $0.60 out" per 1M tokens, or "$0 · included".
    static func shortPrice(_ p: InferenceProfile) -> String {
        guard let price = p.effectivePricing else { return "no price" }
        if price.included { return "$0 · included" }
        func m(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "?" }
        return "\(m(price.inputPerMillion)) in\n\(m(price.outputPerMillion)) out"
    }

    private func defaultCard(_ c: HostConfig) -> some View {
        SettingsCard("Default model") {
            ChoiceMenu(selection: Binding(get: { c.defaultProfileID ?? "" }, set: { id in mutate { $0.defaultProfileID = id } }),
                       options: profiles.map { option($0) }, placeholder: "Choose a model…")
            SettingsNote("Agents that don't pick their own model use this, and so does Pennant's own housekeeping (titles, memory, summaries).")
        }
    }

    private func fallbackCard(_ c: HostConfig) -> some View {
        SettingsCard("If a model fails") {
            if c.fallbackProfileIDs.isEmpty {
                SettingsNote("No fallbacks: a task whose model refuses (used-up quota, revoked key, missing deployment) tries the default model and then stops.")
            }
            ForEach(Array(c.fallbackProfileIDs.enumerated()), id: \.element) { index, id in
                if let p = c.profile(id) {
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.zoomed(.caption).weight(.semibold).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).frame(width: 16)
                        Image(systemName: ModelsSettingsView.symbol(p.inference.provider)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 18)
                        Text(p.name).font(.zoomed(.callout))
                        Spacer()
                        Button { move(id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.pennantIcon).disabled(index == 0).help("Try earlier")
                        Button { move(id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.pennantIcon).disabled(index == c.fallbackProfileIDs.count - 1).help("Try later")
                        Button { mutate { $0.fallbackProfileIDs.removeAll { $0 == id } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.pennantIcon).help("Remove from fallbacks")
                    }
                }
            }
            let candidates = profiles.filter { $0.id != c.defaultProfileID && !c.fallbackProfileIDs.contains($0.id) }
            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates) { p in Button(p.name) { mutate { $0.fallbackProfileIDs.append(p.id) } } }
                } label: { Label("Add a fallback", systemImage: "plus") }
                    .menuStyle(.button).buttonStyle(.pennantCompact).fixedSize()
            }
            SettingsNote("When an agent's model refuses, its task moves down this list in order, then to the default model, and says so in the conversation. A model whose quota ran out is skipped until it resets.")
        }
    }

    private func workerCard(_ c: HostConfig) -> some View {
        SettingsCard("Worker model") {
            ChoiceMenu(selection: Binding(get: { c.workerProfileID ?? "" }, set: { id in mutate { $0.workerProfileID = id.isEmpty ? nil : id } }),
                       options: [ChoiceOption("", title: "Same as the default model", symbol: "star")] + profiles.map { option($0) }, placeholder: "Same as the default model")
            SettingsNote("When an agent hands a piece of work to a worker (delegate_task), the worker runs on this model. A cheaper or local model suits the mechanical parts: reading pages, finding selectors, drafting files from a clear spec, checking outputs. An agent can still ask for another model for a harder piece.")
        }
    }

    private func modelsCard(_ c: HostConfig) -> some View {
        SettingsCard("Models") {
            HStack {
                Text("\(profiles.count) model\(profiles.count == 1 ? "" : "s")").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                Spacer()
                Button { draft = InferenceProfile(name: "", inference: HostConfig.Inference(baseURL: "", model: "")) } label: { Label("Add model", systemImage: "plus") }.buttonStyle(.pennantPrimaryCompact)
            }
            ForEach(profiles) { p in row(p, c) }
        }
    }

    private func row(_ p: InferenceProfile, _ c: HostConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(p.inference.provider)).font(.zoomed(.title3)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        if p.id == c.defaultProfileID { Chip("Default", color: PennantTheme.brandInk) }
                        if let i = c.fallbackProfileIDs.firstIndex(of: p.id) { Chip("Fallback \(i + 1)") }
                        let users = agentsUsing(p.id)
                        if !users.isEmpty { Chip(users.count == 1 ? users[0].name : "\(users.count) agents") }
                    }
                    Text(Self.describe(p.inference)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1).truncationMode(.middle)
                    Text(Self.priceLine(p)).font(.zoomed(.caption)).foregroundStyle(p.effectivePricing == nil ? SettingsTone.warning : PennantTheme.inkTertiary)
                }
                Spacer(minLength: 8)
                Button(testing.contains(p.id) ? "Testing…" : "Test") { test(p) }.buttonStyle(.pennantGhostCompact).disabled(testing.contains(p.id))
                Button("Edit") { editing = p }.buttonStyle(.pennantCompact)
                Menu {
                    Button("Make default") { mutate { $0.defaultProfileID = p.id } }.disabled(p.id == c.defaultProfileID)
                    Button("Duplicate") { duplicate(p) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = p }.disabled(p.id == c.defaultProfileID)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.pennantIcon).fixedSize()
            }
            if let t = tests[p.id] {
                Label("\(t.detail) · \(t.milliseconds) ms", systemImage: t.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.zoomed(.caption)).foregroundStyle(t.ok ? PennantTheme.success : SettingsTone.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Words

    static func symbol(_ provider: String) -> String {
        provider == HostConfig.Inference.azureProvider ? "cloud" : InferenceProviderLabel.symbol(for: provider)
    }

    static func describe(_ i: HostConfig.Inference) -> String {
        switch i.provider {
        case HostConfig.Inference.azureProvider:
            let auth = i.azure?.auth == HostConfig.Inference.Azure.key ? "key" : "Entra ID"
            return "Azure AI Foundry · \(i.azure?.resource ?? "?") · \(i.model) · \(auth)"
        case HostConfig.Inference.chatGPTProvider: return "ChatGPT account · \(i.model)"
        case HostConfig.Inference.appleProvider: return "Apple on-device model"
        default:
            let place = InferencePresets.preset(for: i.baseURL)?.name ?? URL(string: i.baseURL)?.host ?? i.baseURL
            return "\(place) · \(i.model)"
        }
    }

    static func priceLine(_ p: InferenceProfile) -> String {
        guard let price = p.effectivePricing else { return "No prices set: tokens are counted, cost shows as unknown" }
        if price.included { return p.pricing == nil ? "Included (subscription or local): tokens counted, no per-token cost" : "Included: no per-token cost" }
        func m(_ v: Double?) -> String { v.map { "$" + String(format: $0 < 1 ? "%.3g" : "%.2f", $0) } ?? "?" }
        return "\(m(price.inputPerMillion)) in · \(m(price.cachedInputPerMillion ?? price.inputPerMillion)) cached · \(m(price.outputPerMillion)) out, per 1M tokens"
    }

    private func option(_ p: InferenceProfile) -> ChoiceOption<String> {
        ChoiceOption(p.id, title: p.name, subtitle: Self.describe(p.inference), symbol: Self.symbol(p.inference.provider))
    }

    private func agentsUsing(_ id: String) -> [AgentProfile] {
        session.state.persistentAgents.filter { $0.modelProfileID == id }
    }

    // MARK: Changes

    private func load() async {
        do { config = try await session.getConfig().config; error = nil } catch { self.error = HostSessionError.message(error) }
    }

    private func mutate(_ change: (inout HostConfig) -> Void) {
        guard var c = config else { return }
        change(&c)
        save(c)
    }

    private func save(_ c: HostConfig) {
        config = c
        saving = true
        Task {
            defer { saving = false }
            do { config = try await session.updateConfig(c).config; error = nil } catch { self.error = HostSessionError.message(error) }
        }
    }

    private func upsert(_ p: InferenceProfile) {
        mutate { c in
            if let i = c.inferenceProfiles.firstIndex(where: { $0.id == p.id }) { c.inferenceProfiles[i] = p } else { c.inferenceProfiles.append(p) }
        }
        tests[p.id] = nil
    }

    private func duplicate(_ p: InferenceProfile) {
        var copy = p
        copy.id = UUID().uuidString
        copy.name = p.name + " copy"
        upsert(copy)
    }

    private func delete(_ p: InferenceProfile) {
        mutate { c in
            c.inferenceProfiles.removeAll { $0.id == p.id }
            c.fallbackProfileIDs.removeAll { $0 == p.id }
        }
        for var a in agentsUsing(p.id) {
            a.modelProfileID = nil
            Task { try? await session.updateAgent(a) }
        }
    }

    private func move(_ id: String, by delta: Int) {
        mutate { c in
            guard let i = c.fallbackProfileIDs.firstIndex(of: id) else { return }
            let j = i + delta
            guard c.fallbackProfileIDs.indices.contains(j) else { return }
            c.fallbackProfileIDs.swapAt(i, j)
        }
    }

    private func test(_ p: InferenceProfile) {
        testing.insert(p.id)
        Task {
            defer { testing.remove(p.id) }
            do {
                let result = try await session.testModel(p.inference)
                tests[p.id] = result
                // The test looked at a picture: keep "accepts images" matching what the model actually did.
                if let vision = result.vision, vision != p.inference.supportsVision {
                    mutate { c in
                        if let i = c.inferenceProfiles.firstIndex(where: { $0.id == p.id }) { c.inferenceProfiles[i].inference.supportsVision = vision }
                    }
                }
            } catch { tests[p.id] = ModelTestResult(ok: false, detail: HostSessionError.message(error), milliseconds: 0) }
        }
    }
}

// MARK: - Editor

/// One model: how Pennant reaches it (the connection), which model, how hard it reasons, and what it costs.
struct ModelEditorSheet: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var profile: InferenceProfile
    var isNew: Bool
    var onSave: (InferenceProfile) -> Void
    @State private var nameEdited: Bool
    // Endpoint
    @State private var endpointModels: [ModelInfo] = []
    @State private var endpointStatus: String?
    // ChatGPT account
    @State private var account: ChatGPTAccount?
    @State private var chatGPTModels: [ChatGPTModel] = []
    // Azure
    @State private var azure: AzureStatus?
    @State private var subscriptions: [AzureSubscription] = []
    @State private var resources: [AzureResource] = []
    @State private var deployments: [AzureDeployment] = []
    @State private var azureBusy: String?
    @State private var azureError: String?
    // Prices, as typed
    @State private var priceIn = ""
    @State private var priceCached = ""
    @State private var priceOut = ""
    @State private var included = false
    @State private var test: ModelTestResult?
    @State private var testing = false
    @State private var showTokenCommand = false

    init(profile: InferenceProfile, isNew: Bool, onSave: @escaping (InferenceProfile) -> Void) {
        var p = profile
        if isNew { p.inference.provider = HostConfig.Inference.azureProvider; p.inference.supportsTools = true }
        _profile = State(initialValue: p)
        self.isNew = isNew
        self.onSave = onSave
        _nameEdited = State(initialValue: !isNew)
        let fmt: (Double?) -> String = { $0.map { String($0) } ?? "" }
        _priceIn = State(initialValue: fmt(profile.pricing?.inputPerMillion))
        _priceCached = State(initialValue: fmt(profile.pricing?.cachedInputPerMillion))
        _priceOut = State(initialValue: fmt(profile.pricing?.outputPerMillion))
        _included = State(initialValue: profile.pricing?.included ?? false)
    }

    private var provider: String { profile.inference.provider }

    static let providerOptions: [ChoiceOption<String>] = [
        ChoiceOption(HostConfig.Inference.azureProvider, title: "Azure AI Foundry", symbol: "cloud"),
        ChoiceOption(HostConfig.Inference.openAIProvider, title: "OpenAI-compatible", symbol: "network"),
        ChoiceOption(HostConfig.Inference.chatGPTProvider, title: "ChatGPT account", symbol: "person.crop.circle"),
        ChoiceOption(HostConfig.Inference.appleProvider, title: "Apple on-device", symbol: "apple.logo"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(isNew ? "Add a model" : "Edit \(profile.name)").font(.zoomed(.title3).weight(.semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel("Connection")
                        ChipRow(selection: Binding(get: { provider }, set: { switchProvider($0) }), options: Self.providerOptions)
                    }
                    connection
                    if provider != HostConfig.Inference.appleProvider {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel("Reasoning effort")
                            ChipRow(selection: $profile.inference.reasoningEffort, options: [
                                ChoiceOption<String?>(nil, title: "Auto"), ChoiceOption<String?>("low", title: "Low"),
                                ChoiceOption<String?>("medium", title: "Medium"), ChoiceOption<String?>("high", title: "High"),
                            ])
                        }
                    }
                    if provider == HostConfig.Inference.azureProvider {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel("API")
                            ChipRow(selection: $profile.inference.api, options: [
                                ChoiceOption<String?>(nil, title: "Automatic"), ChoiceOption<String?>(HostConfig.Inference.chatAPI, title: "Chat Completions"),
                                ChoiceOption<String?>(HostConfig.Inference.responsesAPI, title: "Responses"),
                            ])
                            SettingsNote(profile.inference.usesResponsesAPI
                                ? "Responses: reasoning and tools together (GPT-6 needs it for tool calls while reasoning)."
                                : "Chat Completions. Automatic picks Responses for GPT-6 models.")
                        }
                    }
                    if provider == HostConfig.Inference.openAIProvider || provider == HostConfig.Inference.azureProvider { limits }
                    pricing
                    PennantTextField("Name", placeholder: InferenceProfile.suggestedName(for: profile.inference),
                                  text: Binding(get: { profile.name }, set: { profile.name = $0; nameEdited = true }))
                    if let test {
                        Label("\(test.detail) · \(test.milliseconds) ms", systemImage: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.zoomed(.callout)).foregroundStyle(test.ok ? PennantTheme.success : SettingsTone.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            Divider()
            HStack {
                Button(testing ? "Testing…" : "Test") { runTest() }.buttonStyle(.pennantSecondary).disabled(testing || !ready)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost)
                Button(isNew ? "Add model" : "Save") { finish() }.buttonStyle(.pennantPrimary).disabled(!ready)
            }
            .padding(16)
        }
        .frame(width: 620, height: 720)
        .background(PennantTheme.windowBackground)
        .task { await prepare() }
    }

    private var ready: Bool {
        switch provider {
        case HostConfig.Inference.appleProvider: return true
        case HostConfig.Inference.azureProvider: return profile.inference.azure != nil && !profile.inference.model.isEmpty
        default: return !profile.inference.model.isEmpty
        }
    }

    // MARK: Connection sections

    @ViewBuilder private var connection: some View {
        switch provider {
        case HostConfig.Inference.azureProvider: azureSection
        case HostConfig.Inference.chatGPTProvider: accountSection
        case HostConfig.Inference.appleProvider:
            SettingsNote("Apple's on-device model through Apple Intelligence: private, offline, no account. It can't see screenshots and has a small context (about 8k tokens), so it suits light tasks.")
        default: endpointSection
        }
    }

    @ViewBuilder private var azureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let azure, !azure.installed {
                SettingsNote("The Azure CLI isn't installed on the host Mac. Install it with Homebrew (`brew install azure-cli`), then come back: Pennant uses it to sign in with Microsoft Entra ID and to list your resources.", tone: SettingsTone.warning)
                Button("Check again") { Task { await loadAzure() } }.buttonStyle(.pennantCompact)
            } else if let azure, !azure.signedIn {
                SettingsNote("The Azure CLI on the host isn't signed in.")
                Button(azureBusy == "login" ? "Waiting for the browser…" : "Sign in with Microsoft") { azureLogin() }.buttonStyle(.pennantPrimaryCompact).disabled(azureBusy != nil)
            } else if let azure {
                Label("Signed in as \(azure.user ?? "?") through the Azure CLI", systemImage: "checkmark.seal.fill").font(.zoomed(.caption)).foregroundStyle(PennantTheme.success)
                ChoiceMenu("Subscription", selection: Binding(get: { profile.inference.azure?.subscriptionID ?? "" }, set: { pickSubscription($0) }),
                           options: subscriptions.map { ChoiceOption($0.id, title: $0.name, subtitle: $0.id) }, placeholder: "Choose a subscription…")
                if !resources.isEmpty || azureBusy == "resources" {
                    ChoiceMenu("Resource", selection: Binding(get: { profile.inference.azure.map { "\($0.subscriptionID)/\($0.resourceGroup)/\($0.resource)" } ?? "" }, set: { pickResource($0) }),
                               options: resources.map { r in
                                   var notes = [r.location, r.kind]
                                   if !r.publicNetworkAccess { notes.append("private network only") }
                                   if r.keysDisabled { notes.append("Entra ID only") }
                                   return ChoiceOption(r.id, title: r.name, subtitle: notes.joined(separator: " · "), symbol: "cloud")
                               }, placeholder: azureBusy == "resources" ? "Loading resources…" : "Choose a resource…")
                }
                if let r = selectedResource {
                    if !r.publicNetworkAccess {
                        SettingsNote("\(r.name) only accepts traffic from its private network. The host Mac needs the VPN or WARP client that reaches it connected, or requests will be refused.", tone: SettingsTone.warning)
                    }
                    ChoiceMenu("Deployment", selection: Binding(get: { profile.inference.model }, set: { pickDeployment($0) }),
                               options: deployments.map { ChoiceOption($0.name, title: $0.name, subtitle: "\($0.model) \($0.version)") },
                               placeholder: azureBusy == "deployments" ? "Loading deployments…" : "Choose a deployment…")
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Sign-in")
                        ChipRow(selection: Binding(get: { profile.inference.azure?.auth ?? HostConfig.Inference.Azure.entra }, set: { profile.inference.azure?.auth = $0 }), options: [
                            ChoiceOption(HostConfig.Inference.Azure.entra, title: "Microsoft Entra ID", symbol: "person.badge.key"),
                            ChoiceOption(HostConfig.Inference.Azure.key, title: "API key", symbol: "key"),
                        ])
                        if profile.inference.azure?.auth == HostConfig.Inference.Azure.key {
                            if r.keysDisabled { SettingsNote("This resource has keys turned off; use Entra ID.", tone: SettingsTone.warning) }
                            ModelKeyField(inference: $profile.inference, label: "API key", placeholder: "Key 1 or 2 from the resource's Keys page", suggestedName: "\(r.name)-key", optional: false)
                        } else {
                            SettingsNote("Uses the Azure CLI's sign-in on the host (your Microsoft account) and fetches a fresh token when it expires. No keys are stored.")
                        }
                    }
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the Azure CLI on the host…").font(.zoomed(.caption)) }
            }
            if let azureError { SettingsNote(azureError, tone: SettingsTone.danger) }
        }
    }

    private var selectedResource: AzureResource? {
        guard let a = profile.inference.azure else { return nil }
        return resources.first { $0.name == a.resource && $0.resourceGroup == a.resourceGroup && $0.subscriptionID == a.subscriptionID }
    }

    @ViewBuilder private var accountSection: some View {
        ChatGPTAccountBlock(account: $account)
        ChoiceMenu("Model", selection: Binding(get: { profile.inference.model }, set: { id in
            profile.inference.model = id
            if let m = chatGPTModels.first(where: { $0.id == id }) { profile.inference.contextWindowTokens = m.contextWindowTokens; profile.inference.supportsVision = m.supportsVision }
            suggestName()
        }), options: chatGPTModels.map { ChoiceOption($0.id, title: $0.title, subtitle: "\(formatTokens($0.contextWindowTokens)) context") }, placeholder: account?.signedIn == true ? "Choose a model…" : "Sign in to list models")
    }

    @ViewBuilder private var endpointSection: some View {
        SearchablePicker("Endpoint", selection: Binding(get: { profile.inference.baseURL.isEmpty ? nil : profile.inference.baseURL }, set: { url in
            let u = url ?? ""
            profile.inference.baseURL = u
            if let p = InferencePresets.all.first(where: { $0.baseURL == u }) {
                profile.inference.preset = p.id
                profile.inference.supportsVision = p.supportsVision
                profile.inference.supportsTools = p.supportsTools
                if let first = p.exampleModels.first, profile.inference.model.isEmpty { profile.inference.model = first }
            } else {
                profile.inference.preset = nil
            }
            Task { await loadEndpointModels() }
        }), options: InferencePresets.all.map { ChoiceOption($0.baseURL, title: $0.name, subtitle: $0.baseURL, symbol: $0.symbol) }, placeholder: "Choose or type an endpoint…") { typed in
            let t = typed.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t
        }
        SearchablePicker("Model", selection: Binding(get: { profile.inference.model.isEmpty ? nil : profile.inference.model }, set: { profile.inference.model = $0 ?? ""; suggestName() }),
                         options: endpointModels.map { ChoiceOption($0.id, title: $0.id) } + (InferencePresets.preset(for: profile.inference.baseURL)?.exampleModels ?? []).filter { id in !endpointModels.contains { $0.id == id } }.map { ChoiceOption($0, title: $0, subtitle: "example") },
                         placeholder: "Choose or type a model…") { typed in
            let t = typed.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t
        }
        if let endpointStatus { SettingsNote(endpointStatus) }
        ModelKeyField(inference: $profile.inference, label: "API key", placeholder: "Paste the key", suggestedName: keyName, optional: true)
            .onChange(of: profile.inference.apiKeyVault) { _, _ in Task { await loadEndpointModels() } }
        PennantDisclosure("Token command", isExpanded: $showTokenCommand) {
            PennantTextField(placeholder: "A command that prints a short-lived token, e.g. gcloud auth print-access-token", text: Binding(get: { profile.inference.apiKeyCommand ?? "" }, set: { profile.inference.apiKeyCommand = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }))
            SettingsNote("For endpoints that take short-lived sign-in tokens instead of a key. Pennant runs it when it needs a token and again when the token expires.")
        }
        Toggle("Model accepts images", isOn: $profile.inference.supportsVision).toggleStyle(.switch)
        Toggle("Model supports tool calls", isOn: $profile.inference.supportsTools).toggleStyle(.switch)
    }

    /// A Vault name for a new key: the preset's id, else the endpoint's host ("openrouter-key", "api.example.com-key").
    private var keyName: String {
        let base = InferencePresets.preset(for: profile.inference.baseURL)?.id ?? URL(string: profile.inference.baseURL)?.host ?? "model"
        return "\(base)-key"
    }

    private var limits: some View {
        HStack(alignment: .top, spacing: 12) {
            ChoiceMenu("Context window", selection: $profile.inference.contextWindowTokens, options: tokenOptions([32_000, 64_000, 128_000, 200_000, 256_000, 400_000, 1_000_000], current: profile.inference.contextWindowTokens))
            ChoiceMenu("Max output", selection: $profile.inference.maxOutputTokens, options: tokenOptions([4096, 8192, 16384, 32768, 65536, 128_000], current: profile.inference.maxOutputTokens))
        }
    }

    private func tokenOptions(_ values: [Int], current: Int) -> [ChoiceOption<Int>] {
        var v = values
        if !v.contains(current) { v.append(current); v.sort() }
        return v.map { ChoiceOption($0, title: settingsTokenTitle($0)) }
    }

    private var pricing: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Price per million tokens (USD)")
            let subscription = [HostConfig.Inference.chatGPTProvider, HostConfig.Inference.appleProvider].contains(provider)
            Toggle(subscription ? "Included in the subscription (no per-token cost)" : "No per-token cost (a subscription or my own hardware)", isOn: $included).toggleStyle(.switch)
            if !included {
                HStack(spacing: 10) {
                    PennantTextField("Input", placeholder: "e.g. 1.25", text: $priceIn)
                    PennantTextField("Cached input", placeholder: "same as input", text: $priceCached)
                    PennantTextField("Output", placeholder: "e.g. 10", text: $priceOut)
                }
                SettingsNote("From the provider's price page (for Azure, the model's pay-as-you-go price in your region). Pennant bills each call at the prices in force when it ran, in Usage.")
            }
        }
    }

    // MARK: Behaviour

    private func switchProvider(_ new: String) {
        guard new != provider else { return }
        profile.inference.provider = new
        profile.inference.model = new == HostConfig.Inference.appleProvider ? HostConfig.Inference.appleModelID : ""
        profile.inference.azure = nil
        if new == HostConfig.Inference.appleProvider { profile.inference.contextWindowTokens = 8192; profile.inference.supportsVision = false }
        if [HostConfig.Inference.chatGPTProvider, HostConfig.Inference.appleProvider].contains(new), priceIn.isEmpty, priceOut.isEmpty { included = true }
        test = nil
        suggestName()
        Task { await prepare() }
    }

    private func suggestName() {
        if !nameEdited { profile.name = InferenceProfile.suggestedName(for: profile.inference) }
    }

    private func prepare() async {
        switch provider {
        case HostConfig.Inference.azureProvider: await loadAzure()
        case HostConfig.Inference.chatGPTProvider: await loadAccount()
        case HostConfig.Inference.openAIProvider: await loadEndpointModels()
        default: break
        }
    }

    private func loadAccount() async {
        account = try? await session.chatGPTAccount()
        guard account?.signedIn == true else { return }
        chatGPTModels = (try? await session.chatGPTModels()) ?? []
        if profile.inference.model.isEmpty, let first = chatGPTModels.first { profile.inference.model = first.id; profile.inference.contextWindowTokens = first.contextWindowTokens; suggestName() }
    }

    private func loadEndpointModels() async {
        let url = profile.inference.baseURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        if let p = InferencePresets.preset(for: url), !p.supportsModelsEndpoint { endpointStatus = "\(p.name) has no models list; pick an example or type an id."; return }
        endpointStatus = "Fetching models…"
        do {
            endpointModels = try await session.listModels(baseURL: url, apiKey: profile.inference.apiKey, apiKeyVault: profile.inference.apiKeyVault).sorted { $0.id < $1.id }
            endpointStatus = "\(endpointModels.count) model\(endpointModels.count == 1 ? "" : "s") at \(URL(string: url)?.host ?? url)"
        } catch {
            endpointStatus = "Couldn't list models: \(HostSessionError.message(error))"
        }
    }

    private func loadAzure() async {
        azureError = nil
        do { azure = try await session.azureStatus() } catch { azureError = HostSessionError.message(error); return }
        guard azure?.signedIn == true else { return }
        do {
            subscriptions = try await session.azureSubscriptions()
            let sub = profile.inference.azure?.subscriptionID ?? azure?.subscriptionID ?? subscriptions.first?.id
            if let sub { await loadResources(sub) }
        } catch { azureError = HostSessionError.message(error) }
    }

    private func loadResources(_ subscription: String) async {
        azureBusy = "resources"
        defer { azureBusy = nil }
        do {
            resources = try await session.azureResources(subscription: subscription)
            if profile.inference.azure == nil, resources.count == 1 { pickResource(resources[0].id) }
            else if let r = selectedResource { await loadDeployments(r) }
            if resources.isEmpty { azureError = "No Azure AI Foundry or Azure OpenAI resources in this subscription." }
        } catch { azureError = HostSessionError.message(error) }
    }

    private func loadDeployments(_ r: AzureResource) async {
        azureBusy = "deployments"
        defer { azureBusy = nil }
        do { deployments = try await session.azureDeployments(subscription: r.subscriptionID, resourceGroup: r.resourceGroup, resource: r.name) }
        catch { azureError = HostSessionError.message(error) }
    }

    private func pickSubscription(_ id: String) {
        profile.inference.azure = nil
        resources = []
        deployments = []
        Task { await loadResources(id) }
    }

    private func pickResource(_ id: String) {
        guard let r = resources.first(where: { $0.id == id }) else { return }
        profile.inference.azure = .init(subscriptionID: r.subscriptionID, resourceGroup: r.resourceGroup, resource: r.name,
                                        auth: r.keysDisabled ? HostConfig.Inference.Azure.entra : (profile.inference.azure?.auth ?? HostConfig.Inference.Azure.entra))
        profile.inference.baseURL = AzureDeploymentURL.base(r.endpoint)
        profile.inference.supportsTools = true
        deployments = []
        Task { await loadDeployments(r) }
    }

    private func pickDeployment(_ name: String) {
        profile.inference.model = name
        suggestName()
        // Whether it reads images isn't in the deployment's metadata: the test shows it a picture and sets the toggle.
        runTest()
    }

    private func azureLogin() {
        azureBusy = "login"
        Task {
            defer { azureBusy = nil }
            do { azure = try await session.azureLogin(); await loadAzure() } catch { azureError = HostSessionError.message(error) }
        }
    }

    private func currentPricing() -> ModelPricing? {
        if included { return ModelPricing(included: true) }
        let i = Double(priceIn.trimmingCharacters(in: .whitespaces)), c = Double(priceCached.trimmingCharacters(in: .whitespaces)), o = Double(priceOut.trimmingCharacters(in: .whitespaces))
        if i == nil, o == nil, c == nil { return nil }
        return ModelPricing(inputPerMillion: i, cachedInputPerMillion: c, outputPerMillion: o)
    }

    private func runTest() {
        testing = true
        Task {
            defer { testing = false }
            do {
                let result = try await session.testModel(profile.inference)
                test = result
                if let vision = result.vision { profile.inference.supportsVision = vision }
            } catch { test = ModelTestResult(ok: false, detail: HostSessionError.message(error), milliseconds: 0) }
        }
    }

    private func finish() {
        var p = profile
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = InferenceProfile.suggestedName(for: p.inference) }
        p.pricing = currentPricing()
        onSave(p)
        dismiss()
    }
}

/// "https://x.cognitiveservices.azure.com/" → "https://x.cognitiveservices.azure.com/openai/v1".
enum AzureDeploymentURL {
    static func base(_ endpoint: String) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespaces)
        while e.hasSuffix("/") { e.removeLast() }
        return e + "/openai/v1"
    }
}

/// Where a model's key comes from: an entry in the Vault, picked from the list or made from a key pasted here, so
/// the key never sits in config.json. A key someone typed into config.json by hand still works, and can be moved.
struct ModelKeyField: View {
    @Environment(\.hostSession) private var session
    @Binding var inference: HostConfig.Inference
    var label: String
    var placeholder: String
    /// A name for a new entry, from the endpoint or resource ("openrouter-key").
    var suggestedName: String
    /// Endpoints such as a local Ollama need no key.
    var optional: Bool
    @State private var entries: [VaultItem] = []
    @State private var adding = false
    @State private var name = ""
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?

    private static let none = "", new = "\u{0}new"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChoiceMenu(label, selection: Binding(get: { adding ? Self.new : inference.apiKeyVault ?? Self.none }, set: pick), options: options, placeholder: optional ? "No key" : "Choose a key…")
            if adding {
                HStack(spacing: 8) {
                    PennantTextField(placeholder: "Name in the Vault", text: $name).frame(width: 170)
                    SecureField(placeholder, text: $key).textFieldStyle(.plain).pennantField()
                    Button(busy ? "Saving…" : "Save") { Task { await saveNew() } }.buttonStyle(.pennantPrimaryCompact).disabled(busy || key.isEmpty || name.isEmpty)
                }
                SettingsNote("The key goes into the Vault (this Mac's Keychain); the model setup only keeps the entry's name.")
            }
            if let plain = inference.apiKey?.nilIfEmpty, inference.apiKeyVault == nil, !adding {
                HStack(spacing: 8) {
                    SettingsNote("A key is written in config.json (…\(plain.suffix(4))).", tone: SettingsTone.warning)
                    Button("Move it to the Vault") { name = suggestedName; key = plain; Task { await saveNew() } }.buttonStyle(.pennantCompact).disabled(busy)
                }
            }
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
        .task { entries = (try? await session.listVault()) ?? [] }
    }

    private var options: [ChoiceOption<String>] {
        var out: [ChoiceOption<String>] = optional ? [ChoiceOption(Self.none, title: "No key", symbol: "minus.circle")] : []
        out += entries.filter { $0.hasSecret || $0.hasPassword }.map { ChoiceOption($0.name, title: $0.name, subtitle: "In the Vault", symbol: "key") }
        out.append(ChoiceOption(Self.new, title: "Add a key to the Vault…", symbol: "plus"))
        return out
    }

    private func pick(_ value: String) {
        error = nil
        if value == Self.new { adding = true; name = suggestedName; key = ""; return }
        adding = false
        inference.apiKeyVault = value.nilIfEmpty
        if inference.apiKeyVault != nil { inference.apiKey = nil }
    }

    private func saveNew() async {
        busy = true
        defer { busy = false }
        do {
            entries = try await session.saveVaultItem(VaultItem(name: name, kind: .secret, notes: "API key for \(inference.baseURL)"), secret: VaultSecret(secret: key))
            // The Vault normalises names (lowercase, dashes); use the entry it saved.
            let saved = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
            inference.apiKeyVault = saved
            inference.apiKey = nil
            adding = false
            key = ""
            error = nil
        } catch {
            self.error = HostSessionError.message(error)
        }
    }
}
