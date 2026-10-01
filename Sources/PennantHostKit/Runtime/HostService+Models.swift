import PennantCore
import CoreGraphics
import Foundation
import ImageIO

/// The models the host talks to: making a provider for a config, testing one (and whether it reads images),
/// and the usage report.
extension HostService {
    // MARK: Models

    /// The inference provider for an inference config: the ChatGPT account (Codex OAuth), Apple's on-device model,
    /// an Azure AI Foundry deployment, or any OpenAI-compatible endpoint. A key comes from the Vault entry the config
    /// names, a token command, or the config itself, in that order.
    static func makeProvider(_ inference: HostConfig.Inference, chatGPT: ChatGPTAuthManager, vault: VaultService) -> any InferenceProvider {
        if inference.provider == HostConfig.Inference.chatGPTProvider { return ChatGPTProvider(config: inference, auth: chatGPT) }
        if inference.provider == HostConfig.Inference.appleProvider { return AppleOnDeviceProvider() }
        if inference.provider == HostConfig.Inference.azureProvider {
            let authority: any EndpointAuthority
            if inference.azure?.auth == HostConfig.Inference.Azure.key {
                authority = inference.apiKeyVault?.nilIfEmpty.map { VaultKeyAuthority(entry: $0, baseURL: inference.baseURL, header: "api-key", vault: vault) }
                    ?? StaticHeaderAuthority(baseURL: inference.baseURL, headers: ["api-key": inference.apiKey ?? ""])
            } else {
                authority = CommandTokenAuthority(command: AzureCLI.tokenCommand(subscription: inference.azure?.subscriptionID), baseURL: inference.baseURL)
            }
            // GPT-6 only calls tools while reasoning through the Responses API.
            if inference.usesResponsesAPI { return AzureResponsesProvider(config: inference, authority: authority) }
            return OpenAICompatibleProvider(config: inference, authority: authority)
        }
        if let entry = inference.apiKeyVault?.nilIfEmpty {
            return OpenAICompatibleProvider(config: inference, authority: VaultKeyAuthority(entry: entry, baseURL: inference.baseURL, vault: vault))
        }
        if let command = inference.apiKeyCommand?.nilIfEmpty {
            return OpenAICompatibleProvider(config: inference, authority: CommandTokenAuthority(command: command, baseURL: inference.baseURL))
        }
        return OpenAICompatibleProvider(config: inference)
    }

    /// The usage ledger summed per task and model, with each task's title.
    func usageReport(from: Date, to: Date) async throws -> [UsageRow] {
        let records = try await store.usage(from: from, to: to)
        var rows: [String: UsageRow] = [:]
        var titles: [TaskID: String] = [:]
        for r in records {
            let key = "\(r.taskID.rawValue)|\(r.modelLabel)"
            if titles[r.taskID] == nil { titles[r.taskID] = (try? await store.task(r.taskID))?.map { String($0.title.prefix(120)) } ?? "Task \(r.taskID.rawValue.prefix(8))" }
            var row = rows[key] ?? UsageRow(agentID: r.agentID, taskID: r.taskID, taskTitle: titles[r.taskID] ?? "", modelLabel: r.modelLabel, provider: r.provider,
                                            calls: 0, inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, cost: 0, unpricedCalls: 0, estimatedCalls: 0, first: r.at, last: r.at)
            row.calls += 1
            row.inputTokens += r.inputTokens
            row.cachedInputTokens += r.cachedInputTokens
            row.outputTokens += r.outputTokens
            if let c = r.cost { row.cost += c } else { row.unpricedCalls += 1 }
            if r.estimated { row.estimatedCalls += 1 }
            row.first = min(row.first, r.at)
            row.last = max(row.last, r.at)
            rows[key] = row
        }
        let jobs = await UsageJobs.resolve(Set(rows.values.map(\.taskID)), store: store)
        return rows.values.map { row in var row = row; row.job = jobs[row.taskID]; return row }.sorted { $0.last > $1.last }
    }

    /// One short prompt through a model setup, with the failure put in words a person can act on.
    func testModel(_ inference: HostConfig.Inference) async -> ModelTestResult {
        let provider = Self.makeProvider(inference, chatGPT: chatGPT, vault: vault)
        let started = Date()
        var request = InferenceRequest(messages: [ModelMessage(role: .user, parts: [.text("Reply with the single word: ready")])], maxOutputTokens: 256, temperature: 0, disableTools: true)
        request.reasoningEffort = inference.reasoningEffort == nil ? nil : "low"
        do {
            var text = ""
            for try await chunk in provider.stream(request) { if case .textDelta(let t) = chunk { text += t } }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let vision = await Self.probeVision(inference) { [chatGPT, vault] in Self.makeProvider($0, chatGPT: chatGPT, vault: vault) }
            var detail = text.isEmpty ? "Answered (no text)" : "Answered: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))"
            if let vision { detail += vision ? " · reads images" : " · text only" }
            return ModelTestResult(ok: true, detail: detail, milliseconds: ms, vision: vision)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return ModelTestResult(ok: false, detail: Self.explain(error), milliseconds: ms)
        }
    }

    /// Shows the model a square in a random colour and asks which colour it is: a model that can't see images
    /// either refuses the request or guesses (right one time in four). Nil for providers that send no images.
    static func probeVision(_ inference: HostConfig.Inference, makeProvider: @Sendable (HostConfig.Inference) -> any InferenceProvider) async -> Bool? {
        guard inference.provider != HostConfig.Inference.appleProvider else { return nil }
        let colors: [(name: String, rgb: (CGFloat, CGFloat, CGFloat))] = [("red", (0.9, 0.1, 0.1)), ("green", (0.1, 0.75, 0.2)), ("blue", (0.1, 0.25, 0.9)), ("yellow", (0.95, 0.85, 0.1))]
        let pick = colors.randomElement()!
        guard let png = solidPNG(pick.rgb) else { return nil }
        var probe = inference
        probe.supportsVision = true
        let provider = makeProvider(probe)
        var request = InferenceRequest(messages: [ModelMessage(role: .user, parts: [.text("What colour is this square? Answer with one word: red, green, blue or yellow."), .image(data: png, mimeType: "image/png")])], maxOutputTokens: 256, temperature: 0, disableTools: true)
        request.reasoningEffort = inference.reasoningEffort == nil ? nil : "low"
        do {
            var text = ""
            for try await chunk in provider.stream(request) { if case .textDelta(let t) = chunk { text += t } }
            return text.lowercased().contains(pick.name)
        } catch {
            let lower = String(describing: error).lowercased()
            // Only an answer about the image itself settles it; a timeout or outage says nothing about vision.
            return ["image", "vision", "multimodal", "content type", "image_url"].contains { lower.contains($0) } ? false : nil
        }
    }

    static func solidPNG(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Data? {
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Model errors as next steps.
    static func explain(_ error: Error) -> String {
        let raw = String(describing: error)
        let lower = raw.lowercased()
        if lower.contains("public access is disabled") || lower.contains("private endpoint") {
            return "This resource only accepts traffic from its private network. Connect the VPN or WARP client that reaches it, then test again."
        }
        if lower.contains("usage_limit_reached") || lower.contains("insufficient_quota") { return "The account's usage limit is used up: \(raw.prefix(160))" }
        if lower.contains("deploymentnotfound") || lower.contains("deployment for this resource does not exist") { return "No deployment with that name on this resource." }
        if lower.contains("isn't signed in") || lower.contains("az login") { return "The Azure CLI on the host isn't signed in. Use Sign in." }
        if lower.contains("401") || lower.contains("unauthorized") { return "The endpoint refused the credentials (401). Check the key or sign in again." }
        if lower.contains("403") { return "The endpoint refused access (403): \(raw.prefix(200))" }
        return raw.count > 280 ? String(raw.prefix(280)) + "…" : raw
    }

    /// What `HostInfo.inferenceEndpoint` shows: the base URL, the ChatGPT account (its email once signed in), or
    /// Apple's on-device model and whether it is available.
    func inferenceEndpointLabel() async -> String {
        switch config.inference.provider {
        case HostConfig.Inference.appleProvider:
            return "On this Mac · \(AppleOnDeviceProvider.availability)"
        case HostConfig.Inference.chatGPTProvider:
            let account = await chatGPT.account()
            if account.signedIn, let email = account.email, !email.isEmpty { return email }
            return "ChatGPT account"
        default:
            return config.inference.baseURL
        }
    }

    /// The ChatGPT account changed (sign-in, import, sign-out, refresh outcome): re-check reachability when it is
    /// the provider in use and tell clients.
    func chatGPTAccountChanged() async {
        if config.inference.provider == HostConfig.Inference.chatGPTProvider {
            await updateInference(reachable: await provider.healthCheck())
        }
        await publishHostStatus()
    }
}

/// Providers for saved profiles, built once per distinct inference setting and reused across tasks.
actor ProviderCache {
    let chatGPT: ChatGPTAuthManager
    let vault: VaultService
    private var cache: [HostConfig.Inference: any InferenceProvider] = [:]

    init(chatGPT: ChatGPTAuthManager, vault: VaultService) {
        self.chatGPT = chatGPT
        self.vault = vault
    }

    func provider(for inference: HostConfig.Inference) -> any InferenceProvider {
        if let cached = cache[inference] { return cached }
        let made = HostService.makeProvider(inference, chatGPT: chatGPT, vault: vault)
        if cache.count > 16 { cache.removeAll() }
        cache[inference] = made
        return made
    }
}
