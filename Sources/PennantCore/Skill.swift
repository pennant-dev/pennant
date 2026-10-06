import Foundation

public enum SkillStatus: String, Codable, Sendable, CaseIterable {
    /// Learned from one successful run; revalidate uncertain steps during use.
    case provisional
    /// Enough successful reuse to trust by default.
    case validated
    case disabled
}

public struct SkillStep: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var instruction: String
    /// Preferred tool for the step, if any.
    public var tool: String?
    /// Suggested tool arguments as a template; `{{input}}` placeholders are substituted.
    public var arguments: JSONValue?
    /// How to verify the step succeeded.
    public var check: String
    /// Whether this step has failed before and should be re-observed before trusting.
    public var uncertain: Bool

    public init(id: String = UUID().uuidString.lowercased(), instruction: String, tool: String? = nil, arguments: JSONValue? = nil, check: String = "", uncertain: Bool = false) {
        self.id = id
        self.instruction = instruction
        self.tool = tool
        self.arguments = arguments
        self.check = check
        self.uncertain = uncertain
    }
}

public struct SkillOutcome: Hashable, Codable, Sendable {
    public var taskID: TaskID
    public var succeeded: Bool
    public var note: String
    public var at: Date

    public init(taskID: TaskID, succeeded: Bool, note: String = "", at: Date = Date()) {
        self.taskID = taskID
        self.succeeded = succeeded
        self.note = note
        self.at = at
    }
}

/// A versioned learned procedure. Creating a skill never expands the agent's access.
public struct Skill: Hashable, Codable, Sendable, Identifiable {
    public var id: SkillID
    public var name: String
    public var version: Int
    public var purpose: String
    public var applicability: String
    public var prerequisites: [String]
    public var inputs: [String]
    public var steps: [SkillStep]
    public var expectedResult: String
    public var failureConditions: [String]
    /// Supporting scripts keyed by file name (shell, AppleScript, JXA).
    public var scripts: [String: String]
    public var status: SkillStatus
    public var evidenceTaskIDs: [TaskID]
    public var outcomes: [SkillOutcome]
    public var createdByAgentID: AgentID?
    public var previousVersionID: SkillID?
    public var createdAt: Date
    public var updatedAt: Date
    /// "learned" (by an agent), "builtin" (shipped with Pennant), "imported" (from a SKILL.md folder), or "claude-code"
    /// (linked from Claude Code and kept in step with its file).
    public var origin: String
    /// Full instructions in Markdown (the SKILL.md body for imported skills). Shown to the model by use_skill.
    public var body: String
    /// Where an imported skill came from, for display and re-import.
    public var sourcePath: String?
    /// The cards this skill produces (a report, an approval gate), declared in its SKILL.md.
    public var outputs: SkillOutputs?
    /// For a skill linked from Claude Code that leans on what only Claude Code has: why ("it starts subagents").
    /// use_skill hands such a skill to a Claude Code run. Nil: Pennant follows it itself.
    public var needsClaudeCode: String?

    public init(id: SkillID = SkillID(), name: String, version: Int = 1, purpose: String, applicability: String = "", prerequisites: [String] = [], inputs: [String] = [], steps: [SkillStep] = [], expectedResult: String = "", failureConditions: [String] = [], scripts: [String: String] = [:], status: SkillStatus = .provisional, evidenceTaskIDs: [TaskID] = [], outcomes: [SkillOutcome] = [], createdByAgentID: AgentID? = nil, previousVersionID: SkillID? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), origin: String = "learned", body: String = "", sourcePath: String? = nil, outputs: SkillOutputs? = nil, needsClaudeCode: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.purpose = purpose
        self.applicability = applicability
        self.prerequisites = prerequisites
        self.inputs = inputs
        self.steps = steps
        self.expectedResult = expectedResult
        self.failureConditions = failureConditions
        self.scripts = scripts
        self.status = status
        self.evidenceTaskIDs = evidenceTaskIDs
        self.outcomes = outcomes
        self.createdByAgentID = createdByAgentID
        self.previousVersionID = previousVersionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.origin = origin
        self.body = body
        self.sourcePath = sourcePath
        self.outputs = outputs
        self.needsClaudeCode = needsClaudeCode
    }

    private enum CodingKeys: String, CodingKey { case id, name, version, purpose, applicability, prerequisites, inputs, steps, expectedResult, failureConditions, scripts, status, evidenceTaskIDs, outcomes, createdByAgentID, previousVersionID, createdAt, updatedAt, origin, body, sourcePath, outputs, needsClaudeCode }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SkillID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        applicability = try c.decodeIfPresent(String.self, forKey: .applicability) ?? ""
        prerequisites = try c.decodeIfPresent([String].self, forKey: .prerequisites) ?? []
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? []
        steps = try c.decodeIfPresent([SkillStep].self, forKey: .steps) ?? []
        expectedResult = try c.decodeIfPresent(String.self, forKey: .expectedResult) ?? ""
        failureConditions = try c.decodeIfPresent([String].self, forKey: .failureConditions) ?? []
        scripts = try c.decodeIfPresent([String: String].self, forKey: .scripts) ?? [:]
        status = try c.decodeIfPresent(SkillStatus.self, forKey: .status) ?? .provisional
        evidenceTaskIDs = try c.decodeIfPresent([TaskID].self, forKey: .evidenceTaskIDs) ?? []
        outcomes = try c.decodeIfPresent([SkillOutcome].self, forKey: .outcomes) ?? []
        createdByAgentID = try c.decodeIfPresent(AgentID.self, forKey: .createdByAgentID)
        previousVersionID = try c.decodeIfPresent(SkillID.self, forKey: .previousVersionID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "learned"
        outputs = try c.decodeIfPresent(SkillOutputs.self, forKey: .outputs)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        needsClaudeCode = try c.decodeIfPresent(String.self, forKey: .needsClaudeCode)
    }

    public var successRate: Double? {
        guard !outcomes.isEmpty else { return nil }
        return Double(outcomes.filter(\.succeeded).count) / Double(outcomes.count)
    }
}

extension Skill {
    /// The folder the skill was imported from (the one holding its SKILL.md), when it came from disk.
    public var folder: String? {
        guard let path = sourcePath, !path.isEmpty else { return nil }
        return path.hasSuffix(".md") ? (path as NSString).deletingLastPathComponent : path
    }

    /// Skill text with `{{skill_dir}}` replaced by the skill's folder, so a skill can name its scripts portably.
    public func expandingFolder(_ text: String) -> String {
        guard let folder else { return text }
        return text.replacingOccurrences(of: "{{skill_dir}}", with: folder)
    }
}

/// What a skill hands back besides its words, declared in SKILL.md front matter:
///   report: <title pattern>            report-sections: A; B; C
///   approval: <destination>            approval-label: Approve & send
///   approval-action: <tool>            approval-text-field: body           approval-details: Setting A; Setting B
public struct SkillOutputs: Hashable, Codable, Sendable {
    public var report: ReportOutput?
    public var approval: ApprovalOutput?
    /// `effort: high`: how hard to think while following the skill; raises the agent's own effort, never lowers it.
    public var effort: String?
    public init(report: ReportOutput? = nil, approval: ApprovalOutput? = nil, effort: String? = nil) { self.report = report; self.approval = approval; self.effort = effort }
    public var isEmpty: Bool { report == nil && approval == nil && effort == nil }

    public struct ReportOutput: Hashable, Codable, Sendable {
        /// The report's title, with {date} for today's date.
        public var title: String
        public var sections: [String]
        public init(title: String, sections: [String] = []) { self.title = title; self.sections = sections }
    }

    public struct ApprovalOutput: Hashable, Codable, Sendable {
        /// Where approved content goes: "YouTube · Company channel (Unlisted)".
        public var destination: String
        public var label: String?
        /// A tool Pennant runs itself on approval, with the approved text in `textField`.
        public var action: String?
        public var textField: String?
        /// Settings the card must carry (as approval details).
        public var details: [String]
        public init(destination: String, label: String? = nil, action: String? = nil, textField: String? = nil, details: [String] = []) {
            self.destination = destination; self.label = label; self.action = action; self.textField = textField; self.details = details
        }
    }

    /// The outputs as instructions for the agent following the skill.
    public var guide: String {
        var lines = ["Outputs this skill produces (Pennant shows them as cards):"]
        if let r = report {
            lines.append("- A report card: finish with post_report (title \"\(r.title)\"\(r.sections.isEmpty ? "" : ", sections in this order: " + r.sections.joined(separator: "; "))), then reply in one line. Short check-ins with nothing to report may skip it.")
        }
        if let a = approval {
            var line = "- An approval card before anything goes out: request_approval with destination \"\(a.destination)\""
            if let label = a.label { line += ", button \"\(label)\"" }
            if let action = a.action { line += ", on_approve {tool: \"\(action)\", text_field: \"\(a.textField ?? "body")\"}" }
            if !a.details.isEmpty { line += ", details for: " + a.details.joined(separator: "; ") }
            lines.append(line + ". Nothing is published, sent or changed without it.")
        }
        return lines.joined(separator: "\n")
    }
}
