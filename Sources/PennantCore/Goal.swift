import Foundation

public enum GoalTag {}
public typealias GoalID = ID<GoalTag>
public enum GoalItemTag {}
public typealias GoalItemID = ID<GoalItemTag>

/// Something the owner wants achieved over weeks, not a single task. Its agent works toward it on its own: at each
/// work session it reads the goal and its board, picks the most valuable next item, works it and updates the board;
/// once a week it reviews progress. What it may do by itself is set by `freedom`; anything beyond that comes to the
/// owner as a card.
public struct Goal: Hashable, Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Drafted, waiting for the owner's approval.
        case proposed
        case active
        case paused
        case achieved
        case dropped
    }

    /// How much the agent does by itself.
    public enum Freedom: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Researches and writes proposals; everything else waits for the owner.
        case proposeOnly
        /// Works freely on this Mac (research, analysis, drafts, branches through the coding agent); anything that changes
        /// the outside world (posting, sending, merging, deploying, spending) goes to the owner as a card.
        case workFreely
        /// Also acts within the goal's limits and budget, and says what it did in its reports.
        case actWithinLimits

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .proposeOnly: return "Only propose"
            case .workFreely: return "Work freely, propose changes"
            case .actWithinLimits: return "Act within limits"
            }
        }
    }

    public var id: GoalID
    public var title: String
    /// What success looks like, in the owner's words.
    public var outcome: String
    /// How progress is judged (a number to watch, where it comes from).
    public var measure: String
    public var ownerAgentID: AgentID
    public var freedom: Freedom
    /// What it must never do, or only within bounds ("no posts on weekends", "no production changes").
    public var limits: String
    /// When it works on it (a schedule expression, e.g. "weekdays at 09:00") and when it reviews ("weekly on fri at 16:00").
    public var workSchedule: String
    public var reviewSchedule: String
    /// Most the goal's work may cost in model use over any 7 days, in US dollars; nil: no cap.
    public var weeklyBudget: Double?
    public var status: Status
    /// The goal's own conversation, where its sessions and reviews happen.
    public var conversationID: ConversationID?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastWorkedAt: Date?
    /// The skill every session and review follows (its newest version); nil: the agent finds its own way.
    public var skillID: SkillID?

    public init(id: GoalID = GoalID(), title: String, outcome: String, measure: String = "", ownerAgentID: AgentID, freedom: Freedom = .workFreely, limits: String = "",
                workSchedule: String = "weekdays at 09:00", reviewSchedule: String = "weekly on fri at 16:00", weeklyBudget: Double? = nil, status: Status = .proposed,
                conversationID: ConversationID? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), lastWorkedAt: Date? = nil) {
        self.id = id; self.title = title; self.outcome = outcome; self.measure = measure; self.ownerAgentID = ownerAgentID; self.freedom = freedom; self.limits = limits
        self.workSchedule = workSchedule; self.reviewSchedule = reviewSchedule; self.weeklyBudget = weeklyBudget; self.status = status
        self.conversationID = conversationID; self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastWorkedAt = lastWorkedAt
    }
}

/// One item on a goal's board: an idea, the next thing to do, work in progress, something waiting on the owner.
/// The agent keeps the board itself; the owner can move, drop or comment on any item.
public struct GoalItem: Hashable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable, Identifiable {
        case idea
        case next
        case doing
        /// Waiting on the owner (a card, a question, an approval).
        case waiting
        case done
        case dropped

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .idea: return "Ideas"
            case .next: return "Next"
            case .doing: return "Doing"
            case .waiting: return "Waiting on you"
            case .done: return "Done"
            case .dropped: return "Dropped"
            }
        }
    }

    public struct Note: Hashable, Codable, Sendable {
        public var text: String
        public var by: String
        public var at: Date
        public init(text: String, by: String, at: Date = Date()) { self.text = text; self.by = by; self.at = at }
    }

    public var id: GoalItemID
    public var goalID: GoalID
    public var title: String
    public var detail: String
    public var state: State
    /// Lower comes first within a state.
    public var rank: Int
    /// Progress notes and the owner's comments, oldest first.
    public var notes: [Note]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: GoalItemID = GoalItemID(), goalID: GoalID, title: String, detail: String = "", state: State = .next, rank: Int = 0, notes: [Note] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.goalID = goalID; self.title = title; self.detail = detail; self.state = state; self.rank = rank; self.notes = notes; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
