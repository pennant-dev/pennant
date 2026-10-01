import PennantCore
import Foundation

/// Reaching people outside Pennant, and hearing back. Contacts are linked per channel; what they send lands in an
/// agent's conversation as a message from them. Their own thread is relayed: the agent's answers (and questions)
/// go back to them. When an agent reaches out from its own conversation, the reply goes back there for a day and
/// nothing is relayed, so a reply never reaches the wrong person.
public actor ChannelService {
    public struct Dependencies: Sendable {
        public var submit: @Sendable (_ agentID: AgentID, _ conversationID: ConversationID?, _ text: String, _ author: MessageAuthor) async throws -> ConversationID
        public var defaultAgent: @Sendable () async -> AgentID?
        public var notice: @Sendable (_ text: String) async -> Void
        /// The Pennant person signed in with this Microsoft (Entra) object id, if any: Teams users who are people
        /// here are linked on their first message.
        public var personForMicrosoftID: @Sendable (_ objectID: String) async -> Person?
        /// A card's buttons: decide an approval, answer a choice card, as the person who tapped.
        public var decideApproval: @Sendable (_ decision: ApprovalDecision, _ by: MessageAuthor) async throws -> Void
        public var answerChoices: @Sendable (_ taskID: TaskID, _ questionID: String, _ answers: [String: String], _ by: MessageAuthor) async throws -> Void
        public var agentName: @Sendable (_ id: AgentID) async -> String
        /// The owner, who speaks from this Mac's own Apple ID in an iMessage group chat.
        public var owner: @Sendable () async -> Person?
        public init(submit: @escaping @Sendable (AgentID, ConversationID?, String, MessageAuthor) async throws -> ConversationID,
                    defaultAgent: @escaping @Sendable () async -> AgentID?, notice: @escaping @Sendable (String) async -> Void,
                    personForMicrosoftID: @escaping @Sendable (String) async -> Person? = { _ in nil },
                    decideApproval: @escaping @Sendable (ApprovalDecision, MessageAuthor) async throws -> Void = { _, _ in throw ToolError.failed("Approvals aren't available here") },
                    answerChoices: @escaping @Sendable (TaskID, String, [String: String], MessageAuthor) async throws -> Void = { _, _, _, _ in throw ToolError.failed("Answers aren't available here") },
                    agentName: @escaping @Sendable (AgentID) async -> String = { _ in "Pennant" },
                    owner: @escaping @Sendable () async -> Person? = { nil }) {
            self.submit = submit; self.defaultAgent = defaultAgent; self.notice = notice; self.personForMicrosoftID = personForMicrosoftID
            self.decideApproval = decideApproval; self.answerChoices = answerChoices; self.agentName = agentName
            self.owner = owner
        }
    }

    struct State: Codable {
        var contacts: [ChannelContact] = []
        var enabled: [String: Bool] = [:]
        var links: [String: Link] = [:]
        var telegramOffset: Int = 0
        var imessageRowID: Int64 = 0
        var refusedChats: [String] = []
        var teams: TeamsBot.Config?
        /// Reply windows from before "one reply per outreach" captured everything for a day; they're cleared once.
        var repliesOncePerOutreach = false
        /// Approval cards sent to people, to update when the approval is decided: approval id → where they went.
        var approvalCards: [String: [CardRef]] = [:]
        /// Messages here is a person's own Apple ID (nil counts as yes: the safe guess on a personal Mac). Then only texts
        /// that start with "Pennant" reach it, and its replies are labelled, so the person's own conversations are left alone.
        var imessagePersonal: Bool?

        struct CardRef: Codable, Hashable {
            var contactID: String
            var activityID: String
        }

        init() {}

        /// Every field is optional in the file: a state saved before a field existed must still load (a missing key
        /// would otherwise fail the whole file, start empty, and the next save would wipe it).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            contacts = try c.decodeIfPresent([ChannelContact].self, forKey: .contacts) ?? []
            enabled = try c.decodeIfPresent([String: Bool].self, forKey: .enabled) ?? [:]
            links = try c.decodeIfPresent([String: Link].self, forKey: .links) ?? [:]
            telegramOffset = try c.decodeIfPresent(Int.self, forKey: .telegramOffset) ?? 0
            imessageRowID = try c.decodeIfPresent(Int64.self, forKey: .imessageRowID) ?? 0
            refusedChats = try c.decodeIfPresent([String].self, forKey: .refusedChats) ?? []
            imessagePersonal = try c.decodeIfPresent(Bool.self, forKey: .imessagePersonal)
            teams = try c.decodeIfPresent(TeamsBot.Config.self, forKey: .teams)
            approvalCards = try c.decodeIfPresent([String: [CardRef]].self, forKey: .approvalCards) ?? [:]
            repliesOncePerOutreach = try c.decodeIfPresent(Bool.self, forKey: .repliesOncePerOutreach) ?? false
        }

        struct Link: Codable {
            var kind: ChannelKind
            var personID: PersonID?
            var name: String
            var expiresAt: Date
        }
    }

    private let fileURL: URL
    private let keychain: KeychainStore
    private let store: any StoreProtocol
    private let eventBus: EventBus
    private var deps: Dependencies?
    private var state: State
    private var telegramName: String?
    private var status: [ChannelKind: (detail: String, healthy: Bool)] = [:]
    private var loops: [Task<Void, Never>] = []
    /// One-time tokens for sends the user approved on a card.
    private var approvedSends: [String: (contactID: String, text: String)] = [:]
    /// Tests replace the real send (Telegram, Messages, Teams) with this; cards arrive as their text version,
    /// and `cardSender` (when set) sees the cards themselves.
    private var sender: (@Sendable (ChannelContact, String) async throws -> Void)?
    private var cardSender: (@Sendable (ChannelContact, JSONValue) async throws -> String?)?

    func useSender(_ sender: @escaping @Sendable (ChannelContact, String) async throws -> Void) { self.sender = sender }

    /// Pull request reviews: what's said in a chat goes here first; an approval it handles gets its answer in that
    /// chat and goes no further. `reviewOpen` says whether a chat has a batch waiting (so a bare "approve all" counts).
    private var reviewHook: (@Sendable (_ text: String, _ contact: ChannelContact, _ keys: [String], _ isGroup: Bool) async -> String?)?
    private var reviewOpen: (@Sendable (_ contactID: String) async -> Bool)?
    public func useReviews(hook: @escaping @Sendable (String, ChannelContact, [String], Bool) async -> String?,
                           open: @escaping @Sendable (String) async -> Bool) {
        reviewHook = hook
        reviewOpen = open
    }

    /// Who a contact is, as reviews know people: their own thread, their handle, their Entra id, their Pennant person.
    public func reviewKeys(of contact: ChannelContact) -> Set<String> {
        var keys: Set<String> = ["contact:\(contact.id)"]
        if contact.kind == .imessage, !Self.isIMessageGroup(contact) { keys.insert("imessage:\(IMessageBridge.normalize(contact.address))") }
        if contact.kind == .teams, let aad = contact.details?["aad"], !aad.isEmpty { keys.insert("teams:\(aad)") }
        if let person = contact.personID { keys.insert(person.rawValue) }
        return keys
    }
    func useCardSender(_ sender: @escaping @Sendable (ChannelContact, JSONValue) async throws -> String?) { cardSender = sender }

    /// Choice cards sent and still open: question id → the question and the task waiting on it.
    private var openChoiceCards: [String: (taskID: TaskID, question: ChoiceQuestion)] = [:]

    static let telegramTokenAccount = "telegram.bot"
    static let teamsSecretAccount = "teams.secret"
    static let teamsPath = "/api/teams/messages"
    static let webhookPort: UInt16 = 7340
    private let webhooks = WebhookServer()
    private let teamsTokens = TeamsTokenCache()
    private let teamsValidator = TeamsTokenValidator()

    static let replyWindow: TimeInterval = 24 * 3600

    public init(paths: HostPaths, keychain: KeychainStore, store: any StoreProtocol, eventBus: EventBus) {
        self.fileURL = paths.root.appendingPathComponent("channels.json")
        self.keychain = keychain
        self.store = store
        self.eventBus = eventBus
        if let data = try? Data(contentsOf: fileURL) {
            do { self.state = try JSONCodec.decode(State.self, from: data) } catch {
                // Unreadable: keep the file aside rather than overwrite it with an empty state.
                log.error("channels.json couldn't be read (\(error)); kept as channels.json.unreadable", category: "channels")
                try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("unreadable"))
                try? FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("unreadable"))
                self.state = State()
            }
        } else {
            self.state = State()
        }
        if !state.repliesOncePerOutreach {
            for i in state.contacts.indices {
                state.contacts[i].replyAgentID = nil
                state.contacts[i].replyConversationID = nil
                state.contacts[i].replyUntil = nil
            }
            state.repliesOncePerOutreach = true
            try? JSONCodec.encode(state).write(to: fileURL, options: [.atomic])
        }
    }

    // MARK: Lifecycle

    public func start(_ deps: Dependencies) {
        self.deps = deps
        stop()
        loops.append(Task { [weak self] in await self?.relayLoop() })
        if isEnabled(.telegram), telegramToken != nil { loops.append(Task { [weak self] in await self?.telegramLoop() }) }
        if isEnabled(.imessage) { loops.append(Task { [weak self] in await self?.imessageLoop() }) }
        if isEnabled(.teams), state.teams != nil, teamsSecret != nil {
            loops.append(Task { [weak self] in await self?.startWebhooks() })
        } else {
            Task { await webhooks.stop() }
        }
    }

    private func startWebhooks() async {
        // A few tries: the port can take a moment to come free after a restart.
        for attempt in 1...5 {
            do {
                try await webhooks.start(port: Self.webhookPort) { [weak self] request in
                    await self?.webhook(request) ?? .notFound
                }
                if status[.teams] == nil { status[.teams] = ("Waiting for Teams at \(state.teams?.publicURL ?? "")", true) }
                return
            } catch {
                if attempt == 5 || Task.isCancelled {
                    status[.teams] = ("Couldn't listen for Teams on port \(Self.webhookPort): \(error)", false)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops = []
    }

    private func restart() {
        guard let deps else { return }
        start(deps)
    }

    // MARK: Settings

    public func overview() -> ChannelsOverview {
        ChannelsOverview(channels: ChannelKind.allCases.map(channelStatus), contacts: state.contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    private func channelStatus(_ kind: ChannelKind) -> ChannelStatus {
        let s = status[kind]
        switch kind {
        case .telegram:
            let configured = telegramToken != nil
            return ChannelStatus(kind: kind, enabled: isEnabled(kind), configured: configured,
                                 detail: s?.detail ?? (configured ? "Starting…" : "Add the bot's token from @BotFather"), healthy: s?.healthy ?? false, handle: telegramName)
        case .imessage:
            let readable = IMessageBridge.canRead
            return ChannelStatus(kind: kind, enabled: isEnabled(kind), configured: readable,
                                 detail: s?.detail ?? (readable ? "Ready" : "Needs Full Disk Access for Pennant Host to read replies"), healthy: s?.healthy ?? readable,
                                 settings: imessageSetup(readable: readable))
        case .teams:
            let configured = state.teams != nil && teamsSecret != nil
            let settings = state.teams.map { ["appID": $0.appID, "tenantID": $0.tenantID, "publicURL": $0.publicURL] }
            return ChannelStatus(kind: kind, enabled: isEnabled(kind), configured: configured,
                                 detail: s?.detail ?? (configured ? "Starting…" : "Not set up yet"), healthy: s?.healthy ?? false, settings: settings)
        }
    }

    private func isEnabled(_ kind: ChannelKind) -> Bool { state.enabled[kind.rawValue] ?? false }

    /// What Settings needs to guide the setup: the two grants (Full Disk Access to read, control of Messages to send)
    /// and which app to grant them to, the personal Apple ID switch, and the group chats to pick from.
    private func imessageSetup(readable: Bool) -> [String: String] {
        var out = ["personal": imessagePersonal ? "true" : "false", "groups": imessageGroups.map(\.name).joined(separator: "\n"),
                   "fullDiskAccess": readable ? "granted" : "missing", "messagesControl": messagesControl.rawValue,
                   "grantee": PermissionCheck.grantee()]
        if let path = PermissionCheck.granteeAppPath() { out["granteePath"] = path }
        return out
    }

    /// Whether this host may control Messages, checked while iMessage is on (unknown while Messages isn't running).
    private var messagesControl: PermissionState = .unknown

    /// Whether Messages on this Mac is a person's own Apple ID (see `State.imessagePersonal`).
    var imessagePersonal: Bool { state.imessagePersonal ?? true }

    /// What of an incoming text reaches Pennant: all of it on Pennant's own Apple ID; on a person's own, only a text
    /// addressed to Pennant (without the name), never its own replies coming back. Nil: not for Pennant.
    func imessageAccepts(_ text: String) -> String? {
        guard imessagePersonal else { return text }
        if IMessageBridge.isPennantsReply(text) || recentlySent(text) { return nil }
        return IMessageBridge.addressedToPennant(text)
    }

    /// What of a group chat message reaches Pennant: only a text addressed to it (as a mention in a Teams channel),
    /// never its own replies. From this Mac's Apple ID it's the owner's on a personal Apple ID, Pennant's own otherwise.
    /// While an agent's message to the group waits for an answer (`awaitingReply`), the next text from someone there is
    /// that answer, name or not.
    func imessageGroupAccepts(_ m: IMessageBridge.Incoming, awaitingReply: Bool = false, reviewOpen: Bool = false) -> String? {
        if m.fromMe, !imessagePersonal { return nil }
        if IMessageBridge.isPennantsReply(m.text) || recentlySent(m.text) { return nil }
        // With a review batch waiting here, "approve all" is for Pennant, name or not.
        if reviewOpen, ReviewService.intent(m.text) != nil { return m.text }
        if awaitingReply, !m.fromMe { return IMessageBridge.addressedToPennant(m.text) ?? m.text }
        return IMessageBridge.addressedToPennant(m.text)
    }

    /// An iMessage group chat, shared by everyone in it: its address is the chat's name in Messages, and
    /// `details["group"]` its identifier once found there.
    static func isIMessageGroup(_ c: ChannelContact) -> Bool { c.kind == .imessage && c.details?["type"] == "group" }

    /// The named group chats in Messages, checked every minute (and sooner while a group contact isn't found).
    private var imessageGroups: [IMessageBridge.GroupChat] = []
    private var imessageGroupsCheckedAt = Date.distantPast

    /// Group contacts get their chat's identifier from its name. True when a contact changed.
    func resolveIMessageGroups(_ chats: [IMessageBridge.GroupChat]) -> Bool {
        var changed = false
        for i in state.contacts.indices where Self.isIMessageGroup(state.contacts[i]) && state.contacts[i].details?["group"] == nil {
            let name = state.contacts[i].address
            guard let chat = chats.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else { continue }
            state.contacts[i].details?["group"] = chat.identifier
            changed = true
        }
        return changed
    }

    public func setIMessagePersonal(_ on: Bool) throws {
        state.imessagePersonal = on
        try save()
    }

    /// What Pennant sent by iMessage lately, to know it when it comes back (a person texting themselves).
    private var sentTexts: [(text: String, at: Date)] = []
    private func rememberSent(_ text: String) {
        sentTexts.removeAll { $0.at < Date().addingTimeInterval(-600) }
        sentTexts.append((text.trimmingCharacters(in: .whitespacesAndNewlines), Date()))
    }
    private func recentlySent(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentTexts.contains { $0.text == t && $0.at > Date().addingTimeInterval(-600) }
    }

    public func setEnabled(_ kind: ChannelKind, _ on: Bool) throws {
        state.enabled[kind.rawValue] = on
        if kind == .imessage, on, state.imessageRowID == 0 { state.imessageRowID = (try? IMessageBridge.latestRowID()) ?? 0 }
        status[kind] = nil
        try save()
        restart()
    }

    private var telegramToken: String? { keychain.get(account: Self.telegramTokenAccount)?.nilIfEmpty }
    private var teamsSecret: String? { keychain.get(account: Self.teamsSecretAccount)?.nilIfEmpty }

    /// The Teams bot's registration. The secret goes to the Keychain (kept when not given); the rest to channels.json.
    public func setTeams(appID: String, tenantID: String, publicURL: String, secret: String?) throws {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard UUID(uuidString: trim(appID)) != nil, UUID(uuidString: trim(tenantID)) != nil else {
            throw ToolError.invalidArguments("The app id and tenant id are GUIDs from the bot's Entra app registration.")
        }
        guard trim(publicURL).hasPrefix("https://") else { throw ToolError.invalidArguments("Teams needs an https address for the webhook.") }
        if let secret = secret.map(trim), !secret.isEmpty { try keychain.set(account: Self.teamsSecretAccount, value: secret) }
        guard teamsSecret != nil else { throw ToolError.invalidArguments("Add the bot's client secret.") }
        state.teams = TeamsBot.Config(appID: trim(appID), tenantID: trim(tenantID), publicURL: trim(publicURL))
        state.enabled[ChannelKind.teams.rawValue] = true
        status[.teams] = nil
        try save()
        restart()
    }

    /// Checks the token with Telegram, keeps it in the Keychain, and turns Telegram on.
    public func setTelegramToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        telegramName = try await TelegramBot(token: trimmed).username()
        try keychain.set(account: Self.telegramTokenAccount, value: trimmed)
        state.enabled[ChannelKind.telegram.rawValue] = true
        status[.telegram] = ("Connected as @\(telegramName!)", true)
        try save()
        restart()
    }

    /// A one-time code (and a link) that ties a chat to a person: they send it to the bot.
    public func linkCode(kind: ChannelKind, personID: PersonID?, name: String) throws -> ChannelLinkCode {
        let code = String((0 ..< 8).map { _ in Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789").randomElement()! })
        let expires = Date().addingTimeInterval(30 * 60)
        state.links = state.links.filter { $0.value.expiresAt > Date() }
        state.links[code] = .init(kind: kind, personID: personID, name: name, expiresAt: expires)
        try save()
        let url = kind == .telegram ? telegramName.map { "https://t.me/\($0)?start=\(code)" } : nil
        return ChannelLinkCode(kind: kind, code: code, url: url, expiresAt: expires)
    }

    public func upsert(_ contact: ChannelContact) throws {
        var c = contact
        c.address = c.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.address.isEmpty else { throw ToolError.invalidArguments("A contact needs an address") }
        if let i = state.contacts.firstIndex(where: { $0.id == c.id }) { state.contacts[i] = c } else { state.contacts.append(c) }
        try save()
    }

    public func remove(_ id: String) throws {
        state.contacts.removeAll { $0.id == id }
        try save()
    }

    public var contacts: [ChannelContact] { state.contacts }

    // MARK: Sending

    public enum SendOutcome: Sendable { case sent(ChannelContact), needsApproval(ChannelContact, token: String) }

    /// Finds who is meant: a contact's name or address, or a person's name, on the given channel or any.
    public func resolve(_ who: String, channel: ChannelKind?) -> ChannelContact? {
        let q = who.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = state.contacts.filter { channel == nil || $0.kind == channel }
            .filter { isEnabled($0.kind) || $0.kind == .teams }
        let key = IMessageBridge.normalize(q)
        let exact = candidates.filter { $0.name.lowercased() == q || $0.address.lowercased() == q || (!key.isEmpty && IMessageBridge.normalize($0.address) == key) }
        let pool = exact.isEmpty ? candidates.filter { $0.name.lowercased().contains(q) } : exact
        // The channel they last used first.
        return pool.sorted { ($0.lastMessageAt ?? $0.linkedAt) > ($1.lastMessageAt ?? $1.linkedAt) }.first
    }

    /// An agent writes to someone. Allowed contacts get it now; anyone else waits on an approval card (the caller
    /// posts it with the returned token). Either way their reply comes back to this agent's conversation.
    public func send(_ text: String, to contact: ChannelContact, from agentID: AgentID, conversationID: ConversationID) async throws -> SendOutcome {
        try await send(.text(text), to: contact, from: agentID, conversationID: conversationID)
    }

    /// Words or a card. Cards to people who need approval go through the card as text (what the approval shows).
    func send(_ outgoing: Outgoing, to contact: ChannelContact, from agentID: AgentID, conversationID: ConversationID) async throws -> SendOutcome {
        routeReplies(contact.id, to: agentID, conversationID: conversationID)
        guard contact.allowed else {
            let token = UUID().uuidString
            approvedSends[token] = (contact.id, outgoing.fallbackText)
            return .needsApproval(contact, token: token)
        }
        try await deliver(outgoing, to: contact)
        return .sent(contact)
    }

    /// Posts to a chat from Pennant, with quick-reply buttons where the channel has them (a card in Teams); what
    /// someone taps comes back as their reply. Only to a chat agents may message freely.
    public func post(_ text: String, buttons: [String], to contactID: String) async throws {
        guard let contact = state.contacts.first(where: { $0.id == contactID }) else { throw ToolError.failed("That chat is gone.") }
        guard contact.allowed else { throw ToolError.failed("\(contact.name) isn't cleared for messages from agents (Settings › Channels).") }
        let outgoing = buttons.isEmpty ? Outgoing.text(text) : ChannelCards.simple(title: nil, text: text, facts: [], buttons: buttons)
        try await deliver(outgoing, to: contact)
    }

    /// Sends what the user approved on the card (their edits included). The token works once.
    public func sendApproved(token: String, text: String) async throws -> ChannelContact {
        guard let pending = approvedSends.removeValue(forKey: token), let contact = state.contacts.first(where: { $0.id == pending.contactID }) else {
            throw ToolError.failed("That send isn't waiting for approval (it was sent or cancelled).")
        }
        // The owner approved these exact words: they go out as written, unlabelled.
        try await deliver(text, to: contact, labelled: false)
        return contact
    }

    private func routeReplies(_ contactID: String, to agentID: AgentID, conversationID: ConversationID) {
        guard let i = state.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        // Their own thread already goes to this conversation: nothing to redirect.
        if state.contacts[i].conversationID == conversationID { return }
        state.contacts[i].replyAgentID = agentID
        state.contacts[i].replyConversationID = conversationID
        state.contacts[i].replyUntil = Date().addingTimeInterval(Self.replyWindow)
        try? save()
    }

    /// Sends words or a card. Teams gets the card itself (returns its message id); other channels its text version.
    @discardableResult
    private func deliver(_ outgoing: Outgoing, to contact: ChannelContact) async throws -> String? {
        guard case .card(let card, let fallback) = outgoing else { try await deliver(outgoing.fallbackText, to: contact); return nil }
        guard contact.kind == .teams else { try await deliver(fallback, to: contact); return nil }
        if let cardSender {
            let id = try await cardSender(contact, card)
            touch(contact.id)
            return id
        }
        guard let config = state.teams, let secret = teamsSecret, let service = contact.details?["serviceURL"] else {
            throw ToolError.failed("Teams isn't set up (Settings › Channels), or \(contact.name) hasn't messaged the bot yet.")
        }
        let id = try await TeamsBot(config: config, secret: secret, session: .shared).send(card: card, summary: fallback, serviceURL: service, conversationID: contact.address, tokens: teamsTokens)
        touch(contact.id)
        return id
    }

    private func touch(_ contactID: String) {
        if let i = state.contacts.firstIndex(where: { $0.id == contactID }) { state.contacts[i].lastMessageAt = Date(); try? save() }
    }

    private func deliver(_ raw: String, to contact: ChannelContact, labelled: Bool = true) async throws {
        // On a person's own Apple ID, Pennant's texts are labelled as its own.
        var text = raw
        // Pennant's own words lose their markdown in Messages; words the owner approved go as written.
        if contact.kind == .imessage, labelled { text = IMessageBridge.plainText(raw) }
        if contact.kind == .imessage, imessagePersonal {
            if labelled { text = IMessageBridge.replyLabel + text }
            rememberSent(text)
        }
        if let sender {
            try await sender(contact, text)
            if let i = state.contacts.firstIndex(where: { $0.id == contact.id }) { state.contacts[i].lastMessageAt = Date() }
            return
        }
        switch contact.kind {
        case .telegram:
            guard let token = telegramToken else { throw ToolError.failed("Telegram isn't set up (Settings › Channels).") }
            try await TelegramBot(token: token).send(text, to: contact.address)
        case .imessage:
            guard isEnabled(.imessage) else { throw ToolError.failed("iMessage is off (Settings › Channels).") }
            if Self.isIMessageGroup(contact) {
                guard let group = contact.details?["group"] else { throw ToolError.failed("Messages has no group chat named \(contact.address) (yet).") }
                try await IMessageBridge().send(text, toGroup: group)
            } else {
                try await IMessageBridge().send(text, to: contact.address)
            }
        case .teams:
            guard let config = state.teams, let secret = teamsSecret, let service = contact.details?["serviceURL"] else {
                throw ToolError.failed("Teams isn't set up (Settings › Channels), or \(contact.name) hasn't messaged the bot yet.")
            }
            try await TeamsBot(config: config, secret: secret, session: .shared).send(text, serviceURL: service, conversationID: contact.address, tokens: teamsTokens)
        }
        if let i = state.contacts.firstIndex(where: { $0.id == contact.id }) { state.contacts[i].lastMessageAt = Date(); try? save() }
    }

    // MARK: Receiving

    /// Something arrived from a contact: into the outreach conversation while one is waiting on them, else their
    /// own thread (made with the built-in assistant on first use).
    /// `speaker`: who said it, in a channel or group chat shared by several people.
    func received(_ text: String, from contactID: String, speaker: MessageAuthor? = nil) async {
        guard var contact = state.contacts.first(where: { $0.id == contactID }) else { return }
        // An approval for a review batch is answered right here.
        let isGroup = contact.details?["group"] != nil || Self.isIMessageGroup(contact)
        let keys = speaker.map { [$0.id.rawValue] } ?? Array(reviewKeys(of: contact))
        if let reviewHook, let answer = await reviewHook(text, contact, keys, isGroup) {
            try? await deliver(answer, to: contact)
            return
        }
        guard let deps else { return }
        let author = speaker ?? MessageAuthor(id: contact.personID ?? PersonID("contact:\(contact.id)"), name: contact.name)
        let place = "the shared \(contact.kind.title) \(contact.details?["type"] == "channel" ? "channel" : "chat") \"\(contact.name)\""
        let outreach = (contact.replyUntil ?? .distantPast) > Date() && contact.replyAgentID != nil && contact.replyConversationID != nil
        let body = speaker == nil ? "\(text)\n\n[via \(contact.kind.title)]"
            // An answer to an agent's message lands in that agent's conversation, which isn't posted back there.
            : outreach ? "\(text)\n\n[\(author.name), replying in \(place) to your message. To answer them, use send_message to \"\(contact.name)\".]"
            : "\(text)\n\n[\(author.name), in \(place). Everyone there sees your answer: Pennant posts your reply in that thread, so just answer. Don't use send_message or Teams tools to reply.]"
        do {
            if outreach, let agent = contact.replyAgentID, let conversation = contact.replyConversationID {
                // An outreach gets one reply; after it, they're talking to Pennant in their own thread again.
                _ = try await deps.submit(agent, conversation, body, author)
                contact.replyAgentID = nil
                contact.replyConversationID = nil
                contact.replyUntil = nil
            } else {
                let fallback = await deps.defaultAgent()
                guard let agent = contact.agentID ?? fallback else { return }
                let conversation = try await deps.submit(agent, contact.conversationID, body, author)
                contact.agentID = agent
                contact.conversationID = conversation
            }
            contact.lastMessageAt = Date()
            if let i = state.contacts.firstIndex(where: { $0.id == contactID }) { state.contacts[i] = contact }
            try? save()
        } catch {
            log.warn("Couldn't deliver a \(contact.kind.title) message from \(contact.name): \(error)", category: "channels")
        }
    }

    private func telegramLoop() async {
        guard let token = telegramToken else { return }
        let bot = TelegramBot(token: token)
        if telegramName == nil { telegramName = try? await bot.username() }
        var failures = 0
        while !Task.isCancelled {
            do {
                let updates = try await bot.updates(after: state.telegramOffset)
                status[.telegram] = ("Connected as @\(telegramName ?? "bot")", true)
                failures = 0
                for u in updates {
                    state.telegramOffset = max(state.telegramOffset, u.updateID + 1)
                    guard u.isPrivate, !u.chatID.isEmpty, !u.text.isEmpty else { continue }
                    await telegramMessage(u, bot: bot)
                }
                if !updates.isEmpty { try? save() }
            } catch {
                if Task.isCancelled { return }
                failures += 1
                status[.telegram] = (String(describing: error), false)
                try? await Task.sleep(for: .seconds(min(60, 5 * failures)))
            }
        }
    }

    private func telegramMessage(_ u: TelegramBot.Incoming, bot: TelegramBot) async {
        if let contact = state.contacts.first(where: { $0.kind == .telegram && $0.address == u.chatID }) {
            await received(u.text, from: contact.id)
            return
        }
        // Linking: "/start CODE" from the link, or the code on its own.
        let word = u.text.replacingOccurrences(of: "/start", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let link = state.links[word], link.kind == .telegram, link.expiresAt > Date() {
            state.links[word] = nil
            let contact = ChannelContact(kind: .telegram, address: u.chatID, name: link.name.isEmpty ? u.senderName : link.name, personID: link.personID, allowed: true)
            state.contacts.append(contact)
            try? save()
            try? await bot.send("Linked. This chat now reaches Pennant, and agents can reach you here.", to: u.chatID)
            await deps?.notice("\(contact.name) linked Telegram.")
            return
        }
        // A stranger: say so once.
        if !state.refusedChats.contains(u.chatID) {
            state.refusedChats.append(u.chatID)
            try? save()
            try? await bot.send("This is a private Pennant bot. Ask its owner for a link from Settings › Channels.", to: u.chatID)
        }
    }

    private func imessageLoop() async {
        while !Task.isCancelled {
            let people = state.contacts.filter { $0.kind == .imessage && !Self.isIMessageGroup($0) }
            let groups = state.contacts.filter(Self.isIMessageGroup)
            // Once granted it stays so; until then, keep checking (unknown while Messages isn't running).
            if messagesControl != .granted {
                let control = PermissionCheck.automation(target: PermissionCheck.messagesBundleID)
                if control != .unknown { messagesControl = control }
            }
            do {
                if state.imessageRowID == 0 { state.imessageRowID = try IMessageBridge.latestRowID() }
                if Date().timeIntervalSince(imessageGroupsCheckedAt) > 60 || groups.contains(where: { $0.details?["group"] == nil }) {
                    imessageGroups = try IMessageBridge.groupChats()
                    imessageGroupsCheckedAt = Date()
                    if resolveIMessageGroups(imessageGroups) { try? save() }
                }
                let after = state.imessageRowID
                let direct = try IMessageBridge.received(after: after, from: Set(people.map(\.address)))
                let groupIDs = Set(state.contacts.filter(Self.isIMessageGroup).compactMap { $0.details?["group"] })
                let inGroups = try IMessageBridge.received(after: after, inGroups: groupIDs)
                status[.imessage] = ("Ready", true)
                // Everything up to the newest row has been seen, even messages from people who aren't contacts.
                state.imessageRowID = max(state.imessageRowID, (try? IMessageBridge.latestRowID()) ?? state.imessageRowID)
                for m in (direct + inGroups).sorted(by: { $0.rowID < $1.rowID }) {
                    if let group = m.group {
                        guard let contact = state.contacts.first(where: { Self.isIMessageGroup($0) && $0.details?["group"] == group }),
                              let text = imessageGroupAccepts(m, awaitingReply: (contact.replyUntil ?? .distantPast) > Date(),
                                                              reviewOpen: await reviewOpen?(contact.id) ?? false) else { continue }
                        await received(text, from: contact.id, speaker: await imessageSpeaker(m))
                    } else {
                        guard let contact = people.first(where: { IMessageBridge.normalize($0.address) == IMessageBridge.normalize(m.handle) }),
                              let text = imessageAccepts(m.text) else { continue }
                        await received(text, from: contact.id)
                    }
                }
                try? save()
            } catch {
                status[.imessage] = (String(describing: error), false)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Who said something in a group chat: the owner (from this Mac's Apple ID), a contact, or their number.
    private func imessageSpeaker(_ m: IMessageBridge.Incoming) async -> MessageAuthor {
        if m.fromMe {
            let owner = await deps?.owner()
            return MessageAuthor(id: owner?.id ?? PersonID("owner"), name: owner?.name ?? NSFullUserName())
        }
        let handle = IMessageBridge.normalize(m.handle)
        let contact = state.contacts.first { $0.kind == .imessage && !Self.isIMessageGroup($0) && IMessageBridge.normalize($0.address) == handle }
        return MessageAuthor(id: contact?.personID ?? PersonID("imessage:\(handle)"), name: contact?.name ?? m.handle)
    }

    // MARK: Teams

    /// A webhook from Teams: only the one path, only with a valid token from Microsoft for this bot. Answered at
    /// once; the message is handled afterwards.
    func webhook(_ request: WebhookServer.Request) async -> WebhookServer.Response {
        guard request.method == "POST", request.path == Self.teamsPath, let config = state.teams else { return .notFound }
        do {
            try await teamsValidator.validate(authorization: request.header("authorization"), config: config)
        } catch {
            log.warn("Refused a Teams webhook: \(error)", category: "channels")
            return .unauthorized
        }
        guard let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any], let activity = TeamsBot.Activity(json) else {
            return WebhookServer.Response(status: 400)
        }
        Task { await self.teamsActivity(activity) }
        return .ok
    }

    func teamsActivity(_ a: TeamsBot.Activity) async {
        // Only people in the bot's own organisation.
        guard let config = state.teams, a.tenantID == config.tenantID else { return }
        if a.isGroup { return await teamsGroupActivity(a, config: config) }
        guard a.type == "message", a.conversationType == "personal", !a.text.isEmpty || a.value["pennant"] != nil else { return }
        status[.teams] = ("Connected · last message \(Date().formatted(date: .omitted, time: .shortened))", true)
        let details = ["serviceURL": a.serviceURL, "aad": a.fromAADObjectID, "tenant": a.tenantID]
        if let i = state.contacts.firstIndex(where: { $0.kind == .teams && $0.details?["group"] == nil && ($0.details?["aad"] == a.fromAADObjectID || $0.address == a.conversationID) }) {
            state.contacts[i].address = a.conversationID
            state.contacts[i].details = details
            try? save()
            // A card's button, or words.
            if a.value["pennant"] != nil { await cardSubmitted(a.value, from: state.contacts[i].id) } else { await received(a.text, from: state.contacts[i].id) }
            return
        }
        // Someone who signs in to Pennant with this Microsoft account: linked on their first message.
        if !a.fromAADObjectID.isEmpty, let person = await deps?.personForMicrosoftID(a.fromAADObjectID) {
            var contact = ChannelContact(kind: .teams, address: a.conversationID, name: person.name, personID: person.id, allowed: true)
            contact.details = details
            state.contacts.append(contact)
            try? save()
            await deps?.notice("\(person.name) linked Teams.")
            await received(a.text, from: contact.id)
            return
        }
        // A link code, as on Telegram.
        let word = a.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let link = state.links[word], link.kind == .teams, link.expiresAt > Date() {
            state.links[word] = nil
            var contact = ChannelContact(kind: .teams, address: a.conversationID, name: link.name.isEmpty ? a.fromName : link.name, personID: link.personID, allowed: true)
            contact.details = details
            state.contacts.append(contact)
            try? save()
            try? await deliver("Linked. This chat now reaches Pennant, and agents can reach you here.", to: contact)
            await deps?.notice("\(contact.name) linked Teams.")
            return
        }
        let key = "teams:\(a.fromAADObjectID)"
        if !state.refusedChats.contains(key), let secret = teamsSecret {
            state.refusedChats.append(key)
            try? save()
            try? await TeamsBot(config: config, secret: secret, session: .shared).send("This is a private Pennant bot. Ask its owner to invite you to Pennant.", serviceURL: a.serviceURL, conversationID: a.conversationID, tokens: teamsTokens)
        }
    }

    /// A team channel or group chat. Teams only sends the bot messages that @mention it there. The channel is one
    /// contact with one conversation, shared by everyone in it: someone with a Pennant account connects it by
    /// mentioning the bot once (or with a link code), and after that anyone there can ask. Each message carries
    /// who said it, replies go to the thread it was asked in, and approvals still need a Pennant account.
    private func teamsGroupActivity(_ a: TeamsBot.Activity, config: TeamsBot.Config) async {
        let key = a.groupKey
        let place = a.placeName ?? (a.conversationType == "channel" ? "Teams channel" : "Teams group chat")
        let kind = a.conversationType == "channel" ? "channel" : "chat"
        let details = ["serviceURL": a.serviceURL, "tenant": a.tenantID, "group": key, "type": a.conversationType]
        let linked = state.contacts.firstIndex { $0.kind == .teams && $0.details?["group"] == key }

        if a.type == "conversationUpdate" {
            // Added to a team or chat: say how to start, once.
            guard linked == nil, a.membersAdded.contains(a.botID) else { return }
            await teamsSay("Hi, I'm Pennant. Someone here with a Pennant account needs to @mention me once to connect this \(kind); after that, anyone here can @mention me to ask the agents.", to: a, config: config)
            return
        }
        guard a.type == "message", !a.text.isEmpty || a.value["pennant"] != nil else { return }
        status[.teams] = ("Connected · last message \(Date().formatted(date: .omitted, time: .shortened))", true)
        let person = a.fromAADObjectID.isEmpty ? nil : await deps?.personForMicrosoftID(a.fromAADObjectID)
        let speaker = MessageAuthor(id: person?.id ?? PersonID("teams:\(a.fromAADObjectID.nilIfEmpty ?? a.fromID)"), name: person?.name ?? a.fromName)

        if let i = linked {
            state.contacts[i].address = a.conversationID       // answers go to the thread this was asked in
            state.contacts[i].details = details
            if let name = a.placeName { state.contacts[i].name = name }
            try? save()
            let id = state.contacts[i].id
            if a.value["pennant"] != nil { await cardSubmitted(a.value, from: id, speaker: speaker, speakerHasAccount: person != nil) } else { await received(a.text, from: id, speaker: speaker) }
            return
        }

        // Not connected yet: a mention from someone with a Pennant account connects it, as does a link code.
        let word = a.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let code = state.links[word].flatMap { $0.kind == .teams && $0.expiresAt > Date() ? $0 : nil }
        guard person != nil || code != nil else {
            let refusal = "teams:\(key)"
            guard !state.refusedChats.contains(refusal) else { return }
            state.refusedChats.append(refusal)
            try? save()
            await teamsSay("Someone here with a Pennant account needs to @mention me once to connect this \(kind).", to: a, config: config)
            return
        }
        if code != nil { state.links[word] = nil }
        var contact = ChannelContact(kind: .teams, address: a.conversationID, name: place, allowed: true)
        contact.details = details
        state.contacts.append(contact)
        state.refusedChats.removeAll { $0 == "teams:\(key)" }
        try? save()
        await deps?.notice("\(speaker.name) connected Pennant to \(place) on Teams.")
        if code != nil {
            try? await deliver("Connected. Anyone here can @mention me to ask the agents.", to: contact)
        } else {
            await received(a.text, from: contact.id, speaker: speaker)
        }
    }

    private func teamsSay(_ text: String, to a: TeamsBot.Activity, config: TeamsBot.Config) async {
        if let sender {
            try? await sender(ChannelContact(kind: .teams, address: a.conversationID, name: a.placeName ?? "Teams"), text)
            return
        }
        guard let secret = teamsSecret else { return }
        try? await TeamsBot(config: config, secret: secret, session: .shared).send(text, serviceURL: a.serviceURL, conversationID: a.conversationID, tokens: teamsTokens)
    }

    // MARK: Relaying replies

    /// Replies already sent, so the end of a task doesn't send the same answer twice.
    private var relayed: [MessageID] = []

    /// What an agent says in a contact's own thread goes back to them as soon as it's said: every finished reply
    /// (a message with words and no tool call; narration always comes with one), and any question it stops to ask.
    /// When a task ends, its last reply is sent too if it hasn't been already.
    private func relayLoop() async {
        for await event in await eventBus.subscribe() {
            if Task.isCancelled { return }
            switch event.payload {
            case .messageAppended(let m), .messageFinalized(let m):
                await relayCards(in: m)
                guard Self.isReply(m), let contact = state.contacts.first(where: { $0.conversationID == m.conversationID }) else { continue }
                await relay(m, to: contact)
            case .taskTransition(let t) where t.to == .completed || t.to == .waitingForUser:
                guard let task = try? await store.task(t.taskID),
                      let contact = state.contacts.first(where: { $0.conversationID == task.conversationID }) else { continue }
                if t.to == .completed {
                    let messages = (try? await store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 400)) ?? []
                    guard let reply = messages.last(where: { $0.taskID == task.id && $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
                    await relay(reply, to: contact)
                } else if !task.stateReason.isEmpty {
                    await send(task.stateReason, to: contact)
                }
            default:
                continue
            }
        }
    }

    /// Cards in a message: approvals go to the contact whose thread it is and to everyone who asked for approvals
    /// (once each), and are updated everywhere when decided; choice questions and reports go to the thread's contact.
    private func relayCards(in m: Message) async {
        guard m.role == .assistant, !m.isStreaming else { return }
        // The conversation's own person, else the person whose conversation asked for this work (Pennant asked
        // Coder from someone's Teams chat: Coder's approvals and questions go to that chat, or nobody sees them).
        var threadContact = state.contacts.first { $0.conversationID == m.conversationID }
        if threadContact == nil, m.parts.contains(where: { if case .approval = $0 { return true }; if case .choices = $0 { return true }; return false }) {
            threadContact = await originContact(of: m.taskID)
        }
        let agentName = await deps?.agentName(m.agentID) ?? "Pennant"
        for part in m.parts {
            switch part {
            case .approval(let a) where a.state == .pending:
                guard state.approvalCards[a.id] == nil else { continue }
                state.approvalCards[a.id] = []
                var targets = state.contacts.filter { $0.forwardApprovals == true }
                if let threadContact, !targets.contains(where: { $0.id == threadContact.id }) { targets.append(threadContact) }
                for contact in targets {
                    do {
                        if let id = try await deliver(ChannelCards.approval(a, agentName: agentName), to: contact) {
                            state.approvalCards[a.id, default: []].append(.init(contactID: contact.id, activityID: id))
                        }
                    } catch {
                        log.warn("Couldn't send the approval card to \(contact.name): \(error)", category: "channels")
                    }
                }
                try? save()
            case .approval(let a):
                await updateApprovalCards(a, agentName: agentName)
            case .choices(let q) where q.answers == nil:
                guard let threadContact, let taskID = m.taskID, openChoiceCards[q.id] == nil else { continue }
                openChoiceCards[q.id] = (taskID, q)
                _ = try? await deliver(ChannelCards.choices(q, taskID: taskID, agentName: agentName), to: threadContact)
            case .report(let r):
                guard let threadContact else { continue }
                _ = try? await deliver(ChannelCards.report(r, agentName: agentName), to: threadContact)
            default:
                continue
            }
        }
    }

    /// Follows who asked for a task (another agent's task, a worker's parent), up to five hops, to a conversation a
    /// person is linked to.
    func originContact(of taskID: TaskID?) async -> ChannelContact? {
        var next = taskID
        var hops = 0
        while let id = next, hops < 5, let task = try? await store.task(id) {
            if hops > 0, let contact = state.contacts.first(where: { $0.conversationID == task.conversationID }) { return contact }
            next = task.requestedByTaskID ?? task.parentTaskID
            hops += 1
        }
        return nil
    }

    /// Pennant has a Teams bot to send from.
    var teamsBotReady: Bool { state.teams != nil && (teamsSecret != nil || sender != nil) }

    /// What happened to a Teams send through the Microsoft 365 connector: Pennant's bot sent it, or couldn't and says why.
    public enum TeamsRoute: Sendable {
        case handled(text: String, failed: Bool)
    }

    /// Every Teams message Pennant sends goes from Pennant's own bot, never the owner's account: into chats and
    /// channels it's in, and one-to-one to anyone in the organisation (their reply comes back to the agent). Where the
    /// bot can't go, nothing is sent and the agent is told. Nil: not a Teams send, or no Teams bot here (a fresh
    /// install, where the connector sends as the owner, as it always did).
    func routeTeamsSend(tool: String, arguments: JSONValue, agentID: AgentID, conversationID: ConversationID,
                        lookup: @Sendable (String) async -> (id: String, name: String)?) async -> TeamsRoute? {
        let kind = ["__teams_send_chat": "chat", "__teams_post_channel": "channel", "__teams_message_person": "person"].first { tool.hasSuffix($0.key) }?.value
        guard let kind, teamsBotReady, let text = arguments["text"]?.stringValue, !text.isEmpty else { return nil }
        let elsewhere = "Nothing was sent. Pennant only posts as itself: add Pennant to it in Teams, or message people one by one with teams_message_person."
        switch kind {
        case "chat", "channel":
            guard let key = arguments[kind == "chat" ? "chat_id" : "channel_id"]?.stringValue,
                  var contact = state.contacts.first(where: { $0.kind == .teams && $0.details?["group"] == key }) else {
                return .handled(text: "Pennant isn't in that \(kind), so it can't post there. \(elsewhere)", failed: true)
            }
            // A new message, or a reply in a channel thread.
            contact.address = kind == "channel" ? (arguments["reply_to"]?.stringValue.map { "\(key);messageid=\($0)" } ?? key) : key
            do {
                try await deliver(text, to: contact)
                return .handled(text: "Posted as Pennant in \(contact.name).", failed: false)
            } catch {
                return .handled(text: "Couldn't post as Pennant in \(contact.name): \(error). Nothing was sent.", failed: true)
            }
        default:
            guard let email = arguments["email"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(), !email.isEmpty else { return nil }
            do {
                let contact = try await teamsContact(email: email, lookup: lookup)
                _ = try await send(.text(text), to: contact, from: agentID, conversationID: conversationID)
                return .handled(text: "Sent to \(contact.name) as Pennant. Their reply comes back to this conversation.", failed: false)
            } catch {
                return .handled(text: "Couldn't message \(email) as Pennant: \(error). Nothing was sent.", failed: true)
            }
        }
    }

    /// Someone in the organisation as a Teams contact the bot can write to: known already, or found by email and a
    /// one-to-one chat opened with them.
    private func teamsContact(email: String, lookup: @Sendable (String) async -> (id: String, name: String)?) async throws -> ChannelContact {
        if let known = state.contacts.first(where: { $0.kind == .teams && $0.details?["group"] == nil && $0.details?["email"]?.lowercased() == email }) { return known }
        guard let found = await lookup(email), !found.id.isEmpty else { throw ToolError.failed("\(email) isn't in this organisation's directory") }
        if var known = state.contacts.first(where: { $0.kind == .teams && $0.details?["group"] == nil && $0.details?["aad"] == found.id }) {
            known.details?["email"] = email
            if let i = state.contacts.firstIndex(where: { $0.id == known.id }) { state.contacts[i] = known; try? save() }
            return known
        }
        guard let config = state.teams else { throw ToolError.failed("Teams isn't set up") }
        let service = state.contacts.compactMap { $0.kind == .teams ? $0.details?["serviceURL"] : nil }.first ?? "https://smba.trafficmanager.net/amer/"
        let conversation: String
        if sender != nil {
            conversation = "a:\(found.id)"   // tests
        } else {
            guard let secret = teamsSecret else { throw ToolError.failed("Teams isn't set up") }
            conversation = try await TeamsBot(config: config, secret: secret, session: .shared).startChat(withObjectID: found.id, serviceURL: service, tokens: teamsTokens)
        }
        // A colleague in the same organisation: agents may write to them without a card each time.
        var contact = ChannelContact(kind: .teams, address: conversation, name: found.name, allowed: true)
        contact.details = ["serviceURL": service, "aad": found.id, "tenant": config.tenantID, "email": email]
        state.contacts.append(contact)
        try? save()
        return contact
    }

    /// A decided approval: its cards lose their buttons and say who decided what.
    private func updateApprovalCards(_ a: ApprovalRequest, agentName: String) async {
        guard let refs = state.approvalCards.removeValue(forKey: a.id), !refs.isEmpty else { return }
        try? save()
        guard case .card(let card, let summary) = ChannelCards.approval(a, agentName: agentName) else { return }
        for ref in refs {
            guard let contact = state.contacts.first(where: { $0.id == ref.contactID }) else { continue }
            if let cardSender { _ = try? await cardSender(contact, card); continue }
            guard let config = state.teams, let secret = teamsSecret, let service = contact.details?["serviceURL"] else { continue }
            do {
                try await TeamsBot(config: config, secret: secret, session: .shared).update(activityID: ref.activityID, card: card, summary: summary,
                                                                                            serviceURL: service, conversationID: contact.address, tokens: teamsTokens)
            } catch {
                log.warn("Couldn't update the approval card for \(contact.name): \(error)", category: "channels")
            }
        }
    }

    /// A card's button was tapped: decide the approval, answer the questions, or pass the button's words on as
    /// the person's reply. Only people linked to Pennant can decide approvals.
    /// In a channel or group chat, `speaker` is who pressed the button; only someone with a Pennant account decides.
    func cardSubmitted(_ value: [String: String], from contactID: String, speaker: MessageAuthor? = nil, speakerHasAccount: Bool = false) async {
        guard let deps, let contact = state.contacts.first(where: { $0.id == contactID }) else { return }
        let author = speaker ?? MessageAuthor(id: contact.personID ?? PersonID("contact:\(contact.id)"), name: contact.name)
        let hasAccount = speaker == nil ? contact.personID != nil : speakerHasAccount
        do {
            switch value["pennant"] {
            case "approval":
                guard hasAccount else { throw ToolError.failed("Only people with a Pennant account can decide approvals.") }
                guard let id = value["approvalID"], let raw = value["verdict"], let verdict = ApprovalDecision.Verdict(rawValue: raw) else { return }
                let comment = value["comment"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                if verdict == .requestChanges, comment == nil { throw ToolError.failed("Add a note saying what to change, then tap Request changes again.") }
                try await deps.decideApproval(ApprovalDecision(approvalID: id, verdict: verdict, comment: comment), author)
            case "choices":
                guard let qid = value["questionID"], let open = openChoiceCards[qid] else { throw ToolError.failed("Those questions were already answered.") }
                let answers = ChannelCards.answers(open.question, from: value)
                guard answers.count == open.question.items.count else { throw ToolError.failed("Answer each question, then tap Send.") }
                try await deps.answerChoices(open.taskID, qid, answers, author)
                openChoiceCards[qid] = nil
                try? await deliver("Got it — \(answers.values.joined(separator: "; ")).", to: contact)
            case "reply":
                if let text = value["text"], !text.isEmpty { await received(text, from: contactID, speaker: speaker) }
            default:
                return
            }
        } catch {
            try? await deliver(String(describing: error), to: contact)
        }
    }

    static func isReply(_ m: Message) -> Bool {
        m.role == .assistant && !m.isStreaming && m.toolCalls.isEmpty && !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !TaskRuntime.isDoneMarker(m.text)
    }

    private func relay(_ m: Message, to contact: ChannelContact) async {
        guard !relayed.contains(m.id) else { return }
        relayed.append(m.id)
        if relayed.count > 500 { relayed.removeFirst(relayed.count - 500) }
        await send(m.text, to: contact)
    }

    private func send(_ text: String, to contact: ChannelContact) async {
        do { try await deliver(text, to: contact) } catch {
            log.warn("Couldn't relay to \(contact.name) on \(contact.kind.title): \(error)", category: "channels")
        }
    }

    private func save() throws {
        try JSONCodec.encode(state).write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
