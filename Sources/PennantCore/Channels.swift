import Foundation

/// Where agents can reach people outside Pennant, and hear back from them.
public enum ChannelKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case telegram, imessage, teams
    public var id: String { rawValue }
    public var title: String {
        switch self { case .telegram: return "Telegram"; case .imessage: return "iMessage"; case .teams: return "Microsoft Teams" }
    }
}

/// Someone agents can message on a channel: a Telegram chat, an iMessage handle, a Teams user. Replies from them
/// arrive in the conversation of the agent that last wrote to them.
public struct ChannelContact: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var kind: ChannelKind
    /// The channel's address: a Telegram chat id, a phone number or email for iMessage, a Teams user id.
    public var address: String
    public var name: String
    /// The Pennant person this is, when known.
    public var personID: PersonID?
    /// Agents may message them without asking first. Without it, each message waits on an approval card.
    public var allowed: Bool
    /// Their own thread: when they write on their own, it goes to this agent's conversation, and the agent's
    /// replies are sent back to them.
    public var agentID: AgentID?
    public var conversationID: ConversationID?
    /// Outreach: an agent wrote to them from its own conversation; their next message (within `replyUntil`) goes
    /// back there as their reply, and nothing is relayed. After that one reply, they're in their own thread again.
    public var replyAgentID: AgentID?
    public var replyConversationID: ConversationID?
    public var replyUntil: Date?
    public var linkedAt: Date
    public var lastMessageAt: Date?
    /// What the channel needs besides the address: Teams keeps the service URL and the person's Entra object id.
    public var details: [String: String]?
    /// Every new approval card, from any agent, is sent here too (to decide from Teams, or read elsewhere).
    public var forwardApprovals: Bool?

    public init(id: String = UUID().uuidString, kind: ChannelKind, address: String, name: String, personID: PersonID? = nil, allowed: Bool = false,
                agentID: AgentID? = nil, conversationID: ConversationID? = nil, linkedAt: Date = Date(), lastMessageAt: Date? = nil) {
        self.id = id; self.kind = kind; self.address = address; self.name = name; self.personID = personID; self.allowed = allowed
        self.agentID = agentID; self.conversationID = conversationID; self.linkedAt = linkedAt; self.lastMessageAt = lastMessageAt
    }
}

/// One channel's setup and health, for Settings › Channels.
public struct ChannelStatus: Hashable, Codable, Sendable, Identifiable {
    public var kind: ChannelKind
    public var enabled: Bool
    /// Has what it needs to run (a token, permission…).
    public var configured: Bool
    /// "Connected as @pennant_bot", "Needs Full Disk Access", an error.
    public var detail: String
    public var healthy: Bool
    /// Telegram: the bot's username, for links.
    public var handle: String?
    /// Teams: the bot's app id, tenant and public webhook address (nothing secret).
    public var settings: [String: String]?
    public var id: String { kind.rawValue }

    public init(kind: ChannelKind, enabled: Bool, configured: Bool, detail: String, healthy: Bool, handle: String? = nil, settings: [String: String]? = nil) {
        self.kind = kind; self.enabled = enabled; self.configured = configured; self.detail = detail; self.healthy = healthy; self.handle = handle
        self.settings = settings
    }
}

public struct ChannelsOverview: Hashable, Codable, Sendable {
    public var channels: [ChannelStatus]
    public var contacts: [ChannelContact]
    public init(channels: [ChannelStatus] = [], contacts: [ChannelContact] = []) { self.channels = channels; self.contacts = contacts }
}

/// A one-time code that links a chat to a person: sent to the bot as `/start <code>`.
public struct ChannelLinkCode: Hashable, Codable, Sendable {
    public var kind: ChannelKind
    public var code: String
    /// A link that opens the chat with the code filled in (Telegram), when the channel has one.
    public var url: String?
    public var expiresAt: Date
    public init(kind: ChannelKind, code: String, url: String?, expiresAt: Date) { self.kind = kind; self.code = code; self.url = url; self.expiresAt = expiresAt }
}
