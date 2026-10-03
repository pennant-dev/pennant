import PennantCore
import Foundation

/// Composes the host: storage, inference, desktop, tools, runtime, MCP, and the API server.
/// Implements the API delegate so clients talk to one object.
public actor HostService: HostAPIDelegate {
    /// The name clients show for this host: the Mac's, or PENNANT_HOST_NAME (the demo host uses a fictional one).
    private var tidyTask: Task<Void, Never>?
    private var pushWatch: Task<Void, Never>?

    /// Turns "needs you" events into iPhone notifications: a pending approval card, a choice question, a task that
    /// stopped to ask something, and the result of a thread the Pennant chat started. Each goes once, to the person
    /// who started the work (following hand-offs between agents), else to the owners, and opens the Pennant chat,
    /// where all of it shows up.
    private func watchForPush() async {
        for await event in await eventBus.subscribe() {
            if Task.isCancelled { return }
            let chat = await runtime.mainChatID
            switch event.payload {
            case .messageAppended(let m), .messageFinalized(let m):
                guard m.role == .assistant, !m.isStreaming else { continue }
                let name = (try? await store.agent(m.agentID))?.name ?? "An agent"
                let opens = (chat ?? m.conversationID).rawValue
                for part in m.parts {
                    switch part {
                    case .approval(let a) where a.state == .pending:
                        let who = await pushRecipients(conversationID: m.conversationID, taskID: m.taskID)
                        await push.notify(title: "\(name) needs your approval", body: a.title, to: who, key: "approval:\(a.id)",
                                          info: ["agentID": m.agentID.rawValue, "conversationID": opens], thread: opens)
                    case .choices(let q) where q.answers == nil:
                        let who = await pushRecipients(conversationID: m.conversationID, taskID: m.taskID)
                        await push.notify(title: "\(name) asks", body: q.items.first?.question ?? "A question for you", to: who, key: "choices:\(q.id)",
                                          info: ["agentID": m.agentID.rawValue, "conversationID": opens], thread: opens)
                    case .update(let u) where m.conversationID == chat:
                        let thread = (try? await store.conversation(u.threadID)) ?? nil
                        switch u.kind {
                        case .question:
                            // A coding run's choice card notifies on its own.
                            if thread?.isCodingRun == true { continue }
                            let who = await pushRecipients(conversationID: u.threadID, taskID: u.taskID)
                            // Pennant's own words when it asked, else the thread's.
                            let asked = m.text.isEmpty ? u.text : m.text
                            await push.notify(title: "\(name) asks", body: Conversation.previewLine(asked, limit: 240), to: who, key: "update:\(u.id)",
                                              info: ["agentID": m.agentID.rawValue, "conversationID": opens], thread: opens)
                        case .finished, .failed:
                            // What Pennant chose to tell them, in its words; nothing when it kept it to itself. Without
                            // its words, only a failure of work the chat asked for.
                            if u.silent == true { continue }
                            if m.text.isEmpty, u.kind == .finished || thread?.parentID != chat { continue }
                            let who = await pushRecipients(conversationID: u.threadID, taskID: u.taskID)
                            await push.notify(title: name, body: Conversation.previewLine(m.text.isEmpty ? u.text : m.text, limit: 240),
                                              to: who, key: "update:\(u.id)", info: ["agentID": m.agentID.rawValue, "conversationID": opens], thread: opens)
                        case .approval:
                            continue
                        }
                    default: continue
                    }
                }
            case .taskTransition(let t) where t.to == .completed:
                // Pennant mentioned something on its own (a heartbeat): that reaches the phone too.
                guard let task = try? await store.task(t.taskID), TaskRuntime.isHeartbeat(task),
                      let said = task.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty, !TaskRuntime.saysNothing(said) else { continue }
                let name = (try? await store.agent(task.agentID))?.name ?? "Pennant"
                let who = await pushRecipients(conversationID: task.conversationID, taskID: task.id)
                await push.notify(title: name, body: Conversation.previewLine(said, limit: 240), to: who, key: "heartbeat:\(task.id.rawValue)",
                                  info: ["agentID": task.agentID.rawValue, "conversationID": task.conversationID.rawValue], thread: task.conversationID.rawValue)
            case .taskTransition(let t) where t.to == .waitingForUser:
                guard let task = try? await store.task(t.taskID) else { continue }
                let reason = task.stateReason
                // Approval cards and choice questions notify on their own, with their content; a thread's other stops
                // reach the chat as a question update, which notifies.
                if reason.hasPrefix("Waiting for your approval") || reason.hasPrefix("Waiting for your answer") || reason.isEmpty { continue }
                if chat != nil, task.conversationID != chat { continue }
                let name = (try? await store.agent(task.agentID))?.name ?? "An agent"
                let who = await pushRecipients(conversationID: task.conversationID, taskID: task.id)
                await push.notify(title: "\(name) needs you", body: String(reason.prefix(240)), to: who, key: "ask:\(task.id.rawValue):\(reason.hashValue)",
                                  info: ["agentID": task.agentID.rawValue, "conversationID": task.conversationID.rawValue], thread: task.conversationID.rawValue)
            default:
                continue
            }
        }
    }

    /// Who a conversation's news is for: the last person who wrote in it; for work another agent asked for, the
    /// person behind that request; failing both, the owners.
    private func pushRecipients(conversationID: ConversationID, taskID: TaskID?) async -> [PersonID] {
        var conversation = conversationID
        var task = taskID
        for _ in 0 ..< 4 {
            let recent = (try? await store.listMessages(conversationID: conversation, before: nil, limit: 80)) ?? []
            if let author = recent.last(where: { $0.role == .user && $0.author != nil })?.author { return [author.id] }
            guard let t = task, let record = try? await store.task(t), let origin = record.requestedByTaskID, let asked = try? await store.task(origin) else { break }
            conversation = asked.conversationID
            task = asked.id
        }
        return await people.snapshot().people.filter { $0.role == .owner }.map(\.id)
    }

    /// Closes conversations idle for longer than `config.autoCloseIdleDays`, when set.
    func autoCloseIdleConversations() async {
        guard let days = config.autoCloseIdleDays, days > 0 else { return }
        do {
            let goalThreads = Set(try await goals.list().filter { $0.status == .active }.compactMap(\.conversationID))
            let n = try await runtime.pruneConversations(idleDays: days, keep: goalThreads)
            if n > 0 { log.info("Closed \(n) conversation(s) idle for \(days)+ days", category: "host") }
        } catch { log.error("Auto tidy failed: \(error)", category: "host") }
    }

    static var displayName: String {
        if let name = ProcessInfo.processInfo.environment["PENNANT_HOST_NAME"], !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    public let paths: HostPaths
    public internal(set) var config: HostConfig
    public let store: SQLiteStore
    public let eventBus: EventBus
    public let switchableProvider: SwitchableProvider
    public var provider: any InferenceProvider { switchableProvider }
    public let desktop: any DesktopControlling
    public let humanInput: any HumanInputObserving
    public let lease: DesktopLease
    public let broker: ToolBroker
    public let memory: MemoryService
    /// Telegram, iMessage and Teams: reaching people outside Pennant.
    public let channels: ChannelService
    /// Pull request approvals from chats, posted on GitHub as whoever approved.
    public let reviews: ReviewService
    public let skillTracker: SkillUsageTracker
    /// Teach mode: records a demonstration for drafting into a skill.
    public let teaching: TeachingService
    /// Playwright with Pennant's own browser profile, for render_html and browser_script.
    public let browserRunner: BrowserRunner
    /// Brand files the user uploads for agents to use.
    public let library: LibraryService
    /// Sign-ins and secrets that scripts use without the model seeing them.
    public let vault: VaultService
    public let runtime: TaskRuntime
    public let mcp: MCPManager
    public let chatGPT: ChatGPTAuthManager
    public let scheduler: Scheduler
    /// Pennant waking up on its own to look over its work (and start goal sessions).
    public let heartbeat: Heartbeat
    /// Pennant's extension in the owner's Chrome, and the sites they let it work on there.
    public let chrome: BrowserLink
    public let chromeSites: ChromeSites
    public let goals: GoalService
    public let devices: DeviceTokens
    /// Teammates who sign in with Microsoft, Google or GitHub, and who may join.
    public let people: PeopleService
    public let push: PushService
    var api: HostAPIServer?
    /// The host's certificate for the encrypted port.
    private var tls: HostTLSIdentity?
    /// This Mac on Tailscale, refreshed every few minutes: part of `addresses` for phones.
    private var tailscale: TailscaleSelf.Info?
    private let startedAt = Date()
    var clients: [ConnectedClient] = []
    var streamingClients = 0
    private var inferenceReachable = false
    private var monitors: [Task<Void, Never>] = []
    private var desktopWasBlocked = false
    private let statusRelay = StatusRelay()
    private var permissionsCache: (value: DesktopPermissions, at: Date)?
    private var restartScheduled = false
    let accessVerifier = CloudflareAccessVerifier()
    let edgeHTTP = WebhookServer()
    /// Called when the host must restart to pick up a grant. Defaults to exiting; the app or launchd starts it again.
    public var restartHandler: @Sendable () async -> Void = {
        log.info("Exiting so the launcher restarts the host with the new permissions", category: "host")
        exit(0)
    }

    public init(paths: HostPaths, config: HostConfig, desktop: (any DesktopControlling)? = nil, humanInput: (any HumanInputObserving)? = nil, provider: (any InferenceProvider)? = nil) throws {
        self.paths = paths
        self.config = config
        try paths.ensureDirectories()
        self.store = try SQLiteStore(paths: paths)
        self.eventBus = EventBus()
        let chatGPTAuth = ChatGPTAuthManager(credentials: KeychainCredentialStore(keychain: KeychainStore.host(service: "dev.pennant.host.chatgpt", fallbackFileURL: paths.root.appendingPathComponent("chatgpt-credentials.json"))))
        self.chatGPT = chatGPTAuth
        let vaultService = VaultService(store: store, keychain: KeychainStore.host(service: "dev.pennant.host.vault", fallbackFileURL: paths.root.appendingPathComponent("vault-fallback.json")))
        self.vault = vaultService
        self.switchableProvider = SwitchableProvider(provider ?? HostService.makeProvider(config.inference, chatGPT: chatGPTAuth, vault: vaultService))
        let desktopImpl = desktop ?? DesktopController(config: config.desktop)
        self.desktop = desktopImpl
        self.humanInput = humanInput ?? HumanInputMonitor()
        let relay = statusRelay
        self.lease = DesktopLease(pauseOnHumanInput: config.desktop.pauseOnHumanInput, desktop: desktopImpl, onChange: { _ in await relay.fire() })
        self.broker = ToolBroker()
        let embeddings: (any EmbeddingProvider)? = config.embeddings.enabled ? OpenAIEmbeddingProvider(config: config.embeddings) : nil
        self.memory = MemoryService(store: store, eventBus: eventBus, embeddings: embeddings)
        self.skillTracker = SkillUsageTracker()
        self.browserRunner = BrowserRunner(root: paths.root.appendingPathComponent("browser", isDirectory: true))
        self.library = LibraryService(root: paths.root.appendingPathComponent("library", isDirectory: true), store: store)
        self.channels = ChannelService(paths: paths, keychain: KeychainStore.host(service: "dev.pennant.host.channels", fallbackFileURL: paths.root.appendingPathComponent("channels-secrets.json")),
                                       store: store, eventBus: eventBus)
        self.reviews = ReviewService(paths: paths, keychain: KeychainStore.host(service: "dev.pennant.host.reviews", fallbackFileURL: paths.root.appendingPathComponent("reviews-secrets.json")))
        let teachingBus = eventBus
        self.teaching = TeachingService(publish: { session in
            await teachingBus.publish(HostEvent(seq: 0, payload: .teachingUpdated(session)))
        }, fileURL: paths.root.appendingPathComponent("teaching-session.json"))
        var runtimeDeps = TaskRuntime.Dependencies(store: store, eventBus: eventBus, provider: switchableProvider, broker: broker, desktop: desktopImpl, lease: lease, memory: memory, skillTracker: skillTracker, config: config)
        let router = ProviderCache(chatGPT: chatGPTAuth, vault: vaultService)
        runtimeDeps.makeProvider = { inference in await router.provider(for: inference) }
        runtimeDeps.dataRoot = paths.root
        let sharedChats = channels
        // The goal service needs the scheduler, which needs the runtime: it's filled in once made.
        let goalBox = Locked<GoalService?>(nil)
        let cursorDesktop = desktopImpl
        let chromeLink = BrowserLink { x, y, click in await cursorDesktop.showCursor(x: x, y: y, click: click) }
        runtimeDeps.chromeConnected = { await chromeLink.currentStatus().connected }
        runtimeDeps.goalFreedom = { taskID in await goalBox.get()?.freedom(forTask: taskID) }
        runtimeDeps.goals = { (try? await goalBox.get()?.list()) ?? [] }
        let vaultForGitHub = vault
        runtimeDeps.gitHubEnvironment = { identity in try await HostService.gitHubEnvironment(for: identity, vault: vaultForGitHub) }
        let lookupBroker = broker
        let lookupStore = store
        let lookupDesktop = desktopImpl
        let lookupLease = lease
        let lookupConfig = config
        runtimeDeps.routeTeamsSend = { tool, arguments, agentID, conversationID in
            await sharedChats.routeTeamsSend(tool: tool, arguments: arguments, agentID: agentID, conversationID: conversationID) { email in
                // The connector's directory lookup: same service, people_lookup.
                let name = tool.replacingOccurrences(of: "__teams_message_person", with: "__people_lookup")
                guard let lookup = await lookupBroker.tool(named: name) else { return nil }
                let context = ToolContext(agentID: agentID, taskID: TaskID(), conversationID: conversationID, store: lookupStore, desktop: lookupDesktop, lease: lookupLease, config: lookupConfig)
                guard let result = try? await lookup.invoke(["email": .string(email)], context: context), !result.isError,
                      let json = (try? JSONSerialization.jsonObject(with: Data(result.textContent.utf8))) as? [String: Any],
                      let id = json["id"] as? String, !id.isEmpty else { return nil }
                return (id, json["name"] as? String ?? email)
            }
        }
        self.runtime = TaskRuntime(runtimeDeps)
        self.scheduler = Scheduler(store: store, eventBus: eventBus, runtime: runtime)
        self.heartbeat = Heartbeat(runtime: runtime, scheduler: scheduler, settings: config.heartbeat)
        self.chrome = chromeLink
        self.chromeSites = ChromeSites(folder: paths.root)
        let goalStore = store
        let goalBus = eventBus
        self.goals = GoalService(store: store, scheduler: scheduler, publish: { payload in
            if let event = try? await goalStore.appendEvent(payload) { await goalBus.publish(event) }
        })
        goalBox.set(goals)
        // Only the host's own data folder uses the Keychain (see KeychainStore.host).
        self.devices = DeviceTokens(paths: paths, useFileFallback: !KeychainStore.isHostDataFolder(paths.root))
        self.people = PeopleService(paths: paths)
        self.push = PushService(paths: paths, keychain: KeychainStore.host(service: "dev.pennant.host.push", fallbackFileURL: paths.root.appendingPathComponent("push-credentials.json")))
        let keychain = KeychainStore.host(service: "dev.pennant.host.mcp", fallbackFileURL: paths.root.appendingPathComponent("mcp-credentials.json"))
        self.mcp = MCPManager(store: store, eventBus: eventBus, broker: broker, credentials: KeychainCredentialStore(keychain: keychain))
    }

    // MARK: Lifecycle

    public func start(startAPI: Bool = true) async throws {
        log.attachFile(at: paths.logURL.path)
        log.info("Pennant host \(PennantVersion.string) starting at \(paths.root.path)", category: "host")
        // Every model is a profile; an older config's single model becomes the default profile.
        if self.config.normalizeModels() { log.info("Models: the host's model is now the default profile", category: "host") }
        try ConfigLoader.save(self.config, to: paths.configURL)
        await runtime.updateConfig(self.config)

        // Write the local token first so a client that starts the host can connect as soon as the port opens.
        _ = await devices.localToken()
        await statusRelay.set { [weak self] in await self?.desktopLeaseChanged() }
        await broker.register([ShellTool(vault: vault), ReadFileTool(), WriteFileTool(), EditFileTool(), ListDirectoryTool(), FileShareTool(), OpenURLTool(), BrowserReadTool(headless: browserRunner), BrowserFillTool(),
                               MemorySearchTool(memory: memory), MemoryRememberTool(memory: memory), MemoryPreferenceTool(memory: memory),
                               LearnSkillTool(), FindSkillTool(), UseSkillTool(tracker: skillTracker),
                               DelegateTaskTool(), AwaitTaskTool(), AskUserTool(), StartThreadTool(), MessageThreadTool(), ReadThreadTool(), StopThreadTool(),
                               CodeTool(),
                               ScheduleJobTool(), ListSchedulesTool(), CancelScheduleTool(), ImportSkillsTool(),
                               RequestApprovalTool(), WritingCheckTool(),
                               RenderHTMLTool(browser: browserRunner), BrowserScriptTool(browser: browserRunner, screenshots: paths.root.appendingPathComponent("browser/screenshots", isDirectory: true), vault: vault),
                               FindAssetsTool(library: library), VaultListTool(vault: vault), PostReportTool(),
                               SendMessageTool(channels: channels), ChannelSendTool(channels: channels), ListContactsTool(channels: channels)])
        let ownerOf = people
        let theOwner: @Sendable () async -> Person? = { await ownerOf.snapshot().people.first { $0.role == .owner } }
        await broker.register([LinkReviewerTool(reviews: reviews, channels: channels, owner: theOwner),
                               RequestReviewsTool(reviews: reviews, channels: channels, owner: theOwner),
                               ApproveReviewBatchTool(reviews: reviews, owner: theOwner), ReviewStatusTool(reviews: reviews)])
        await broker.register(DesktopTools.all())
        // The health review's tools: only an agent the owner grants them to (`pennant health enable`) sees them.
        let sched = scheduler
        await broker.register(HealthTools(store: store, logURL: paths.logURL, schedules: { try await sched.list() },
                                          updateAgent: { [unowned self] in try await self.saveAgentProfile($0) },
                                          setSkillStatus: { [unowned self] in try await self.setSkillStatus($0, $1) }).tools)
        try await ensureDefaultAgent()
        // The Pennant chat: what every app opens on.
        _ = try? await runtime.ensureMainChat()
        await BuiltinSkills.seed(store: store, eventBus: eventBus)
        await runtime.attach(scheduler: scheduler)
        await chatGPT.setOnChange { [weak self] in await self?.chatGPTAccountChanged() }
        await humanInput.start()
        inferenceReachable = await provider.healthCheck()
        await runtime.start()
        let goalService = goals
        await scheduler.setGoalPrompt { id, run in try await goalService.runPrompt(id, run: run) }
        await broker.register(GoalTools.all(goals: goals, store: store))
        await scheduler.start()
        await heartbeat.start()
        if let source = ChromeExtension.bundled() {
            do {
                let copy = try ChromeExtension.install(from: source, into: paths.root)
                await chrome.setInstalled(folder: copy.folder, build: copy.build)
            } catch {
                log.warn("Couldn't copy the Chrome extension into the data folder: \(error)", category: "browser")
            }
        }
        await chrome.start()
        await broker.register(WebTools.all(link: chrome, sites: chromeSites))
        // Notifications: approvals, questions and choices reach the phones of whoever the work is for.
        pushWatch = Task { [weak self] in await self?.watchForPush() }
        // Tidy up once a day when the owner asked for it: idle conversations close (they can be reopened).
        tidyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.autoCloseIdleConversations()
                await self?.runtime.tendMemory()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
        if startAPI {
            let name = Self.displayName
            // Encrypted connections on the network; without a certificate the plain port still serves.
            do { tls = try HostTLSIdentity.loadOrCreate(root: paths.root, hostName: name) }
            catch { log.error("\(error)", category: "api") }
            let server = HostAPIServer(config: config.api, delegate: self, eventBus: eventBus, store: store, hostName: name, tls: tls)
            try await server.start()
            api = server
            await startEdgeHandoff()
        }
        startMonitors()
        await publishHostStatus()
        // MCP servers connect after the port is open: their handshakes can take seconds each and clients should
        // not wait on them. Tools register with the broker as each server comes up.
        let mcp = self.mcp
        Task.detached(priority: .utility) { await mcp.start() }
        // Channels: what people send arrives as messages from them; the built-in assistant takes new threads.
        let runtime = self.runtime, store = self.store
        // Reviews: batches post to chats; approvals there are heard first; the asking agent hears how it goes, with the
        // owner's authority (only a request the owner could make opens a batch: asking is a consequential tool).
        let reviews = self.reviews, chats = channels, reviewPeople = people
        await reviews.start(ReviewService.Dependencies(
            post: { contactID, text, buttons in try await chats.post(text, buttons: buttons, to: contactID) },
            notify: { agentID, conversationID, text in
                let owner = await reviewPeople.snapshot().people.first { $0.role == .owner }
                _ = try? await runtime.submitUserMessage(agentID: agentID, conversationID: conversationID, text: text, attachments: [],
                                                         author: owner.map { MessageAuthor(id: $0.id, name: $0.name) })
            }))
        await channels.useReviews(
            hook: { text, contact, keys, isGroup in await reviews.heard(text, in: contact.id, isGroup: isGroup, keys: keys, via: "\(contact.kind.title) · \(contact.name)") },
            open: { contactID in await reviews.hasOpenBatch(in: contactID) })
        await channels.start(ChannelService.Dependencies(
            submit: { agentID, conversationID, text, author in
                try await runtime.submitUserMessage(agentID: agentID, conversationID: conversationID, text: text, attachments: [], author: author).1
            },
            defaultAgent: {
                let agents = (try? await store.listAgents(includeRetired: false)) ?? []
                return (agents.first { $0.name == HostService.defaultAgentName && $0.kind == .persistent } ?? agents.first { $0.kind == .persistent })?.id
            },
            notice: { [weak self] text in await self?.publish(.notice(level: .info, agentID: nil, text: text)) },
            personForMicrosoftID: { [weak self] oid in
                await self?.people.snapshot().people.first { p in p.identities.contains { $0.provider == .microsoft && $0.subject == oid } && !p.disabled }
            },
            decideApproval: { decision, author in try await runtime.decideApproval(decision, by: author) },
            answerChoices: { taskID, questionID, answers, author in try await runtime.answerChoices(taskID: taskID, questionID: questionID, answers: answers, by: author) },
            agentName: { id in (try? await store.agent(id))?.name ?? "Pennant" },
            owner: { [weak self] in try? await self?.people.ownerAccount(defaultName: NSFullUserName()) }))
        // Memories saved before meaning search was on (or under another embedding model) get vectors; then what
        // was said in conversations is indexed as passages, and kept current as conversations change.
        let memory = self.memory
        monitors.append(Task.detached(priority: .background) {
            await memory.backfillEmbeddings()
            while !Task.isCancelled {
                await memory.syncPassages()
                try? await Task.sleep(for: .seconds(60))
            }
        })
        log.info("Host ready on port \(config.api.port); inference \(inferenceReachable ? "reachable" : "unreachable") at \(config.inference.baseURL)", category: "host")
    }

    public func stop() async {
        tidyTask?.cancel()
        pushWatch?.cancel()
        for m in monitors { m.cancel() }
        monitors = []
        await heartbeat.stop()
        await chrome.stop()
        await scheduler.stop()
        await channels.stop()
        await runtime.stop()
        await mcp.stop()
        await api?.stop()
        await humanInput.stop()
        await store.close()
        log.info("Host stopped", category: "host")
    }

    /// The built-in assistant who operates this Mac, named after the app.
    static let defaultAgentName = "Pennant"
    static let defaultAgentRole = "personal assistant who operates this Mac"

    private func ensureDefaultAgent() async throws {
        let agents = try await store.listAgents(includeRetired: false)
        guard !agents.contains(where: { $0.kind == .persistent }) else { return }
        let agent = AgentProfile(name: Self.defaultAgentName, role: Self.defaultAgentRole, style: "warm, plain-spoken and brief; straight about what's done and what isn't", avatar: "flag:compass", accentColorHex: "#2F80ED")
        try await store.upsertAgent(agent)
        await publish(.agentUpserted(agent))
    }

    private func startMonitors() {
        // This Mac's Tailscale name and addresses, for phones that leave its network (only when it serves them).
        if api != nil {
            monitors.append(Task { [weak self] in
                while !Task.isCancelled {
                    let info = await TailscaleSelf.read()
                    await self?.setTailscale(info)
                    try? await Task.sleep(for: .seconds(300))
                }
            })
        }
        // Inference reachability: resumes tasks paused for an unavailable endpoint.
        monitors.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                let ok = await self.provider.healthCheck()
                await self.updateInference(reachable: ok)
            }
        })
        // Pause-on-human-input: watches for human events while an agent holds the desktop.
        monitors.append(Task { [weak self] in
            var lastPausedAt: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                let owner = await self.lease.owner
                let pauseOnInput = await self.lease.pauseOnHumanInput
                if case .agent = owner, pauseOnInput, let last = await self.humanInput.lastHumanInputAt(), Date().timeIntervalSince(last) < 0.5 {
                    await self.lease.pause()
                    lastPausedAt = Date()
                    await self.runtime.desktopPausedByHuman(reason: "Paused computer use because you started using the Mac. Press Resume when you are done.")
                }
                let autoResume = await self.config.desktop.autoResumeAfterSeconds
                let pausedByHuman = await self.lease.pausedByHuman
                let humanHasControl = await self.lease.humanHasControl
                if autoResume > 0, let pausedAt = lastPausedAt, pausedByHuman, !humanHasControl {
                    let idle = await self.humanInput.lastHumanInputAt().map { Date().timeIntervalSince($0) } ?? .infinity
                    if idle > autoResume, Date().timeIntervalSince(pausedAt) > autoResume {
                        lastPausedAt = nil
                        await self.lease.resume()
                    }
                }
            }
        })
        // Periodic host status for connected clients.
        monitors.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.publishHostStatus()
            }
        })
        // Background permission re-check: grants made in System Settings show up without user action.
        monitors.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = await self.currentPermissions(forceFresh: false)
                let interval: Double = current.allGranted ? 30 : 4
                try? await Task.sleep(for: .seconds(interval))
                _ = await self.currentPermissions(forceFresh: true)
            }
        })
    }

    func updateInference(reachable: Bool) async {
        let was = inferenceReachable
        inferenceReachable = reachable
        if reachable, !was {
            await publish(.notice(level: .info, agentID: nil, text: "Model server reachable again."))
            await runtime.inferenceAvailable()
        }
        if was != reachable { await publishHostStatus() }
    }

    private func desktopLeaseChanged() async {
        let humanHasControl = await lease.humanHasControl
        let pausedByHuman = await lease.pausedByHuman
        let blocked = humanHasControl || pausedByHuman
        if desktopWasBlocked, !blocked { await runtime.desktopResumed() }
        desktopWasBlocked = blocked
        await publishDesktopStatus()
    }

    private func setTailscale(_ info: TailscaleSelf.Info?) { tailscale = info }

    // MARK: Agent changes (the app's commands and the health review's approved proposals)

    /// Saves an agent's profile, keeping what only the runtime sets (status, kind).
    func saveAgentProfile(_ profile: AgentProfile) async throws -> AgentProfile {
        guard let existing = try await store.agent(profile.id) else { throw ToolError.failed("Agent not found") }
        var agent = profile
        agent.status = existing.status
        agent.statusLine = existing.statusLine
        agent.kind = existing.kind
        agent.updatedAt = Date()
        try await store.upsertAgent(agent)
        await publish(.agentUpserted(agent))
        return agent
    }

    func retire(_ id: AgentID) async throws {
        guard var agent = try await store.agent(id) else { throw ToolError.failed("Agent not found") }
        for t in try await store.listTasks(agentID: id, includeFinished: false) { try? await runtime.cancelTask(t.id, reason: "Agent retired") }
        agent.status = .retired
        agent.updatedAt = Date()
        try await store.upsertAgent(agent)
        await publish(.agentRemoved(id))
    }

    func setSkillStatus(_ id: SkillID, _ status: SkillStatus) async throws -> Skill {
        guard var skill = try await store.skill(id) else { throw ToolError.failed("Skill not found") }
        skill.status = status
        skill.updatedAt = Date()
        try await store.upsertSkill(skill)
        await publish(.skillUpserted(skill))
        return skill
    }

    // MARK: Status

    /// Where phones can reach this host, best first: its Tailscale name (works anywhere Tailscale does), its tailnet
    /// addresses, then its local network address. Only when it listens beyond this Mac.
    func addresses() -> [String] {
        guard config.api.listenOnNetwork else { return [] }
        var list: [String] = []
        if let name = tailscale?.dnsName { list.append(name) }
        list += tailscale?.addresses ?? []
        if let lan = HostAPIServer.advertisedIPv4() { list.append(lan) }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    public func hostInfo() async -> HostInfo {
        var info = HostInfo(hostName: Self.displayName, version: PennantVersion.string, startedAt: startedAt, mode: config.mode, inferenceEndpoint: await inferenceEndpointLabel(), inferenceModel: config.inference.model, inferenceReachable: inferenceReachable, databasePath: paths.databaseURL.path, activeTaskCount: await runtime.activeTaskCount, connectedClients: clients.count, contextWindowTokens: provider.capabilities.contextWindowTokens, inferenceProvider: config.inference.provider)
        if let tls, let api, await api.tlsPort > 0 {
            info.tlsPort = await api.tlsPort
            info.tlsFingerprint = tls.fingerprint
        }
        let addresses = addresses()
        info.addresses = addresses.isEmpty ? nil : addresses
        info.build = PennantVersion.build
        return info
    }

    public func desktopStatus(freshPermissions: Bool = false) async -> DesktopStatus {
        let size = await desktop.displaySize()
        return await lease.snapshot(permissions: await currentPermissions(forceFresh: freshPermissions), frontmostApp: await desktop.frontmostApp()?.name, displayWidth: size.width, displayHeight: size.height, streamingClients: streamingClients)
    }

    /// Permissions as a fresh process would see them, cached briefly. Falls back to the in-process check.
    public func currentPermissions(forceFresh: Bool) async -> DesktopPermissions {
        if !forceFresh, let cached = permissionsCache, Date().timeIntervalSince(cached.at) < 3 { return cached.value }
        let inProcess = await desktop.permissions()
        var value = inProcess
        if useFreshPermissionChecks, let fresh = await PermissionCheck.fresh() {
            value = fresh
            if PermissionCheck.restartNeeded(fresh: fresh, inProcess: inProcess) { await scheduleRestartForPermissions() }
        }
        let changed = permissionsCache?.value != value
        permissionsCache = (value, Date())
        if changed { await publishDesktopStatus() }
        return value
    }

    /// Helper-process checks only make sense for the real host executable (never for tests or the app).
    public var useFreshPermissionChecks = PermissionCheck.canSpawnHelper

    private func scheduleRestartForPermissions() async {
        guard !restartScheduled else { return }
        restartScheduled = true
        let active = await runtime.activeTaskCount
        if active == 0 {
            await publish(.notice(level: .info, agentID: nil, text: "Permission granted. Restarting the host to apply it; the app reconnects in a few seconds."))
            log.info("Restarting to apply newly granted permissions", category: "host")
            let handler = restartHandler
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                await self.stop()
                await handler()
            }
        } else {
            await publish(.notice(level: .warning, agentID: nil, text: "Permission granted, but a task is running. Restart the host (Settings › Host) when it finishes to apply it."))
            restartScheduled = false
        }
    }

    func publishHostStatus() async {
        await eventBus.publish(HostEvent(seq: 0, payload: .hostStatus(await hostInfo())))
    }

    private func publishDesktopStatus() async {
        await eventBus.publish(HostEvent(seq: 0, payload: .desktopStatus(await desktopStatus())))
    }

    func publish(_ payload: EventPayload) async {
        if let event = try? await store.appendEvent(payload) { await eventBus.publish(event) }
    }

}

/// Lets the lease notify the service without an initialisation cycle.
actor StatusRelay {
    private var handler: (@Sendable () async -> Void)?
    func set(_ h: @escaping @Sendable () async -> Void) { handler = h }
    func fire() async { await handler?() }
}

extension DesktopLease {
    public func setPauseOnHumanInput(_ on: Bool) { pauseOnHumanInput = on }
}
