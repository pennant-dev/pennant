import Foundation

public let pennantProtocolVersion = 1

/// Identity a client presents on connect.
public struct ClientHello: Hashable, Codable, Sendable {
    public var clientID: ClientID
    public var displayName: String
    public var platform: String
    public var appVersion: String
    public var protocolVersion: Int
    /// Last event the client has applied. The host replays everything after it.
    public var lastEventSeq: EventSeq
    public var token: String?
    /// Through Cloudflare Access: the Access token, which is also the sign-in (the account with its email).
    public var accessToken: String?

    public init(clientID: ClientID, displayName: String, platform: String, appVersion: String, protocolVersion: Int = pennantProtocolVersion, lastEventSeq: EventSeq = 0, token: String? = nil, accessToken: String? = nil) {
        self.accessToken = accessToken
        self.clientID = clientID
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.lastEventSeq = lastEventSeq
        self.token = token
    }
}

public struct Page<T: Codable & Hashable & Sendable>: Hashable, Codable, Sendable {
    public var items: [T]
    public var hasMore: Bool
    public init(items: [T], hasMore: Bool = false) { self.items = items; self.hasMore = hasMore }
}

/// Snapshot handed to a freshly connected client before live events resume.
public struct StateSnapshot: Hashable, Codable, Sendable {
    public var host: HostInfo
    public var agents: [AgentProfile]
    public var tasks: [TaskRecord]
    public var conversations: [Conversation]
    public var desktop: DesktopStatus
    public var mcpServers: [MCPServerStatus]
    public var latestEventSeq: EventSeq
    public var schedules: [ScheduledJob]
    /// Who this client is signed in as (nil from hosts that predate people).
    public var me: Person?
    public var goals: [Goal]

    public init(host: HostInfo, agents: [AgentProfile], tasks: [TaskRecord], conversations: [Conversation], desktop: DesktopStatus, mcpServers: [MCPServerStatus], latestEventSeq: EventSeq, schedules: [ScheduledJob] = [], me: Person? = nil, goals: [Goal] = []) {
        self.me = me
        self.goals = goals
        self.host = host
        self.agents = agents
        self.tasks = tasks
        self.conversations = conversations
        self.desktop = desktop
        self.mcpServers = mcpServers
        self.latestEventSeq = latestEventSeq
        self.schedules = schedules
    }

    private enum CodingKeys: String, CodingKey { case host, agents, tasks, conversations, desktop, mcpServers, latestEventSeq, schedules, me, goals }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(HostInfo.self, forKey: .host)
        agents = try c.decode([AgentProfile].self, forKey: .agents)
        tasks = try c.decode([TaskRecord].self, forKey: .tasks)
        conversations = try c.decode([Conversation].self, forKey: .conversations)
        desktop = try c.decode(DesktopStatus.self, forKey: .desktop)
        mcpServers = try c.decode([MCPServerStatus].self, forKey: .mcpServers)
        latestEventSeq = try c.decode(EventSeq.self, forKey: .latestEventSeq)
        schedules = try c.decodeIfPresent([ScheduledJob].self, forKey: .schedules) ?? []
        me = try c.decodeIfPresent(Person.self, forKey: .me)
        goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
    }
}

public struct MemoryQuery: Hashable, Codable, Sendable {
    public var text: String
    public var scopes: [String]
    public var includeSuperseded: Bool
    public var limit: Int
    /// false: facts and what was said only, as agents search (they already have every instruction). nil means yes.
    public var instructions: Bool?

    public init(text: String, scopes: [String] = [], includeSuperseded: Bool = false, limit: Int = 20, instructions: Bool? = nil) {
        self.text = text
        self.scopes = scopes
        self.includeSuperseded = includeSuperseded
        self.limit = limit
        self.instructions = instructions
    }
}

public struct DiagnosticsReport: Hashable, Codable, Sendable {
    public var host: HostInfo
    public var databasePath: String
    public var artifactDirectory: String
    public var configPath: String
    public var logPath: String
    public var eventCount: Int64
    public var toolSpecs: [ToolSpec]
    public var recentToolRecords: [ToolRecord]
    public var memory: MemoryOverview

    public init(host: HostInfo, databasePath: String, artifactDirectory: String, configPath: String, logPath: String, eventCount: Int64, toolSpecs: [ToolSpec], recentToolRecords: [ToolRecord], memory: MemoryOverview) {
        self.host = host
        self.databasePath = databasePath
        self.artifactDirectory = artifactDirectory
        self.configPath = configPath
        self.logPath = logPath
        self.eventCount = eventCount
        self.toolSpecs = toolSpecs
        self.recentToolRecords = recentToolRecords
        self.memory = memory
    }
}

/// Commands a client sends. Each carries a unique ID; the host answers with exactly one reply.
public struct ClientCommand: Hashable, Codable, Sendable, Identifiable {
    public var id: CommandID
    public var body: CommandBody

    public init(id: CommandID = CommandID(), body: CommandBody) {
        self.id = id
        self.body = body
    }
}

public enum CommandBody: Hashable, Codable, Sendable {
    // Session and signing in
    case hello(ClientHello)
    /// The sign-in providers this host has set up. Allowed before `hello`. Replies `signInOptions`.
    case signInOptions
    /// Starts signing in with a provider; the app then runs the returned step. Allowed before `hello`. Replies `signInStarted`.
    case beginSignIn(provider: SignInProvider, redirectURI: String)
    /// Finishes a sign-in: the code the browser came back with (nil for GitHub's device code, which the host polls
    /// for). Allowed before `hello`. Replies `signedIn` or an error (`not_invited`, `sign_in_failed`).
    case completeSignIn(state: String, code: String?, clientID: ClientID, clientName: String, platform: String)
    /// Signs in with an email and password. Allowed before `hello` (over an encrypted connection). Replies `signedIn`.
    case signInWithPassword(email: String, password: String, clientID: ClientID, clientName: String, platform: String)
    /// Joins with an invite's one-time code, choosing a name and password. Allowed before `hello`. Replies `signedIn`.
    case redeemInvite(code: String, name: String, password: String, clientID: ClientID, clientName: String, platform: String)
    case ping

    // People (the owner manages them; members may list)
    case listPeople
    case invitePerson(email: String)
    case removeInvite(email: String)
    /// Removes a member and signs out every device they signed in on.
    case removePerson(PersonID)
    /// Makes someone an owner (they can manage people from any device) or a member again.
    case setPersonRole(PersonID, PersonRole)
    case updateSignInSettings(SignInSettings)
    /// Your own name and email. On the Mac itself this sets up the owner's account.
    case updateMyAccount(name: String, email: String)
    /// Sets or changes your password (`current` is needed when one is set, except on the Mac itself).
    case setMyPassword(current: String?, new: String)

    // The agent
    case updateAgent(AgentProfile)
    case retireAgent(AgentID)
    /// What an agent's model received on its latest turn (or a preview for a new task when none ran yet).
    case inspectPrompt(AgentID)

    // Conversations
    case sendMessage(agentID: AgentID, conversationID: ConversationID?, text: String, attachments: [Attachment])
    case listMessages(conversationID: ConversationID, beforeMessageID: MessageID?, limit: Int)
    case answerQuestion(taskID: TaskID, text: String)
    /// Answers a choice card (question text → answer).
    case answerChoices(taskID: TaskID, questionID: String, answers: [String: String])
    /// Stores a file the user attaches to a message; replies `attachment` to send with `sendMessage`.
    case uploadAttachment(fileName: String, mimeType: String, base64: String)
    /// Fold the conversation's history into a checkpoint now. Replies with the updated latest task
    /// (its usage carries the new context size); a `checkpointSaved` event follows.
    case compactConversation(ConversationID)
    /// Checkpoints that apply to a conversation, oldest first.
    case getConversationCheckpoints(ConversationID)
    /// Closes a conversation as done (stopping its running task), or reopens it.
    case closeConversation(ConversationID, closed: Bool)
    /// Deletes conversations for good (owner only): running work stops, then messages and tasks go.
    case deleteConversations([ConversationID])
    /// Closes every open conversation with nothing new for `idleDays` (owner only). Replies `pruned`.
    case pruneConversations(idleDays: Int)

    // Tasks
    case pauseTask(TaskID, reason: String)
    case resumeTask(TaskID)
    case cancelTask(TaskID, reason: String)
    case getToolRecords(TaskID)
    case getArtifact(ArtifactID)

    // Approvals and reports
    /// The user's answer to an approval card; the waiting task resumes with it. Replies `ok`.
    case decideApproval(ApprovalDecision)
    /// Every approval card still waiting for the user, from any agent, newest first. Replies `pendingApprovals`.
    case listPendingApprovals
    /// Report cards from every agent in the last 30 days, newest first. Replies `reports`.
    case listReports

    // Coding runs
    /// Sets the project folder a coding agent's conversation works in. Replies `ok`.
    case setConversationFolder(ConversationID, path: String)
    /// How a coding conversation asks (mode) and which model its CLI runs; applies from the next message.
    case setConversationCoding(ConversationID, mode: CodingMode?, model: String?)
    /// Folders on the host a coding run could work in: the Coding projects first, then git repositories found in
    /// the usual places. Replies `projects`.
    case listProjects
    /// From the coding CLI's permission bridge: may the running coding task use this tool with this input?
    /// Shown as an approval card; replies `coderDecision`.
    case coderPermission(taskID: TaskID, tool: String, input: JSONValue)
    /// From the coding CLI's bridge: run one of the Pennant tools a coding agent may use (messaging people) for the
    /// running coding task, as any agent's call would run. Replies `coderToolResult`.
    case coderTool(taskID: TaskID, name: String, arguments: JSONValue)
    /// Mints a token for a GitHub App identity, as a coding run would, to check the App ID, installation and the
    /// Vault entry's private key before saving them. Replies `ok`, or an error saying what GitHub or the Vault refused.
    case checkGitHubApp(GitHubAppIdentity)
    /// The GitHub app people link for pull request reviews (device flow on), and its client secret when its sign-ins
    /// expire. Owner only. Replies `ok`.
    case setReviewsGitHubApp(clientID: String, secret: String?)

    // Desktop
    case getDesktopStatus
    case takeoverDesktop
    case releaseDesktop
    case pauseDesktop
    case resumeDesktop
    case setPauseOnHumanInput(Bool)
    case subscribeScreen(ScreenStreamOptions)
    case unsubscribeScreen
    case remoteInput(RemoteInput)
    case captureScreenshot(maxWidth: Int)
    /// Trigger the macOS permission prompts (Accessibility, Screen Recording, Input Monitoring, Automation).
    /// `targets` limits which ones to request; empty means all. Returns the desktop status afterwards.
    case requestPermissions(targets: [String])
    /// Re-evaluate permissions in a fresh helper process (grants made in System Settings show up immediately).
    case recheckPermissions
    /// Clear this host's entry for one permission ("accessibility", "screenRecording", "inputMonitoring", or a
    /// bundle id for Automation) so macOS asks again; used when an entry is stale or was denied.
    case resetPermission(target: String)

    // Memory
    case memoryOverview
    case searchMemory(MemoryQuery)
    case listEntities(kind: MemoryEntityKind?, scope: String?, limit: Int)
    case listPreferences(scope: String?)
    case listRelations(entityID: MemoryEntityID)
    case upsertEntity(MemoryEntity)
    case upsertPreference(Preference)
    case forgetEntity(MemoryEntityID)
    case forgetPreference(PreferenceID)
    /// The passages that mention a fact. Replies `memoryPassages`.
    case memoryEvidence(MemoryEntityID)
    /// Renames a fact (the old name becomes an alias; onto another fact's name, merges). Replies `entity`.
    case renameEntity(MemoryEntityID, name: String)
    /// Folds one fact into another. Replies `entity`.
    case mergeEntities(from: MemoryEntityID, into: MemoryEntityID)
    /// What Pennant decided on its own to keep memory current, newest first. Replies `memoryUpkeep`.
    case memoryUpkeepLog
    /// Puts back what one of those decisions set aside. Replies `memoryUpkeep`.
    case undoMemoryUpkeep(id: String)
    /// Names removed from memory. Replies `removedMemory`.
    case listRemovedMemory
    /// Lets agents remember a removed name again. Replies `removedMemory`.
    case restoreRemovedMemory(name: String, kind: MemoryEntityKind)

    // Skills
    case listSkills
    case updateSkill(Skill)
    case setSkillStatus(SkillID, SkillStatus)
    case deleteSkill(SkillID)
    /// Import every SKILL.md found under a path (a skill folder, or a directory of them).
    /// `path` is a folder, a SKILL.md, or a git URL (cloned under the host's data folder).
    /// `only` limits the import to those SKILL.md paths (from `previewSkillImport`); nil imports everything found.
    case importSkills(path: String, only: [String]? = nil)
    /// Lists what `importSkills` would import from a folder or git URL without writing anything.
    case previewSkillImport(path: String)
    case deleteSkills([SkillID])
    /// Remembers a folder so it shows up in `scanSkillLocations`; replies with the updated locations.
    case addSkillFolder(path: String)
    case removeSkillFolder(path: String)
    /// Known skill folders of other harnesses that exist on this Mac.
    case scanSkillLocations

    // Teach mode: record a demonstration, then draft a skill from it
    /// Starts recording what the user does on the host Mac. Replies `teaching` with the new session.
    case startTeaching(goal: String)
    /// Stops recording; the session stays for review and drafting.
    case stopTeaching
    /// Stops and throws the session away.
    case cancelTeaching
    case addTeachingNote(String)
    /// Drops recorded steps the user does not want in the skill (stray clicks), by event id.
    case removeTeachingEvents([Int])
    case getTeaching
    /// Drafts a provisional skill from the stopped session. `goal` replaces the session's goal when set.
    /// Replies `skill` with the saved draft.
    case draftSkillFromTeaching(goal: String?)

    // Library (brand assets), vault (sign-ins for scripts) and browser sign-ins
    case listLibrary
    /// Adds a file to a collection (created if new). Replies `library`.
    case uploadLibraryAsset(collection: String, fileName: String, mimeType: String, base64: String, name: String, notes: String)
    case updateLibraryAsset(LibraryAsset)
    case deleteLibraryAsset(id: String)
    /// Creates or updates a collection's guidance notes. Replies `library`.
    case saveLibraryCollection(LibraryCollection)
    /// Deletes a collection and its files. Replies `library`.
    case deleteLibraryCollection(name: String)
    /// A small preview of an image asset. Replies `libraryPreview`.
    case libraryPreview(id: String)
    case listVault
    /// Saves an entry; nil secret fields keep what is stored. Replies `vault`.
    case saveVaultItem(VaultItem, secret: VaultSecret?)
    case deleteVaultItem(id: String)
    /// Chrome profiles on this Mac. Replies `chromeProfiles`.
    case listChromeProfiles
    /// The sites a Chrome profile has cookies for (names only). Replies `chromeSites`.
    case listChromeSites(profile: String)
    /// Copies the sites' sign-in cookies from a Chrome profile into Pennant's browser. Replies `chromeImport`.
    case importChromeSignIns(profile: String, sites: [String])
    /// Sites whose sign-ins were copied into Pennant's browser. Replies `browserSignIns`.
    case listBrowserSignIns
    /// Deletes a site's cookies from Pennant's browser and forgets it. Replies `browserSignIns`.
    case removeBrowserSignIn(site: String)

    // Goals
    case listGoals
    /// Creates or edits a goal (its jobs follow its schedules and status). Replies `goal`.
    case upsertGoal(Goal)
    /// Moves a goal to any status, proposed included. Replies `goal`.
    case setGoalStatus(GoalID, Goal.Status)
    /// Deletes a goal with its board and its jobs; its conversation stays. Replies `ok`.
    case deleteGoal(GoalID)
    /// Replies `goalItems`.
    case listGoalItems(GoalID)
    /// Adds or changes an item on a goal's board (the owner moving or dropping it). Replies `goalItem`.
    case upsertGoalItem(GoalItem)
    /// The owner's comment on an item; the agent reads it at its next session. Replies `goalItem`.
    case commentGoalItem(GoalItemID, text: String)

    // Scheduled jobs
    case listSchedules
    case upsertSchedule(ScheduledJob)
    case deleteSchedule(ScheduleID)
    case runScheduleNow(ScheduleID)
    /// Preview the next few run times for a schedule expression (validation for the editor).
    case previewSchedule(expression: String, timeZone: String, count: Int)

    // Channels (owner only)
    /// Replies `channels`.
    case listChannels
    case setChannelEnabled(ChannelKind, enabled: Bool)
    /// Messages on the host is a person's own Apple ID: only texts starting with "Pennant" reach it, replies labelled.
    case setIMessagePersonal(Bool)
    /// Checks the bot token with Telegram, keeps it in the Keychain, and turns Telegram on. Replies `channels`.
    case setTelegramToken(String)
    /// The Teams bot's Entra app id, tenant, public webhook address, and (when changing it) client secret. Replies `channels`.
    case setTeamsBot(appID: String, tenantID: String, publicURL: String, secret: String?)
    /// A one-time code (and link) that ties a chat to the requester. Replies `channelLink`.
    case createChannelLink(ChannelKind)
    case upsertChannelContact(ChannelContact)
    case removeChannelContact(id: String)

    // Notifications on iPhones (APNs)
    /// This device wants notifications for the signed-in person. `environment`: "development" or "production".
    case registerPushDevice(token: String, environment: String, teamID: String?, name: String, bundleID: String)
    /// Replies `pushStatus`.
    case getPushStatus
    /// The APNs key from the Apple Developer account (owner only): its Key ID and the .p8 file's text.
    case setPushKey(keyID: String, teamID: String?, p8: String)
    /// A test notification to the caller's devices (every device, for the owner at the Mac). Replies `pushStatus`.
    case sendTestPush

    // Connected services (MCP)
    case listMCPServers
    case addMCPServer(MCPServerConfig)
    case removeMCPServer(MCPServerID)
    case reconnectMCPServer(MCPServerID)
    /// Starts the OAuth flow for an HTTP server: discovery, registration, PKCE. Replies `mcpAuthStarted` with the
    /// URL to open in a browser; the host finishes the flow on its loopback redirect and publishes the new status.
    case beginMCPAuth(MCPServerID)
    case cancelMCPAuth(MCPServerID)
    /// Stores an API key (or a pasted token) for the server in the Keychain and reconnects.
    case setMCPCredential(MCPServerID, secret: String)
    /// Forgets stored credentials and disconnects.
    case signOutMCP(MCPServerID)
    case listMCPCatalog

    // Models
    /// Sends a model one short prompt and reports whether it answered. Replies `modelTest`.
    case testModel(HostConfig.Inference)
    /// Model usage between two dates, summed per task and model. Replies `usage`.
    case usageReport(from: Date, to: Date)
    /// Ask an OpenAI-compatible endpoint for its models (GET {baseURL}/models). Used by the settings UI.
    /// What the endpoint serves; `apiKeyVault` names a Vault entry the host reads the key from instead.
    case listModels(baseURL: String, apiKey: String?, apiKeyVault: String? = nil)
    /// The Azure CLI on the host: installed, signed in as whom. Replies `azureStatus`.
    case azureStatus
    /// Runs `az login` on the host (opens its browser). Replies `azureStatus`.
    case azureLogin
    case azureSubscriptions
    case azureResources(subscription: String)
    case azureDeployments(subscription: String, resourceGroup: String, resource: String)

    // ChatGPT account as the inference provider
    /// Starts the Codex OAuth sign-in; replies `chatGPTSignInStarted` with the browser URL. The host finishes the
    /// flow on its loopback redirect and publishes `hostStatus`.
    case beginChatGPTSignIn
    /// Reuses the Codex CLI's login on this Mac (~/.codex/auth.json) when the user asks for it.
    case importCodexLogin
    case signOutChatGPT
    case getChatGPTAccount
    /// The static list of models the ChatGPT backend serves.
    case listChatGPTModels

    // The host: diagnostics, settings, moving to another Mac
    case getDiagnostics
    case listEvents(afterSeq: EventSeq, limit: Int)
    case getConfig
    case updateConfig(HostConfig)
    /// Writes a Pennant export folder inside `folder` (default ~/Documents); secrets only with a passphrase. Replies `exported`.
    case exportData(folder: String?, passphrase: String?)
    /// Checks and stages an export, then restarts the host, which swaps it in. Replies `ok` before restarting.
    case importData(folder: String, passphrase: String?)
}

public struct HostReply: Hashable, Codable, Sendable {
    public var commandID: CommandID
    public var result: ReplyBody

    public init(commandID: CommandID, result: ReplyBody) {
        self.commandID = commandID
        self.result = result
    }
}

public enum ReplyBody: Hashable, Codable, Sendable {
    case ok
    /// `mode`: the permission mode the CLI switches to for the rest of the run (after an approved plan).
    case coderDecision(allow: Bool, input: JSONValue?, message: String?, mode: CodingMode? = nil)
    case coderToolResult(text: String, isError: Bool)
    case projects([String])
    case error(code: String, message: String)
    case welcome(StateSnapshot)
    /// `password`: the host takes email-and-password sign-in and invite codes.
    case signInOptions([SignInProvider], hostName: String)
    case signInStarted(SignInStart)
    case signedIn(SignedIn)
    case people(PeopleDirectory)
    case agent(AgentProfile)
    case messages(Page<Message>)
    case messageAccepted(messageID: MessageID, conversationID: ConversationID, taskID: TaskID)
    case task(TaskRecord)
    case checkpoints([Checkpoint])
    case toolRecords([ToolRecord])
    case desktop(DesktopStatus)
    case screenshot(ImageRef, base64: String)
    case memoryOverview(MemoryOverview)
    case memoryHits([MemoryHit])
    case memoryPassages([MemoryPassage])
    case memoryUpkeep([MemoryUpkeepEntry])
    case removedMemory([IgnoredMemoryName])
    case channels(ChannelsOverview)
    /// How many conversations a prune closed.
    case pruned(count: Int)
    case pushStatus(PushStatus)
    case channelLink(ChannelLinkCode)
    case entities([MemoryEntity])
    case preferences([Preference])
    case relations([MemoryRelation])
    case entity(MemoryEntity)
    case preference(Preference)
    case artifact(ArtifactRecord, base64: String)
    case skills([Skill])
    case pendingApprovals([PendingApproval])
    case reports([PostedReport])
    case skill(Skill)
    case importedSkills([Skill], warnings: [String])
    case skillLocations([SkillLocation])
    case skillPreview(SkillImportPreview)
    case teaching(TeachingSession?)
    case promptInspection(PromptInspection)
    case attachment(Attachment)
    case library(LibraryIndex)
    case libraryPreview(id: String, base64: String)
    case vault([VaultItem])
    case chromeProfiles([ChromeProfile])
    case modelTest(ModelTestResult)
    case exported(PennantExportResult)
    case usage([UsageRow])
    case azureStatus(AzureStatus)
    case azureSubscriptions([AzureSubscription])
    case azureResources([AzureResource])
    case azureDeployments([AzureDeployment])
    case chromeSites([ChromeSite])
    case chromeImport(ChromeImportResult)
    case browserSignIns([BrowserSignIn])
    case schedules([ScheduledJob])
    case schedule(ScheduledJob)
    case goals([Goal])
    case goal(Goal)
    case goalItems([GoalItem])
    case goalItem(GoalItem)
    case schedulePreview([Date], error: String?)
    case mcpServers([MCPServerStatus])
    case mcpAuthStarted(serverID: MCPServerID, url: String)
    case mcpCatalog([MCPCatalogEntry])
    case chatGPTSignInStarted(url: String)
    case chatGPTAccount(ChatGPTAccount)
    case chatGPTModels([ChatGPTModel])
    case diagnostics(DiagnosticsReport)
    case events([HostEvent])
    case config(HostConfig, restartRequired: Bool)
    case models([ModelInfo])
}

/// A model advertised by an inference endpoint.
public struct ModelInfo: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var ownedBy: String?
    public var created: Date?
    public init(id: String, ownedBy: String? = nil, created: Date? = nil) {
        self.id = id
        self.ownedBy = ownedBy
        self.created = created
    }
}

/// Everything that travels on the control socket, in either direction.
public enum WireMessage: Hashable, Codable, Sendable {
    case command(ClientCommand)
    case reply(HostReply)
    case event(HostEvent)

    public func encoded() throws -> Data { try JSONCodec.encode(self) }
    public static func decode(_ data: Data) throws -> WireMessage { try JSONCodec.decode(WireMessage.self, from: data) }
}

/// Binary screen-stream frame: 4-byte big-endian header length, JSON `ScreenFrameHeader`, then JPEG bytes.
public enum ScreenFrameCodec {
    public static func encode(header: ScreenFrameHeader, jpeg: Data) throws -> Data {
        let head = try JSONCodec.encode(header)
        var out = Data(capacity: 4 + head.count + jpeg.count)
        var len = UInt32(head.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(head)
        out.append(jpeg)
        return out
    }

    public static func decode(_ data: Data) throws -> (ScreenFrameHeader, Data) {
        guard data.count >= 4 else { throw ProtocolError.malformedFrame }
        let len = data.prefix(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard data.count >= 4 + len else { throw ProtocolError.malformedFrame }
        let header = try JSONCodec.decode(ScreenFrameHeader.self, from: data.subdata(in: 4 ..< 4 + len))
        return (header, data.subdata(in: (4 + len) ..< data.count))
    }
}

public enum ProtocolError: Error, Sendable, CustomStringConvertible {
    case malformedFrame
    case unauthenticated
    case unsupportedVersion(Int)
    case notConnected

    public var description: String {
        switch self {
        case .malformedFrame: return "Malformed frame"
        case .unauthenticated: return "Client is not authenticated"
        case .unsupportedVersion(let v): return "Unsupported protocol version \(v)"
        case .notConnected: return "Not connected to host"
        }
    }
}
