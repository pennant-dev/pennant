import Foundation

public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

/// Reference to a stored binary artifact (screenshot, file, generated document).
public struct ImageRef: Hashable, Codable, Sendable {
    public var artifactID: ArtifactID
    public var mimeType: String
    public var width: Int
    public var height: Int
    /// Short description used when the image is dropped from context after compaction.
    public var caption: String

    public init(artifactID: ArtifactID, mimeType: String = "image/jpeg", width: Int = 0, height: Int = 0, caption: String = "") {
        self.artifactID = artifactID
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.caption = caption
    }
}

public struct ToolCall: Hashable, Codable, Sendable, Identifiable {
    public var id: ToolCallID
    public var name: String
    public var arguments: JSONValue

    public init(id: ToolCallID = ToolCallID(), name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Hashable, Codable, Sendable {
    public var callID: ToolCallID
    public var name: String
    public var content: [ContentPart]
    public var isError: Bool

    public init(callID: ToolCallID, name: String, content: [ContentPart], isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.content = content
        self.isError = isError
    }

    public static func text(_ callID: ToolCallID, name: String, _ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(callID: callID, name: name, content: [.text(text)], isError: isError)
    }

    public var textContent: String {
        content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }
}

/// A file the agent handed to the user (or the user attached), stored as an artifact on the host.
public struct FileRef: Hashable, Codable, Sendable {
    public var artifactID: ArtifactID
    public var fileName: String
    public var mimeType: String
    public var byteCount: Int
    /// One line about what the file is, shown under the name.
    public var caption: String

    public init(artifactID: ArtifactID, fileName: String, mimeType: String = "application/octet-stream", byteCount: Int = 0, caption: String = "") {
        self.artifactID = artifactID
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.caption = caption
    }
}

public indirect enum ContentPart: Hashable, Codable, Sendable {
    case text(String)
    case image(ImageRef)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    /// Model reasoning that should be shown collapsed and never re-sent as an instruction.
    case reasoning(String)
    /// A file shared into the conversation; the bytes live in the artifact store.
    case file(FileRef)
    /// Something waiting for the user's approval (a post to publish), shown as a card with Approve / Reject.
    case approval(ApprovalRequest)
    /// A structured report (status, numbers, tables, lists), drawn as a card.
    case report(ReportCard)
    /// Multiple-choice questions waiting for the user (a coding CLI's AskUserQuestion), answered by tapping.
    case choices(ChoiceQuestion)
    /// News from one of Pennant's threads in the Pennant chat: it finished, failed, asks something or put up a card.
    case update(WorkUpdate)

    private enum CodingKeys: String, CodingKey { case type, text, image, toolCall, toolResult, file, approval, report, choices, update }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "reasoning": self = .reasoning(try c.decode(String.self, forKey: .text))
        case "image": self = .image(try c.decode(ImageRef.self, forKey: .image))
        case "toolCall": self = .toolCall(try c.decode(ToolCall.self, forKey: .toolCall))
        case "toolResult": self = .toolResult(try c.decode(ToolResult.self, forKey: .toolResult))
        case "file": self = .file(try c.decode(FileRef.self, forKey: .file))
        case "approval": self = .approval(try c.decode(ApprovalRequest.self, forKey: .approval))
        case "report": self = .report(try c.decode(ReportCard.self, forKey: .report))
        case "choices": self = .choices(try c.decode(ChoiceQuestion.self, forKey: .choices))
        case "update": self = .update(try c.decode(WorkUpdate.self, forKey: .update))
        // A part from a newer host: show a placeholder rather than failing the whole message.
        default: self = .text("[\(type) — update Pennant to see this]")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .reasoning(let t): try c.encode("reasoning", forKey: .type); try c.encode(t, forKey: .text)
        case .image(let i): try c.encode("image", forKey: .type); try c.encode(i, forKey: .image)
        case .toolCall(let tc): try c.encode("toolCall", forKey: .type); try c.encode(tc, forKey: .toolCall)
        case .toolResult(let tr): try c.encode("toolResult", forKey: .type); try c.encode(tr, forKey: .toolResult)
        case .file(let f): try c.encode("file", forKey: .type); try c.encode(f, forKey: .file)
        case .approval(let a): try c.encode("approval", forKey: .type); try c.encode(a, forKey: .approval)
        case .report(let r): try c.encode("report", forKey: .type); try c.encode(r, forKey: .report)
        case .choices(let q): try c.encode("choices", forKey: .type); try c.encode(q, forKey: .choices)
        case .update(let u): try c.encode("update", forKey: .type); try c.encode(u, forKey: .update)
        }
    }

    public var plainText: String? {
        if case .text(let t) = self { return t }
        return nil
    }
}

public struct Conversation: Hashable, Codable, Sendable, Identifiable {
    public var id: ConversationID
    public var agentID: AgentID
    public var title: String
    /// First line of the most recent user or assistant message, for list previews. Maintained by the host.
    public var preview: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Claude Code's session for this conversation, resumed on every message.
    public var engineSessionID: String?
    /// The project folder this coding run works in.
    public var workingDirectory: String?
    /// The last user message already handed to the coding CLI.
    public var engineCursor: MessageID?
    /// How the coding run asks before acting in this conversation (nil: only the owner's sign-offs ask).
    public var engineMode: CodingMode?
    /// The coding run's model for this conversation: Claude Code's name for it ("claude-opus-5-5"), or for the
    /// Pennant engine a Settings › Models profile id; nil: the engine's default.
    public var engineModel: String?
    /// Claude Code runs here with Claude in Chrome (`--chrome`): a skill that browses with it asked for it.
    public var engineChrome: Bool?
    /// When the conversation was closed as done. Closed conversations leave the lists; writing in one reopens it.
    public var closedAt: Date?
    public var isClosed: Bool { closedAt != nil }
    /// The thread that started this one: another agent's request (a question, a handed-off change). Lists show the
    /// parent only; this one opens from the step in the parent's thread.
    public var parentID: ConversationID?
    /// A coding run: the agent handed this thread to a coding engine (Claude Code, or Pennant's own runtime with only
    /// coding tools), which works in a project folder and streams its steps here. Nil: an ordinary thread.
    public var engine: CodingEngine?
    public var isCodingRun: Bool { engine != nil }
    /// The Pennant chat: the one conversation people have with Pennant. Pennant starts threads from it for the work,
    /// and their results, questions and cards come back to it.
    public var isMain: Bool = false

    public init(id: ConversationID = ConversationID(), agentID: AgentID, title: String = "", preview: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, agentID, title, preview, createdAt, updatedAt, engineSessionID, workingDirectory, engineCursor, engineMode, engineModel, engineChrome, closedAt, parentID, engine, isMain }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ConversationID.self, forKey: .id)
        agentID = try c.decode(AgentID.self, forKey: .agentID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        engineSessionID = try c.decodeIfPresent(String.self, forKey: .engineSessionID)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        engineCursor = try c.decodeIfPresent(MessageID.self, forKey: .engineCursor)
        // A mode from a newer host reads as the default rather than failing the conversation.
        engineMode = (try? c.decodeIfPresent(CodingMode.self, forKey: .engineMode)) ?? nil
        engineModel = try c.decodeIfPresent(String.self, forKey: .engineModel)
        engineChrome = try c.decodeIfPresent(Bool.self, forKey: .engineChrome)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        parentID = try c.decodeIfPresent(ConversationID.self, forKey: .parentID)
        engine = (try? c.decodeIfPresent(CodingEngine.self, forKey: .engine)) ?? nil
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
    }

    /// Trims a message body to one preview line.
    public static func previewLine(_ text: String, limit: Int = 140) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let stripped = line.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        return stripped.count > limit ? String(stripped.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : stripped
    }
}

/// One turn in a conversation. Messages are the searchable original history.
public struct Message: Hashable, Codable, Sendable, Identifiable {
    public var id: MessageID
    public var conversationID: ConversationID
    public var agentID: AgentID
    public var taskID: TaskID?
    public var role: MessageRole
    public var parts: [ContentPart]
    /// True while the assistant is still streaming this message.
    public var isStreaming: Bool
    public var createdAt: Date
    /// How fast the model produced this assistant message; nil for other roles and older messages.
    public var stats: GenerationStats?
    /// Who wrote a user message, on a host several people share. Nil for older messages and non-user roles.
    public var author: MessageAuthor?

    public init(
        id: MessageID = MessageID(),
        conversationID: ConversationID,
        agentID: AgentID,
        taskID: TaskID? = nil,
        role: MessageRole,
        parts: [ContentPart],
        isStreaming: Bool = false,
        createdAt: Date = Date(),
        author: MessageAuthor? = nil
    ) {
        self.author = author
        self.id = id
        self.conversationID = conversationID
        self.agentID = agentID
        self.taskID = taskID
        self.role = role
        self.parts = parts
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }

    public var text: String {
        parts.compactMap { $0.plainText }.joined(separator: "\n")
    }

    public var toolCalls: [ToolCall] {
        parts.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
    }
}

/// The person behind a user message or a decision.
public struct MessageAuthor: Hashable, Codable, Sendable {
    public var id: PersonID
    public var name: String
    public init(id: PersonID, name: String) { self.id = id; self.name = name }
}

/// A file attached by the user to a message.
public struct Attachment: Hashable, Codable, Sendable {
    public var artifactID: ArtifactID
    public var fileName: String
    public var mimeType: String
    public var byteCount: Int
    /// Where the host saved a non-image file so the agent can open it with its file tools.
    public var path: String?

    public init(artifactID: ArtifactID, fileName: String, mimeType: String, byteCount: Int, path: String? = nil) {
        self.path = path
        self.artifactID = artifactID
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

/// Metadata for a stored artifact. Bytes live in the artifact directory next to the database.
public struct ArtifactRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: ArtifactID
    public var kind: String
    public var mimeType: String
    public var byteCount: Int
    public var fileName: String
    public var taskID: TaskID?
    public var agentID: AgentID?
    public var caption: String
    public var createdAt: Date

    public init(id: ArtifactID = ArtifactID(), kind: String, mimeType: String, byteCount: Int, fileName: String, taskID: TaskID? = nil, agentID: AgentID? = nil, caption: String = "", createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.fileName = fileName
        self.taskID = taskID
        self.agentID = agentID
        self.caption = caption
        self.createdAt = createdAt
    }
}

/// Speed of one model reply: tokens out, time from the first token to the last, and the wait before the first.
public struct GenerationStats: Hashable, Codable, Sendable {
    public var outputTokens: Int
    /// Seconds spent generating (first token to last).
    public var seconds: Double
    /// Seconds from sending the request to the first token (prompt processing and queueing).
    public var firstTokenSeconds: Double?
    /// The model or profile that answered.
    public var model: String?
    /// True when the provider reported no usage and the token count was estimated from the text.
    public var estimated: Bool

    public init(outputTokens: Int, seconds: Double, firstTokenSeconds: Double? = nil, model: String? = nil, estimated: Bool = false) {
        self.outputTokens = outputTokens
        self.seconds = seconds
        self.firstTokenSeconds = firstTokenSeconds
        self.model = model
        self.estimated = estimated
    }

    /// Output tokens per second of generation; nil when the reply was too short to time.
    public var tokensPerSecond: Double? {
        guard outputTokens > 0, seconds >= 0.05 else { return nil }
        return Double(outputTokens) / seconds
    }
}
