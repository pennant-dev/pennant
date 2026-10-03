import PennantCore
import Foundation

/// What the Pennant chat does with threads: start one for a piece of work, pass the owner's word on to one, see
/// where one stands, stop one. Offered only in the chat.
public struct ThreadHooks: Sendable {
    public var start: @Sendable (_ taskID: TaskID, _ title: String, _ instructions: String) async throws -> (TaskID, ConversationID)
    public var message: @Sendable (_ taskID: TaskID, _ thread: String, _ text: String) async throws -> String
    public var read: @Sendable (_ thread: String, _ limit: Int) async throws -> String
    public var stop: @Sendable (_ thread: String) async throws -> String

    public init(start: @escaping @Sendable (TaskID, String, String) async throws -> (TaskID, ConversationID),
                message: @escaping @Sendable (TaskID, String, String) async throws -> String,
                read: @escaping @Sendable (String, Int) async throws -> String,
                stop: @escaping @Sendable (String) async throws -> String) {
        self.start = start; self.message = message; self.read = read; self.stop = stop
    }
}

public enum ThreadTools {
    public static let names: Set<String> = [StartThreadTool.name, MessageThreadTool.name, ReadThreadTool.name, StopThreadTool.name]

    static func hooks(_ context: ToolContext) throws -> ThreadHooks {
        guard let hooks = context.runtimeHooks?.threads else { throw ToolError.failed("Threads are started from the Pennant chat.") }
        return hooks
    }
}

public struct StartThreadTool: Tool {
    public static let name = "start_thread"
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Start a thread for a piece of work: you, working on it in a conversation of its own with all your tools, while this chat stays free. Its result, questions and cards come back to this chat as updates by themselves; don't wait for it. The thread doesn't see this chat, so the instructions must say everything it needs: the goal, the facts and links, what done looks like, and what to check with the owner first.", inputSchema: JSONSchema.object([
            "title": JSONSchema.string("A short title the owner will recognise, e.g. \"LinkedIn post on the October release\"."),
            "instructions": JSONSchema.string("Complete, self-contained instructions for the thread."),
        ], required: ["title", "instructions"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let title = try arguments.requireString("title"), instructions = try arguments.requireString("instructions")
        let (task, thread) = try await ThreadTools.hooks(context).start(context.taskID, title, instructions)
        return .text(ToolCallID("pending"), name: spec.name, "Started the thread “\(title)” (thread \(thread.rawValue.prefix(8)), task \(task.rawValue)). Its result comes back to this chat on its own. Tell the owner in a line and end your turn.")
    }
}

public struct MessageThreadTool: Tool {
    public static let name = "message_thread"
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Send a message into one of your threads: the owner's answer to its question, a change of plan, or more work for one that finished (it picks back up, and its result comes back here). Write it as you'd brief yourself, with everything the owner said that matters.", inputSchema: JSONSchema.object([
            "thread": JSONSchema.string("The thread's id from the work board (the first 8 characters do), or its title."),
            "text": JSONSchema.string("The message."),
        ], required: ["thread", "text"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let reply = try await ThreadTools.hooks(context).message(context.taskID, try arguments.requireString("thread"), try arguments.requireString("text"))
        return .text(ToolCallID("pending"), name: spec.name, reply)
    }
}

public struct ReadThreadTool: Tool {
    public static let name = "read_thread"
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "See where one of your threads stands: its state and its latest messages and steps. For answering \"how's it going?\" or catching up before you steer it.", inputSchema: JSONSchema.object([
            "thread": JSONSchema.string("The thread's id from the work board (the first 8 characters do), or its title."),
            "limit": JSONSchema.integer("How many of its latest messages to read (default 20, at most 60)."),
        ], required: ["thread"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let text = try await ThreadTools.hooks(context).read(try arguments.requireString("thread"), arguments.int("limit") ?? 20)
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}

public struct StopThreadTool: Tool {
    public static let name = "stop_thread"
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Stop the work going on in one of your threads, when the owner calls it off or it's going the wrong way. What it already did stays done.", inputSchema: JSONSchema.object([
            "thread": JSONSchema.string("The thread's id from the work board (the first 8 characters do), or its title."),
        ], required: ["thread"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let text = try await ThreadTools.hooks(context).stop(try arguments.requireString("thread"))
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}
