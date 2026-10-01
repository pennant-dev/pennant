import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    /// A named agent with a persistent identity and its own scoped memory.
    case persistent
    /// A task-scoped worker created by another agent. Leaves results with its parent and can be retired.
    case worker
}

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case thinking
    case acting
    case waitingForDesktop
    case waitingForUser
    case paused
    case error
    case retired
}

/// Which memories an agent reads and writes by default.
public struct MemoryScope: Hashable, Codable, Sendable {
    /// Scope label stored on memories this agent creates. `shared` is visible to every agent.
    public var label: String
    /// Additional scopes this agent may read.
    public var readableScopes: [String]

    public init(label: String, readableScopes: [String] = ["shared"]) {
        self.label = label
        self.readableScopes = readableScopes
    }
}

/// A persistent agent profile or a task-scoped worker.
/// Personality affects communication and role behaviour only; it never changes machine permissions.
public struct AgentProfile: Hashable, Codable, Sendable, Identifiable {
    public var id: AgentID
    public var kind: AgentKind
    public var name: String
    public var role: String
    /// Short description of voice and manner, e.g. "concise, dry, checks twice before acting".
    public var style: String
    /// Extra durable instructions appended to the system prompt.
    public var instructions: String
    public var memoryScope: MemoryScope
    /// Skill IDs this agent prefers. Empty means all enabled skills are eligible.
    public var skillIDs: [SkillID]
    /// Tool names this agent may use. Empty means the default tool set.
    public var toolAllowlist: [String]
    /// Tools only some agents get (`ToolAccess.granted`), given to this one by the owner. Agents can't change it.
    public var grantedTools: [String]?
    public var parentAgentID: AgentID?
    public var status: AgentStatus
    /// Current headline shown in the roster, e.g. "Filing invoice 042".
    public var statusLine: String
    /// Emoji or SF Symbol name used as the avatar.
    public var avatar: String
    public var accentColorHex: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The saved inference profile this agent runs on (`HostConfig.inferenceProfiles`); nil: the host's model.
    public var modelProfileID: String?
    /// Reasoning effort for this agent ("low", "medium", "high"); nil: the profile's or the host's.
    public var reasoningEffort: String?
    /// MCP servers whose tools this agent always sees. Others load when it calls `find_tools`.
    public var alwaysLoadedServers: [MCPServerID]?

    public init(
        id: AgentID = AgentID(),
        kind: AgentKind = .persistent,
        name: String,
        role: String,
        style: String = "",
        instructions: String = "",
        memoryScope: MemoryScope? = nil,
        skillIDs: [SkillID] = [],
        toolAllowlist: [String] = [],
        parentAgentID: AgentID? = nil,
        status: AgentStatus = .idle,
        statusLine: String = "",
        avatar: String = "flag:sparkle",
        accentColorHex: String = "#2F80ED",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.role = role
        self.style = style
        self.instructions = instructions
        self.memoryScope = memoryScope ?? MemoryScope(label: id.rawValue, readableScopes: ["shared"])
        self.skillIDs = skillIDs
        self.toolAllowlist = toolAllowlist
        self.parentAgentID = parentAgentID
        self.status = status
        self.statusLine = statusLine
        self.avatar = avatar
        self.accentColorHex = accentColorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A GitHub App coding runs act as (`HostConfig.Coding.gitHubApp`). The private key stays in the Vault; the host mints
/// a short-lived installation token for each coding session.
public struct GitHubAppIdentity: Hashable, Codable, Sendable {
    public var appID: Int
    public var installationID: Int
    /// The Vault entry holding the App's private key (.pem) as its secret.
    public var vaultEntry: String
    /// The App's slug; it acts on GitHub as "<slug>[bot]".
    public var slug: String
    public var botLogin: String { "\(slug)[bot]" }

    public init(appID: Int, installationID: Int, vaultEntry: String, slug: String) {
        self.appID = appID; self.installationID = installationID; self.vaultEntry = vaultEntry; self.slug = slug
    }
}

/// What does a coding run's work: the Claude Code CLI the owner installed and signed in to, or Pennant's own task
/// runtime on one of the models in Settings › Models.
public enum CodingEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode, pennant
    public var id: String { rawValue }
    public var title: String {
        switch self { case .claudeCode: return "Claude Code"; case .pennant: return "Pennant" }
    }

    /// Claude Code's models to offer for a conversation, by family, as the CLI names them (each one checked against
    /// the CLI; ids it doesn't know fall back silently to its default, so only ones it runs as asked are listed). The
    /// first, with no id, is the CLI's own default. Any other id can still be typed. The Pennant engine runs on the
    /// host's model profiles instead, so it lists none here.
    public var models: [CodingModel] {
        switch self {
        case .claudeCode:
            return [
                CodingModel(nil, family: "", title: "Default", note: "Opus 5.5 · 1M context"),
                CodingModel("claude-fable-5-1", family: "Fable", title: "Fable 5.1"),
                CodingModel("claude-fable-5", family: "Fable", title: "Fable 5"),
                CodingModel("claude-opus-5-5[1m]", family: "Opus", title: "Opus 5.5", note: "1M context"),
                CodingModel("claude-opus-5-5", family: "Opus", title: "Opus 5.5"),
                CodingModel("claude-opus-5", family: "Opus", title: "Opus 5"),
                CodingModel("claude-opus-4-6", family: "Opus", title: "Opus 4.6"),
                CodingModel("claude-opus-4-5", family: "Opus", title: "Opus 4.5"),
                CodingModel("claude-sonnet-5[1m]", family: "Sonnet", title: "Sonnet 5", note: "1M context"),
                CodingModel("claude-sonnet-5", family: "Sonnet", title: "Sonnet 5"),
                CodingModel("claude-sonnet-4-6", family: "Sonnet", title: "Sonnet 4.6"),
                CodingModel("claude-sonnet-4-5", family: "Sonnet", title: "Sonnet 4.5"),
                CodingModel("claude-haiku-4-5", family: "Haiku", title: "Haiku 4.5"),
            ]
        case .pennant: return []
        }
    }

    /// Families in menu order, each with its models.
    public var modelFamilies: [(family: String, models: [CodingModel])] {
        var order: [String] = []
        for m in models where !m.family.isEmpty && !order.contains(m.family) { order.append(m.family) }
        return order.map { f in (f, models.filter { $0.family == f }) }
    }

    /// A model's short name for a pill: "Opus 5.5 · 1M", or the id itself when it isn't in the list.
    public func modelTitle(_ id: String?) -> String {
        if let m = models.first(where: { $0.id == id }) { return m.note.contains("1M") && m.id != nil ? "\(m.title) · 1M" : m.title }
        // Family aliases (the newest of each) that earlier conversations were set to.
        switch id {
        case "opus": return "Opus (newest)"
        case "sonnet": return "Sonnet (newest)"
        case "haiku": return "Haiku (newest)"
        case "fable": return "Fable (newest)"
        default: return id ?? "Default"
        }
    }
}

/// One model a coding CLI can run.
public struct CodingModel: Sendable, Hashable, Identifiable {
    /// The CLI's name for it; nil is the CLI's default.
    public var id: String?
    public var family: String
    public var title: String
    public var note: String
    public init(_ id: String?, family: String, title: String, note: String = "") {
        self.id = id; self.family = family; self.title = title; self.note = note
    }
}

/// How a coding run asks before acting, per conversation, whichever engine runs it. Raw values are Claude Code's
/// `--permission-mode` names.
public enum CodingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Edits files and runs commands freely; only the owner's sign-offs (publishing or email, deleting, spending) ask first.
    case acceptEdits
    /// Every edit and command asks first.
    case manual
    /// Claude Code's own safety check decides; only what it would block asks. The Pennant engine, which has no such
    /// check, asks for the owner's sign-offs as in `acceptEdits`.
    case auto
    /// Reads and plans without changing anything, then asks you to approve the plan.
    case plan

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .acceptEdits: return "Only sign-offs ask"
        case .manual: return "Ask for everything"
        case .auto: return "Auto"
        case .plan: return "Plan first"
        }
    }
    public var detail: String {
        switch self {
        case .acceptEdits: return "Edits, runs commands and commits on its own; asks before publishing or sending email, deleting, or spending"
        case .manual: return "Asks before every edit and command"
        case .auto: return "Decides for itself; asks only when something looks risky"
        case .plan: return "Reads and plans, then asks you to approve before changing anything"
        }
    }
    public var symbol: String {
        switch self {
        case .acceptEdits: return "pencil"
        case .manual: return "hand.raised"
        case .auto: return "bolt"
        case .plan: return "list.bullet.clipboard"
        }
    }
}

/// Multiple-choice questions a coding CLI puts to the user (Claude Code's AskUserQuestion), drawn as a card to tap
/// through. Answers are keyed by question text, as the CLI expects them back.
public struct ChoiceQuestion: Hashable, Codable, Sendable, Identifiable {
    public struct Option: Hashable, Codable, Sendable {
        public var label: String
        public var description: String
        public init(label: String, description: String = "") { self.label = label; self.description = description }
    }
    public struct Item: Hashable, Codable, Sendable {
        public var question: String
        public var header: String
        public var multiSelect: Bool
        public var options: [Option]
        public init(question: String, header: String = "", multiSelect: Bool = false, options: [Option]) {
            self.question = question; self.header = header; self.multiSelect = multiSelect; self.options = options
        }
    }

    public var id: String
    public var items: [Item]
    /// Question text → answer: an option's label, several joined by ", ", or the person's own words. Nil while open.
    public var answers: [String: String]?
    public var answeredBy: MessageAuthor?

    public init(id: String = UUID().uuidString, items: [Item], answers: [String: String]? = nil, answeredBy: MessageAuthor? = nil) {
        self.id = id; self.items = items; self.answers = answers; self.answeredBy = answeredBy
    }

    /// One line per question, for previews, search and the model's context.
    public var summary: String {
        items.map { item in "\(item.question) → \(answers?[item.question] ?? "(waiting)")" }.joined(separator: "\n")
    }

    /// Reads Claude Code's AskUserQuestion input (`questions: [{question, header, multiSelect, options: [{label, description}]}]`).
    public init?(claudeInput input: JSONValue) {
        guard case .array(let raw)? = input["questions"] else { return nil }
        let items: [Item] = raw.compactMap { q in
            guard let text = q["question"]?.stringValue else { return nil }
            var options: [Option] = []
            if case .array(let opts)? = q["options"] {
                options = opts.compactMap { o in o["label"]?.stringValue.map { Option(label: $0, description: o["description"]?.stringValue ?? "") } }
            }
            var multi = false
            if case .bool(let b)? = q["multiSelect"] { multi = b }
            return Item(question: text, header: q["header"]?.stringValue ?? "", multiSelect: multi, options: options)
        }
        guard !items.isEmpty else { return nil }
        self.init(items: items)
    }
}
