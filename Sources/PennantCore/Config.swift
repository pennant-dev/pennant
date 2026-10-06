import Foundation

/// Host configuration stored at `~/Library/Application Support/Pennant/config.json`.
public struct HostConfig: Hashable, Codable, Sendable {
    public struct Inference: Hashable, Codable, Sendable {
        /// OpenAI-compatible base URL, e.g. `http://gpu-box.local:8000/v1` (vLLM/SGLang) or `http://localhost:11434/v1` (Ollama).
        public var baseURL: String
        public var model: String
        public var apiKey: String?
        public var contextWindowTokens: Int
        public var maxOutputTokens: Int
        public var temperature: Double
        public var supportsVision: Bool
        public var supportsTools: Bool
        /// Image format sent to the model: "jpeg" or "png".
        public var imageFormat: String
        public var imageMaxWidth: Int
        public var requestTimeout: TimeInterval
        /// "openai" (any OpenAI-compatible endpoint at `baseURL`) or "chatgpt" (a ChatGPT account signed in through
        /// the Codex OAuth flow; `baseURL` and `apiKey` are ignored, credentials live in the host Keychain).
        public var provider: String

        public static let openAIProvider = "openai"
        public static let chatGPTProvider = "chatgpt"
        /// Apple's on-device model through the FoundationModels framework (macOS 26+). No sign-in, no vision.
        public static let appleProvider = "apple"
        public static let appleModelID = "apple-on-device"
        /// A deployment on an Azure AI Foundry (Azure OpenAI) resource, signed in with Entra ID or a key.
        public static let azureProvider = "azure"
        /// Which API-key preset `baseURL` came from, for display only (e.g. "openrouter"); nil for a typed URL.
        public var preset: String?
        /// How hard a reasoning model thinks: "low", "medium", "high" (nil: the provider's default). Sent as
        /// `reasoning.effort` to ChatGPT and `reasoning_effort` to OpenAI-compatible endpoints that take it.
        public var reasoningEffort: String?
        /// A shell command that prints a short-lived bearer token, used instead of `apiKey` (e.g.
        /// `az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv`
        /// for Azure AI Foundry with Microsoft Entra ID). Pennant caches the token and runs it again when it nears
        /// expiry or the endpoint refuses it.
        public var apiKeyCommand: String?
        /// The Vault entry that holds the key (its secret, else its password), used instead of `apiKey` so the key
        /// never sits in this file. The host reads it for every request, so changing the entry takes effect at once.
        public var apiKeyVault: String?
        /// Azure AI Foundry: the resource's subscription, resource group and name, and how to sign in
        /// ("entra": Microsoft Entra ID through the Azure CLI on the host; "key": `apiKey`). `baseURL` is the
        /// resource's OpenAI v1 endpoint and `model` the deployment name.
        public var azure: Azure?
        /// Which OpenAI API to call on Azure: "chat" (Chat Completions) or "responses" (the Responses API). Nil: the
        /// Responses API for GPT-6 models (on Chat Completions they can't call tools while reasoning), else chat.
        public var api: String?
        public static let chatAPI = "chat", responsesAPI = "responses"

        /// Whether this profile goes through the Responses API.
        public var usesResponsesAPI: Bool {
            guard provider == Inference.azureProvider else { return false }
            if let api { return api == Inference.responsesAPI }
            return model.lowercased().hasPrefix("gpt-6")
        }

        public struct Azure: Hashable, Codable, Sendable {
            public var subscriptionID: String
            public var resourceGroup: String
            public var resource: String
            public var auth: String
            public static let entra = "entra", key = "key"
            public init(subscriptionID: String, resourceGroup: String, resource: String, auth: String = Azure.entra) {
                self.subscriptionID = subscriptionID
                self.resourceGroup = resourceGroup
                self.resource = resource
                self.auth = auth
            }
        }

        public init(baseURL: String = "http://localhost:11434/v1", model: String = "gemma4:e2b-it-qat", apiKey: String? = nil, contextWindowTokens: Int = 128_000, maxOutputTokens: Int = 4096, temperature: Double = 0.2, supportsVision: Bool = true, supportsTools: Bool = true, imageFormat: String = "jpeg", imageMaxWidth: Int = 1440, requestTimeout: TimeInterval = 300, provider: String = Inference.openAIProvider) {
            self.provider = provider
            self.preset = nil
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
            self.contextWindowTokens = contextWindowTokens
            self.maxOutputTokens = maxOutputTokens
            self.temperature = temperature
            self.supportsVision = supportsVision
            self.supportsTools = supportsTools
            self.imageFormat = imageFormat
            self.imageMaxWidth = imageMaxWidth
            self.requestTimeout = requestTimeout
        }

        private enum CodingKeys: String, CodingKey { case baseURL, model, apiKey, contextWindowTokens, maxOutputTokens, temperature, supportsVision, supportsTools, imageFormat, imageMaxWidth, requestTimeout, provider, preset, reasoningEffort, apiKeyCommand, apiKeyVault, azure, api }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Inference()
            baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
            contextWindowTokens = try c.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? d.contextWindowTokens
            maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? d.maxOutputTokens
            temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
            supportsVision = try c.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? d.supportsVision
            supportsTools = try c.decodeIfPresent(Bool.self, forKey: .supportsTools) ?? d.supportsTools
            imageFormat = try c.decodeIfPresent(String.self, forKey: .imageFormat) ?? d.imageFormat
            imageMaxWidth = try c.decodeIfPresent(Int.self, forKey: .imageMaxWidth) ?? d.imageMaxWidth
            requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? d.requestTimeout
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? Inference.openAIProvider
            preset = try c.decodeIfPresent(String.self, forKey: .preset)
            reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
            apiKeyCommand = try c.decodeIfPresent(String.self, forKey: .apiKeyCommand)
            apiKeyVault = try c.decodeIfPresent(String.self, forKey: .apiKeyVault)
            azure = try c.decodeIfPresent(Azure.self, forKey: .azure)
            api = try c.decodeIfPresent(String.self, forKey: .api)
        }
    }

    public struct Embeddings: Hashable, Codable, Sendable {
        public var enabled: Bool
        public var baseURL: String
        public var model: String
        public init(enabled: Bool = false, baseURL: String = "http://localhost:11434/v1", model: String = "embeddinggemma") {
            self.enabled = enabled
            self.baseURL = baseURL
            self.model = model
        }
    }

    public struct API: Hashable, Codable, Sendable {
        public var port: Int
        /// Bind to all interfaces (needed for the iPhone) or loopback only.
        public var listenOnNetwork: Bool
        public var advertiseBonjour: Bool
        /// The encrypted (TLS) port beside `port`; clients try it first. 0 picks any free port (tests).
        public var tlsPort: Int
        /// Remote access through a Cloudflare Tunnel protected by Cloudflare Access. Nil: off.
        public var edge: Edge?
        public init(port: Int = 7331, listenOnNetwork: Bool = true, advertiseBonjour: Bool = true, tlsPort: Int = 7332, edge: Edge? = nil) {
            self.port = port
            self.listenOnNetwork = listenOnNetwork
            self.advertiseBonjour = advertiseBonjour
            self.tlsPort = tlsPort
            self.edge = edge
        }

        /// A public hostname served by `cloudflared` on this Mac, behind Cloudflare Access (Entra ID or any identity
        /// provider Access has). The tunnel sends the app connection to `port` and the sign-in handoff to `httpPort`,
        /// both on loopback only. Every connection there must carry an Access token for `audience`, which also says
        /// who it is: the Pennant account with that email.
        public struct Edge: Hashable, Codable, Sendable {
            public var hostname: String
            /// The Zero Trust team domain, e.g. "acme.cloudflareaccess.com".
            public var teamDomain: String
            /// The Access application's AUD tag.
            public var audience: String
            public var port: Int
            public var httpPort: Int
            /// Emails allowed through, by domain; empty allows any the Access policy let in.
            public var allowedEmailDomains: [String]
            public init(hostname: String, teamDomain: String, audience: String, port: Int = 7333, httpPort: Int = 7334, allowedEmailDomains: [String] = []) {
                self.hostname = hostname; self.teamDomain = teamDomain; self.audience = audience
                self.port = port; self.httpPort = httpPort; self.allowedEmailDomains = allowedEmailDomains
            }
        }

        private enum CodingKeys: String, CodingKey { case port, listenOnNetwork, advertiseBonjour, tlsPort, edge }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 7331
            listenOnNetwork = try c.decodeIfPresent(Bool.self, forKey: .listenOnNetwork) ?? true
            advertiseBonjour = try c.decodeIfPresent(Bool.self, forKey: .advertiseBonjour) ?? true
            // Configs from before encryption get the encrypted port too.
            tlsPort = try c.decodeIfPresent(Int.self, forKey: .tlsPort) ?? 7332
            edge = try c.decodeIfPresent(Edge.self, forKey: .edge)
        }
    }

    public struct Desktop: Hashable, Codable, Sendable {
        public var pauseOnHumanInput: Bool
        /// Seconds of human inactivity before a paused agent may resume automatically. 0 disables auto-resume.
        public var autoResumeAfterSeconds: Double
        public var screenshotMaxWidth: Int
        public var actionDelayMilliseconds: Int
        public init(pauseOnHumanInput: Bool = true, autoResumeAfterSeconds: Double = 0, screenshotMaxWidth: Int = 1440, actionDelayMilliseconds: Int = 120) {
            self.pauseOnHumanInput = pauseOnHumanInput
            self.autoResumeAfterSeconds = autoResumeAfterSeconds
            self.screenshotMaxWidth = screenshotMaxWidth
            self.actionDelayMilliseconds = actionDelayMilliseconds
        }
    }

    public struct Compaction: Hashable, Codable, Sendable {
        /// Fraction of the context window at which a checkpoint and compaction are triggered.
        public var triggerFraction: Double
        /// Absolute context size (tokens) that also triggers compaction, whichever comes first with the fraction.
        /// Long-context models degrade well before their window is full; zero disables this cap.
        public var triggerTokens: Int
        /// Fraction reserved so the checkpoint itself can be produced.
        public var reserveFraction: Double
        /// Number of most recent messages kept verbatim after compaction.
        public var keepRecentMessages: Int
        public init(triggerFraction: Double = 0.75, triggerTokens: Int = 128_000, reserveFraction: Double = 0.15, keepRecentMessages: Int = 8) {
            self.triggerFraction = triggerFraction
            self.triggerTokens = triggerTokens
            self.reserveFraction = reserveFraction
            self.keepRecentMessages = keepRecentMessages
        }

        /// The context size at which compaction runs for a given window: the smaller of the fraction and the cap.
        public func threshold(window: Int) -> Int {
            let byFraction = Int(Double(window) * triggerFraction)
            return triggerTokens > 0 ? min(byFraction, triggerTokens) : byFraction
        }

        private enum CodingKeys: String, CodingKey { case triggerFraction, triggerTokens, reserveFraction, keepRecentMessages }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            triggerFraction = try c.decodeIfPresent(Double.self, forKey: .triggerFraction) ?? 0.75
            triggerTokens = try c.decodeIfPresent(Int.self, forKey: .triggerTokens) ?? 128_000
            reserveFraction = try c.decodeIfPresent(Double.self, forKey: .reserveFraction) ?? 0.15
            keepRecentMessages = try c.decodeIfPresent(Int.self, forKey: .keepRecentMessages) ?? 8
        }
    }

    public var mode: DeploymentMode
    public var inference: Inference
    /// Named inference setups the user saved (provider, endpoint, key, model, window), switchable in one click.
    public var inferenceProfiles: [InferenceProfile]
    /// The model profile agents use unless they pick their own. `inference` mirrors it, so the host's own calls
    /// (titles, memory, compaction) run on it too.
    public var defaultProfileID: String?
    /// Profiles a task moves to, in order, when its model refuses the request (a missing deployment, a revoked
    /// key, a used-up quota). The default model comes after these.
    public var fallbackProfileIDs: [String]
    /// The model delegated workers run on (mechanical, well-specified work); nil: the default model.
    public var workerProfileID: String?
    /// The first fallback (older configs kept one).
    public var fallbackProfileID: String? {
        get { fallbackProfileIDs.first }
        set { fallbackProfileIDs = newValue.map { [$0] } ?? [] }
    }
    /// The "How to work" rules in every agent's system prompt; nil uses `HouseRules.default`.
    public var houseRules: String?
    public var embeddings: Embeddings
    public var api: API
    public var desktop: Desktop
    public var compaction: Compaction
    public var mcpServers: [MCPServerConfig]
    public var defaultBudget: TaskBudget
    /// Shell commands are run with this working directory unless the tool call specifies one.
    public var workingDirectory: String
    /// Close conversations with nothing new for this many days, once a day (closed ones can be reopened). Nil: never.
    public var autoCloseIdleDays: Int?
    /// How the agent writes code: it hands a change to a coding engine, which works in one of the project folders and
    /// acts on GitHub as its own App. Nil: coding isn't set up.
    public var coding: Coding?
    /// Pennant waking up on its own to look over its work.
    public var heartbeat = Heartbeat()
    /// Pennant asks on a card before it first uses a site in the owner's Chrome. Off: it uses any site; sending,
    /// publishing, deleting and paying still stop for the owner's OK.
    public var chromeAsksForNewSites = false
    /// Claude Code's skills (the owner's own and their enabled plugins') linked into Pennant and kept in step with
    /// the files. Off: Pennant has only its own skills.
    public var claudeCodeSkills = false

    /// Every so often the host looks over Pennant's work without the model: it starts the goal sessions that are due
    /// (goals need no schedules of their own) and, when something needs a look (work that stopped moving, a question
    /// left for hours, or something the owner asked for on each check-in), Pennant takes one turn in its chat to deal
    /// with it or tell the owner. A look with nothing in it costs nothing.
    public struct Heartbeat: Hashable, Codable, Sendable {
        public var enabled: Bool
        public var intervalMinutes: Int
        /// The most turns Pennant takes on heartbeats in a day.
        public var maxTurnsPerDay: Int
        /// What Pennant also does on each beat, in the owner's words ("Check my email for anything that needs me
        /// today"), with whatever tools it has. Empty: a beat only looks over Pennant's own work. Something here makes
        /// every beat a turn of the model.
        public var instructions: String?

        public init(enabled: Bool = true, intervalMinutes: Int = 30, maxTurnsPerDay: Int = 48) {
            self.enabled = enabled
            self.intervalMinutes = intervalMinutes
            self.maxTurnsPerDay = maxTurnsPerDay
        }
    }

    public struct Coding: Hashable, Codable, Sendable {
        public var engine: CodingEngine
        /// The folders coding runs work in, by name; the first is where a request that names none goes.
        public var projects: [CodingProject]
        /// The Settings › Models profile the Pennant engine runs on; nil: the host's default model. (Claude Code runs
        /// its own models.)
        public var modelProfileID: String?
        /// Standing instructions for every coding run (house style, how to branch, what never to touch).
        public var instructions: String
        /// The GitHub App coding runs commit, push and open pull requests as; nil: they don't push.
        public var gitHubApp: GitHubAppIdentity?
        /// How a new coding run asks before acting; nil: only the owner's sign-offs ask (`acceptEdits`). With `manual`,
        /// every run asks for everything, whatever the request says.
        public var mode: CodingMode?

        public init(engine: CodingEngine = .claudeCode, projects: [CodingProject] = [], modelProfileID: String? = nil, instructions: String = "", gitHubApp: GitHubAppIdentity? = nil, mode: CodingMode? = nil) {
            self.engine = engine; self.projects = projects; self.modelProfileID = modelProfileID
            self.instructions = instructions; self.gitHubApp = gitHubApp; self.mode = mode
        }

        /// The mode a new run starts in: the one asked for, except that "Ask for everything" can't be loosened.
        public func mode(asked: CodingMode?) -> CodingMode? {
            mode == .manual ? .manual : asked ?? mode
        }

        /// Where a request that names no project goes.
        public var defaultProject: CodingProject? { projects.first }

        /// A project by name, ignoring case.
        public func project(named name: String) -> CodingProject? {
            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return projects.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        }

        /// Adds a folder as a project, named `name` or after the folder, first when `asDefault`. A folder that is
        /// already a project keeps its place and name unless asked otherwise.
        public mutating func addProject(path: String, name: String? = nil, asDefault: Bool) {
            let given = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let i = projects.firstIndex(where: { $0.path == path }) {
                if let given { projects[i].name = uniqueName(given, except: path) }
                if asDefault { projects.insert(projects.remove(at: i), at: 0) }
                return
            }
            let project = CodingProject(name: uniqueName(given ?? CodingProject.folderName(path)), path: path)
            if asDefault { projects.insert(project, at: 0) } else { projects.append(project) }
        }

        /// `wanted`, or "wanted 2", "wanted 3"… when another project (not the one at `path`) has that name: the code
        /// tool finds projects by name.
        public func uniqueName(_ wanted: String, except path: String? = nil) -> String {
            let taken = Set(projects.filter { $0.path != path }.map { $0.name.lowercased() })
            var name = wanted, n = 2
            while taken.contains(name.lowercased()) { name = "\(wanted) \(n)"; n += 1 }
            return name
        }

        private enum CodingKeys: String, CodingKey { case engine, projects, workingDirectory, modelProfileID, instructions, gitHubApp, mode }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            engine = try c.decode(CodingEngine.self, forKey: .engine)
            // Configs from before several projects had one folder: it becomes the only (and default) project.
            if let projects = try c.decodeIfPresent([CodingProject].self, forKey: .projects) {
                self.projects = projects
            } else {
                self.projects = try c.decodeIfPresent(String.self, forKey: .workingDirectory).map { [CodingProject(path: $0)] } ?? []
            }
            modelProfileID = try c.decodeIfPresent(String.self, forKey: .modelProfileID)
            instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
            gitHubApp = try c.decodeIfPresent(GitHubAppIdentity.self, forKey: .gitHubApp)
            mode = try c.decodeIfPresent(CodingMode.self, forKey: .mode)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(engine, forKey: .engine)
            try c.encode(projects, forKey: .projects)
            try c.encodeIfPresent(modelProfileID, forKey: .modelProfileID)
            try c.encode(instructions, forKey: .instructions)
            try c.encodeIfPresent(gitHubApp, forKey: .gitHubApp)
            try c.encodeIfPresent(mode, forKey: .mode)
        }
    }

    public init(mode: DeploymentMode = .everyday, inference: Inference = Inference(), inferenceProfiles: [InferenceProfile] = [], embeddings: Embeddings = Embeddings(), api: API = API(), desktop: Desktop = Desktop(), compaction: Compaction = Compaction(), mcpServers: [MCPServerConfig] = [], defaultBudget: TaskBudget = TaskBudget(), workingDirectory: String = NSHomeDirectory()) {
        self.mode = mode
        self.inference = inference
        self.inferenceProfiles = inferenceProfiles
        self.defaultProfileID = nil
        self.fallbackProfileIDs = []
        self.workerProfileID = nil
        self.houseRules = nil
        self.embeddings = embeddings
        self.api = api
        self.desktop = desktop
        self.compaction = compaction
        self.mcpServers = mcpServers
        self.defaultBudget = defaultBudget
        self.workingDirectory = workingDirectory
    }

    private enum CodingKeys: String, CodingKey { case mode, inference, inferenceProfiles, defaultProfileID, fallbackProfileIDs, fallbackProfileID, workerProfileID, houseRules, embeddings, api, desktop, compaction, mcpServers, defaultBudget, workingDirectory, autoCloseIdleDays, coding, heartbeat, chromeAsksForNewSites, claudeCodeSkills }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(DeploymentMode.self, forKey: .mode)
        inference = try c.decode(Inference.self, forKey: .inference)
        // Configs written before profiles existed have none.
        inferenceProfiles = try c.decodeIfPresent([InferenceProfile].self, forKey: .inferenceProfiles) ?? []
        defaultProfileID = try c.decodeIfPresent(String.self, forKey: .defaultProfileID)
        fallbackProfileIDs = try c.decodeIfPresent([String].self, forKey: .fallbackProfileIDs)
            ?? (try c.decodeIfPresent(String.self, forKey: .fallbackProfileID)).map { [$0] } ?? []
        workerProfileID = try c.decodeIfPresent(String.self, forKey: .workerProfileID)
        houseRules = try c.decodeIfPresent(String.self, forKey: .houseRules)
        embeddings = try c.decode(Embeddings.self, forKey: .embeddings)
        api = try c.decode(API.self, forKey: .api)
        desktop = try c.decode(Desktop.self, forKey: .desktop)
        compaction = try c.decode(Compaction.self, forKey: .compaction)
        mcpServers = try c.decode([MCPServerConfig].self, forKey: .mcpServers)
        defaultBudget = try c.decode(TaskBudget.self, forKey: .defaultBudget)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        autoCloseIdleDays = try c.decodeIfPresent(Int.self, forKey: .autoCloseIdleDays)
        coding = try c.decodeIfPresent(Coding.self, forKey: .coding)
        heartbeat = try c.decodeIfPresent(Heartbeat.self, forKey: .heartbeat) ?? Heartbeat()
        chromeAsksForNewSites = try c.decodeIfPresent(Bool.self, forKey: .chromeAsksForNewSites) ?? false
        claudeCodeSkills = try c.decodeIfPresent(Bool.self, forKey: .claudeCodeSkills) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(inference, forKey: .inference)
        try c.encode(inferenceProfiles, forKey: .inferenceProfiles)
        try c.encodeIfPresent(defaultProfileID, forKey: .defaultProfileID)
        try c.encode(fallbackProfileIDs, forKey: .fallbackProfileIDs)
        try c.encodeIfPresent(workerProfileID, forKey: .workerProfileID)
        try c.encodeIfPresent(houseRules, forKey: .houseRules)
        try c.encode(embeddings, forKey: .embeddings)
        try c.encode(api, forKey: .api)
        try c.encode(desktop, forKey: .desktop)
        try c.encode(compaction, forKey: .compaction)
        try c.encode(mcpServers, forKey: .mcpServers)
        try c.encode(defaultBudget, forKey: .defaultBudget)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(autoCloseIdleDays, forKey: .autoCloseIdleDays)
        try c.encodeIfPresent(coding, forKey: .coding)
        try c.encode(heartbeat, forKey: .heartbeat)
        try c.encode(chromeAsksForNewSites, forKey: .chromeAsksForNewSites)
        try c.encode(claudeCodeSkills, forKey: .claudeCodeSkills)
    }

    // MARK: Models

    public func profile(_ id: String?) -> InferenceProfile? {
        guard let id else { return nil }
        return inferenceProfiles.first { $0.id == id }
    }

    /// A profile by id, else by name (any case): what someone typed or a model was asked for by.
    /// A profile by its id, its name, or the model as its provider names it ("gpt-6-sol").
    public func profile(matching idOrName: String?) -> InferenceProfile? {
        guard let key = idOrName?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return profile(key) ?? inferenceProfiles.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
            ?? inferenceProfiles.first { $0.inference.model.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// The default model's profile.
    public var defaultProfile: InferenceProfile? { profile(defaultProfileID) }

    /// Brings `self` (a config a client sent) in line with the model rules: the default profile drives `inference`.
    /// An `inference` edited on its own is overwritten, never copied into a profile. A client's stale copy (an earlier
    /// model, sent along with a new default) once rewrote the default profile that way: "DeepSeek" ran a small local
    /// model under DeepSeek's name.
    public mutating func reconcileModels() {
        normalizeModels()
    }

    /// Makes every setup a profile: an older config's single `inference` becomes a profile and the default, and
    /// `inference` is kept equal to the default profile. Returns whether anything changed.
    @discardableResult
    public mutating func normalizeModels() -> Bool {
        let before = self
        if defaultProfile == nil {
            if let match = inferenceProfiles.first(where: { $0.matches(inference) }) {
                defaultProfileID = match.id
            } else {
                let p = InferenceProfile(inference: inference)
                inferenceProfiles.insert(p, at: 0)
                defaultProfileID = p.id
            }
        }
        if let d = defaultProfile { inference = d.inference }
        let ids = Set(inferenceProfiles.map(\.id))
        var seen = Set<String>()
        fallbackProfileIDs = fallbackProfileIDs.filter { ids.contains($0) && $0 != defaultProfileID && seen.insert($0).inserted }
        if let w = workerProfileID, !ids.contains(w) { workerProfileID = nil }
        return before != self
    }
}

/// A folder coding runs work in, under the short name the owner and Pennant call it by.
public struct CodingProject: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    /// The folder's absolute path on the host.
    public var path: String
    public var id: String { path }

    /// A project named after its folder unless a name is given.
    public init(name: String? = nil, path: String) {
        self.path = path
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Self.folderName(path)
    }

    /// "/Users/maya/code/harbor-web" → "harbor-web".
    public static func folderName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? path : last
    }
}

/// A saved inference setup: everything the host needs to run one model (provider, endpoint, key, model,
/// window, output cap, capability flags). Applying one replaces `HostConfig.inference` whole.
public struct InferenceProfile: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var inference: HostConfig.Inference
    /// What its tokens cost, for the usage dashboard. Nil: unknown (tokens are still counted).
    public var pricing: ModelPricing?

    public init(id: String = UUID().uuidString, inference: HostConfig.Inference, pricing: ModelPricing? = nil) {
        self.id = id
        self.inference = inference
        self.pricing = pricing
    }

    /// What it's called everywhere: the model as its provider names it, where it runs, and how hard it thinks when
    /// that's set ("DeepSeek-V4.1-Flash · Azure my-ai-resource · medium"). Never typed in: a name kept apart from
    /// the settings once said one model while the settings ran another.
    public var name: String {
        let base = Self.suggestedName(for: inference)
        return inference.reasoningEffort.map { "\(base) · \($0)" } ?? base
    }

    private enum CodingKeys: String, CodingKey { case id, name, inference, pricing }

    /// A name stored by an older version is ignored: it's worked out from the settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        inference = try c.decode(HostConfig.Inference.self, forKey: .inference)
        pricing = try c.decodeIfPresent(ModelPricing.self, forKey: .pricing)
    }

    /// The name goes out too, for apps from before it was worked out.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(inference, forKey: .inference)
        try c.encodeIfPresent(pricing, forKey: .pricing)
    }

    /// The prices to bill with: the ones set, else "included" for subscription accounts and local models.
    public var effectivePricing: ModelPricing? {
        if let pricing { return pricing }
        switch inference.provider {
        case HostConfig.Inference.chatGPTProvider, HostConfig.Inference.appleProvider:
            return ModelPricing(included: true)
        default:
            return nil
        }
    }

    /// Whether `other` runs the same model the same way: provider, model, and (for an endpoint) base URL.
    public func matches(_ other: HostConfig.Inference) -> Bool {
        guard inference.provider == other.provider, inference.model == other.model else { return false }
        if inference.provider == HostConfig.Inference.openAIProvider || inference.provider == HostConfig.Inference.azureProvider {
            return Self.normalized(inference.baseURL) == Self.normalized(other.baseURL)
        }
        return true
    }

    /// "qwen3.8 · 192.0.2.10", "ChatGPT · gpt-5.6-sol", "Apple on-device".
    public static func suggestedName(for inference: HostConfig.Inference) -> String {
        switch inference.provider {
        case HostConfig.Inference.chatGPTProvider: return "ChatGPT · \(inference.model)"
        case HostConfig.Inference.appleProvider: return "Apple on-device"
        case HostConfig.Inference.azureProvider: return "\(inference.model) · Azure \(inference.azure?.resource ?? "")".trimmingCharacters(in: .whitespaces)
        default:
            let url = inference.baseURL.trimmingCharacters(in: .whitespaces)
            let place = InferencePresets.preset(for: url)?.name ?? URL(string: url)?.host ?? url
            return place.isEmpty ? inference.model : "\(inference.model) · \(place)"
        }
    }

    private static func normalized(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespaces).lowercased()
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}

// MARK: - Azure AI Foundry (read through the Azure CLI on the host)

public struct AzureStatus: Hashable, Codable, Sendable {
    public var installed: Bool
    public var cliPath: String?
    public var signedIn: Bool
    public var user: String?
    public var subscriptionID: String?
    public var subscriptionName: String?
    public var tenantID: String?
    public init(installed: Bool, cliPath: String? = nil, signedIn: Bool = false, user: String? = nil, subscriptionID: String? = nil, subscriptionName: String? = nil, tenantID: String? = nil) {
        self.installed = installed; self.cliPath = cliPath; self.signedIn = signedIn; self.user = user
        self.subscriptionID = subscriptionID; self.subscriptionName = subscriptionName; self.tenantID = tenantID
    }
}

public struct AzureSubscription: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    public init(id: String, name: String, isDefault: Bool) { self.id = id; self.name = name; self.isDefault = isDefault }
}

public struct AzureResource: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(subscriptionID)/\(resourceGroup)/\(name)" }
    public var name: String
    public var resourceGroup: String
    public var subscriptionID: String
    public var kind: String
    public var location: String
    public var endpoint: String
    /// False when the resource only takes traffic through a private endpoint (a VPN or WARP is needed).
    public var publicNetworkAccess: Bool
    /// True when keys are turned off (Entra ID sign-in only).
    public var keysDisabled: Bool
    public init(name: String, resourceGroup: String, subscriptionID: String, kind: String, location: String, endpoint: String, publicNetworkAccess: Bool, keysDisabled: Bool) {
        self.name = name; self.resourceGroup = resourceGroup; self.subscriptionID = subscriptionID; self.kind = kind
        self.location = location; self.endpoint = endpoint; self.publicNetworkAccess = publicNetworkAccess; self.keysDisabled = keysDisabled
    }
}

public struct AzureDeployment: Hashable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var model: String
    public var version: String
    public var format: String
    public init(name: String, model: String, version: String, format: String) { self.name = name; self.model = model; self.version = version; self.format = format }
}

/// The result of sending a model one short prompt.
public struct ModelTestResult: Hashable, Codable, Sendable {
    public var ok: Bool
    public var detail: String
    public var milliseconds: Int
    /// Whether the model read a test picture: nil when that wasn't checked (the text test failed, or the provider
    /// has no way to send images).
    public var vision: Bool?
    public init(ok: Bool, detail: String, milliseconds: Int, vision: Bool? = nil) { self.ok = ok; self.detail = detail; self.milliseconds = milliseconds; self.vision = vision }
}
