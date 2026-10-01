import PennantCore
import Foundation

/// What a tool may touch while running. Handed to every invocation by the broker.
public struct ToolContext: Sendable {
    public var agentID: AgentID
    public var taskID: TaskID
    public var conversationID: ConversationID
    public var store: any StoreProtocol
    public var desktop: any DesktopControlling
    public var lease: DesktopLease
    public var config: HostConfig
    /// Set by the runtime so tools such as `delegate` can reach it without a dependency cycle.
    public var runtimeHooks: RuntimeHooks?
    /// The project a coding run on the Pennant engine works in; nil for any other task.
    public var project: ProjectScope?

    public init(agentID: AgentID, taskID: TaskID, conversationID: ConversationID, store: any StoreProtocol, desktop: any DesktopControlling, lease: DesktopLease, config: HostConfig, runtimeHooks: RuntimeHooks? = nil, project: ProjectScope? = nil) {
        self.agentID = agentID
        self.taskID = taskID
        self.conversationID = conversationID
        self.store = store
        self.desktop = desktop
        self.lease = lease
        self.config = config
        self.runtimeHooks = runtimeHooks
        self.project = project
    }

    /// Where relative paths and commands start: the project's folder in a coding run, else the host's working directory.
    public var workingDirectory: String { project?.folder ?? config.workingDirectory }

    /// A path to write to, resolved against the working directory. In a coding run it must lie inside the project.
    public func writablePath(_ raw: String) throws -> String {
        let path = PathResolver.resolve(raw, base: workingDirectory)
        if let project, !PathResolver.isInside(path, folder: project.folder) {
            throw ToolError.denied("\(path) is outside the project folder \(project.folder); a coding run writes only inside its project.")
        }
        return path
    }
}

/// A coding run's project: files are written only inside its folder, and commands run there with the environment of
/// the GitHub identity the run acts as.
public struct ProjectScope: Sendable {
    public var folder: String
    public var environment: [String: String]
    public init(folder: String, environment: [String: String] = [:]) { self.folder = folder; self.environment = environment }
}

/// Runtime capabilities exposed to tools that need to create work or ask the user.
public struct RuntimeHooks: Sendable {
    public var delegate: @Sendable (_ parentTaskID: TaskID, _ title: String, _ objective: String, _ completionCriteria: String, _ context: String, _ workerName: String?, _ workerRole: String?) async throws -> TaskID
    /// Delegation on a chosen model (a profile's name or id); nil in contexts without it.
    public var delegateOnModel: (@Sendable (_ parentTaskID: TaskID, _ title: String, _ objective: String, _ completionCriteria: String, _ context: String, _ workerName: String?, _ workerRole: String?, _ model: String?) async throws -> TaskID)? = nil
    public var awaitTask: @Sendable (_ taskID: TaskID, _ timeout: TimeInterval) async throws -> TaskRecord
    public var askUser: @Sendable (_ taskID: TaskID, _ question: String) async throws -> String
    public var learnSkill: @Sendable (_ taskID: TaskID, _ skill: Skill) async throws -> Skill
    public var scheduleJob: @Sendable (_ name: String, _ schedule: String, _ prompt: String, _ skillID: SkillID?) async throws -> ScheduledJob
    public var deleteSchedule: @Sendable (_ id: ScheduleID) async throws -> Void
    public var importSkills: @Sendable (_ path: String) async throws -> ([Skill], [String])
    /// Starts a coding run: the request goes to the coding engine in a thread of its own under the caller's (a
    /// follow-up to one of the caller's coding threads when `thread` is set), in the project `folder` names (a project's
    /// name or a path; nil: the default project). Returns its task and thread.
    public var startCoding: @Sendable (_ request: String, _ folder: String?, _ mode: CodingMode?, _ thread: ConversationID?) async throws -> (TaskID, ConversationID) = { _, _, _, _ in throw ToolError.failed("Coding is unavailable in this context") }
    /// Posts a file already in the artifact store into the task's conversation as an assistant `.file` message.
    public var shareFile: @Sendable (_ taskID: TaskID, _ ref: FileRef) async throws -> Void
    /// Shows an approval card and waits for the user's decision; returns the decided request.
    public var requestApproval: @Sendable (_ taskID: TaskID, _ request: ApprovalRequest) async throws -> ApprovalRequest = { _, _ in throw ToolError.failed("Approvals are unavailable in this context") }
    /// Looks up an approval by id (for publishing tools).
    public var approval: @Sendable (_ id: String) async throws -> ApprovalRequest? = { _ in nil }
    /// Posts a card that carries its own action and returns at once (the task doesn't wait for the decision).
    public var postApproval: @Sendable (_ taskID: TaskID, _ request: ApprovalRequest) async throws -> Void = { _, _ in throw ToolError.failed("Approvals are unavailable in this context") }
    /// Posts a proposed change to an agent or a skill: a card whose action (an approval-only tool) applies it once
    /// the user approves. Only the proposal tools post these.
    public var postProposal: @Sendable (_ taskID: TaskID, _ request: ApprovalRequest) async throws -> Void = { _, _ in throw ToolError.failed("Proposals are unavailable in this context") }
    /// Posts a card (a report) into the task's conversation as an assistant message.
    public var postPart: @Sendable (_ taskID: TaskID, _ part: ContentPart) async throws -> Void = { _, _ in throw ToolError.failed("Cards are unavailable in this context") }
    /// Records where approved content went live.
    public var markPublished: @Sendable (_ id: String, _ url: String) async throws -> Void = { _, _ in }

    public init(delegate: @escaping @Sendable (TaskID, String, String, String, String, String?, String?) async throws -> TaskID, awaitTask: @escaping @Sendable (TaskID, TimeInterval) async throws -> TaskRecord, askUser: @escaping @Sendable (TaskID, String) async throws -> String, learnSkill: @escaping @Sendable (TaskID, Skill) async throws -> Skill, scheduleJob: @escaping @Sendable (String, String, String, SkillID?) async throws -> ScheduledJob, deleteSchedule: @escaping @Sendable (ScheduleID) async throws -> Void, importSkills: @escaping @Sendable (String) async throws -> ([Skill], [String]), shareFile: @escaping @Sendable (TaskID, FileRef) async throws -> Void = { _, _ in throw ToolError.failed("share_file is unavailable in this context") }) {
        self.delegate = delegate
        self.awaitTask = awaitTask
        self.askUser = askUser
        self.learnSkill = learnSkill
        self.scheduleJob = scheduleJob
        self.deleteSchedule = deleteSchedule
        self.importSkills = importSkills
        self.shareFile = shareFile
    }
}

public enum ToolError: Error, Sendable, CustomStringConvertible {
    case invalidArguments(String)
    case denied(String)
    case desktopRevoked
    case failed(String)
    case unknownTool(String)
    case timeout

    public var description: String {
        switch self {
        case .invalidArguments(let s): return "Invalid arguments: \(s)"
        case .denied(let s): return "Denied: \(s)"
        case .desktopRevoked: return "Desktop control was revoked (human takeover or pause). Re-read the screen before continuing."
        case .failed(let s): return s
        case .unknownTool(let s): return "Unknown tool: \(s)"
        case .timeout: return "Tool timed out"
        }
    }
}

/// A callable capability exposed to the model.
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult
}

// MARK: - Argument helpers

public extension JSONValue {
    func requireString(_ key: String) throws -> String {
        guard let v = self[key]?.stringValue, !v.isEmpty else { throw ToolError.invalidArguments("missing string '\(key)'") }
        return v
    }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func requireDouble(_ key: String) throws -> Double {
        guard let v = self[key]?.doubleValue else { throw ToolError.invalidArguments("missing number '\(key)'") }
        return v
    }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func stringArray(_ key: String) -> [String]? { self[key]?.arrayValue?.compactMap(\.stringValue) }
}

/// Small helper for building JSON Schema objects for tool specs.
public enum JSONSchema {
    public static func object(_ properties: [String: JSONValue], required: [String] = [], description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        if let description { o["description"] = .string(description) }
        o["additionalProperties"] = .bool(false)
        return .object(o)
    }
    public static func string(_ description: String, enumValues: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let enumValues { o["enum"] = .array(enumValues.map { .string($0) }) }
        return .object(o)
    }
    public static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    public static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    public static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
    public static func array(of items: JSONValue, _ description: String) -> JSONValue { ["type": "array", "items": items, "description": .string(description)] }
}

public extension ToolContext {
    /// Desktop tools call this before every synthesized action. The runtime acquires the lease for the task;
    /// a human takeover or pause invalidates it and the tool must stop.
    func requireDesktop() async throws {
        guard let holder = await lease.currentHolder, holder.taskID == taskID, await lease.isValid(holder) else {
            throw ToolError.desktopRevoked
        }
    }
}
