import Foundation

/// A phantom-typed string identifier. The tag prevents mixing IDs of different kinds.
public struct ID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func < (lhs: ID<Tag>, rhs: ID<Tag>) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum AgentTag {}
public enum TaskTag {}
public enum ConversationTag {}
public enum MessageTag {}
public enum ToolCallTag {}
public enum ToolRecordTag {}
public enum SkillTag {}
public enum MemoryEntityTag {}
public enum MemoryRelationTag {}
public enum PreferenceTag {}
public enum CheckpointTag {}
public enum ArtifactTag {}
public enum ClientTag {}
public enum CommandTag {}
public enum MCPServerTag {}
public enum LeaseTag {}

public typealias AgentID = ID<AgentTag>
public typealias TaskID = ID<TaskTag>
public typealias ConversationID = ID<ConversationTag>
public typealias MessageID = ID<MessageTag>
public typealias ToolCallID = ID<ToolCallTag>
public typealias ToolRecordID = ID<ToolRecordTag>
public typealias SkillID = ID<SkillTag>
public typealias MemoryEntityID = ID<MemoryEntityTag>
public typealias MemoryRelationID = ID<MemoryRelationTag>
public typealias PreferenceID = ID<PreferenceTag>
public typealias CheckpointID = ID<CheckpointTag>
public typealias ArtifactID = ID<ArtifactTag>
public typealias ClientID = ID<ClientTag>
public typealias CommandID = ID<CommandTag>
public typealias MCPServerID = ID<MCPServerTag>
public typealias LeaseID = ID<LeaseTag>

/// Monotonic sequence number of an event in the host log. Clients replay from the last one they saw.
public typealias EventSeq = Int64
