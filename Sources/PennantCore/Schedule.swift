import Foundation

public enum ScheduleTag {}
public typealias ScheduleID = ID<ScheduleTag>

/// A recurring (or one-off) job: at each due time the host starts a task for the agent with the prompt,
/// optionally pointing at a skill to follow. Runs accumulate in one conversation per job.
public struct ScheduledJob: Hashable, Codable, Sendable, Identifiable {
    public var id: ScheduleID
    public var name: String
    public var agentID: AgentID
    public var skillID: SkillID?
    /// What the agent is asked to do each run.
    public var prompt: String
    /// Schedule expression: `every 15m`, `every 2h`, `hourly`, `daily at 09:00`, `weekdays at 08:30`,
    /// `weekly on mon,thu at 18:00`, `monthly on 1 at 07:00`, `once at 2026-10-01 09:00`, or 5-field cron.
    public var schedule: String
    public var timeZone: String
    public var enabled: Bool
    public var conversationID: ConversationID?
    /// Start a new conversation for every run instead of continuing one (content jobs that should begin from a
    /// clean slate each time, relying on their own logs rather than a long chat history). Nil means continue.
    public var freshConversation: Bool?
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var lastTaskID: TaskID?
    public var lastOutcome: String?
    public var runCount: Int
    public var createdByAgentID: AgentID?
    public var createdAt: Date
    public var updatedAt: Date
    /// A goal's work session or weekly review: the prompt is written from the goal and its board at each run.
    public var goalID: GoalID?
    /// "work" or "review", for a goal's jobs.
    public var goalRun: String?

    public init(id: ScheduleID = ScheduleID(), name: String, agentID: AgentID, skillID: SkillID? = nil, prompt: String, schedule: String, timeZone: String = TimeZone.current.identifier, enabled: Bool = true, conversationID: ConversationID? = nil, nextRunAt: Date? = nil, lastRunAt: Date? = nil, lastTaskID: TaskID? = nil, lastOutcome: String? = nil, runCount: Int = 0, createdByAgentID: AgentID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.skillID = skillID
        self.prompt = prompt
        self.schedule = schedule
        self.timeZone = timeZone
        self.enabled = enabled
        self.conversationID = conversationID
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastTaskID = lastTaskID
        self.lastOutcome = lastOutcome
        self.runCount = runCount
        self.createdByAgentID = createdByAgentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A folder that holds skills from another harness (Claude Code, Codex, the Agent Skills standard).
public struct SkillLocation: Hashable, Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var harness: String
    public var skillCount: Int
    /// "known" (a harness's standard folder), "custom" (a folder the user added), or "git" (a cloned repository).
    public var kind: String
    /// For git locations, the repository URL it was cloned from.
    public var origin: String?
    public init(path: String, harness: String, skillCount: Int, kind: String = "known", origin: String? = nil) {
        self.path = path
        self.harness = harness
        self.skillCount = skillCount
        self.kind = kind
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case path, harness, skillCount, kind, origin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? ""
        skillCount = try c.decodeIfPresent(Int.self, forKey: .skillCount) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "known"
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
    }
}

/// One importable skill found under a location, before anything is written.
public struct SkillPreviewItem: Hashable, Codable, Sendable, Identifiable {
    public var id: String { sourcePath }
    public var name: String
    public var purpose: String
    /// Path of the SKILL.md this skill would come from; pass it back in `importSkills(only:)`.
    public var sourcePath: String
    public var stepCount: Int
    public var scriptCount: Int
    /// Version already in the library with the same name, if any.
    public var existingVersion: Int?
    /// True when the library already holds identical content (import would skip it).
    public var unchanged: Bool
    public init(name: String, purpose: String, sourcePath: String, stepCount: Int, scriptCount: Int, existingVersion: Int?, unchanged: Bool) {
        self.name = name
        self.purpose = purpose
        self.sourcePath = sourcePath
        self.stepCount = stepCount
        self.scriptCount = scriptCount
        self.existingVersion = existingVersion
        self.unchanged = unchanged
    }
}

public struct SkillImportPreview: Hashable, Codable, Sendable {
    /// The resolved folder that was scanned (for a git URL, the local checkout).
    public var root: String
    public var items: [SkillPreviewItem]
    public var warnings: [String]
    public init(root: String, items: [SkillPreviewItem], warnings: [String]) {
        self.root = root
        self.items = items
        self.warnings = warnings
    }
}
