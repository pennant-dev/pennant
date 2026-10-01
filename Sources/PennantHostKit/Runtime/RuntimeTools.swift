import PennantCore
import Foundation

public struct DelegateTaskTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "delegate_task", description: "Hand an independent piece of work to a worker agent that runs on its own and reports back. Give a specific objective and completion criteria. You remain responsible for verifying the result. Workers run on the worker model (usually a cheaper or local one), which suits mechanical, well-specified work: reading and summarizing pages, finding selectors, drafting files from a clear spec, checking outputs against criteria. Pass model to use another model for a harder piece. Returns the task id; use await_task to collect the result.", inputSchema: JSONSchema.object([
            "title": JSONSchema.string("Short title."),
            "objective": JSONSchema.string("Exactly what the worker must accomplish."),
            "completion_criteria": JSONSchema.string("How to know it is done."),
            "context": JSONSchema.string("Facts, paths, and constraints the worker needs."),
            "worker_name": JSONSchema.string("Optional name for the worker persona."),
            "worker_role": JSONSchema.string("Optional role, e.g. 'research assistant'."),
            "model": JSONSchema.string("Optional: the name of a model from Settings › Models for this worker (default: the worker model)."),
        ], required: ["title", "objective"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Delegation unavailable") }
        let title = try arguments.requireString("title"), objective = try arguments.requireString("objective")
        let id: TaskID
        if let onModel = hooks.delegateOnModel {
            id = try await onModel(context.taskID, title, objective, arguments.string("completion_criteria") ?? "", arguments.string("context") ?? "", arguments.string("worker_name"), arguments.string("worker_role"), arguments.string("model"))
        } else {
            id = try await hooks.delegate(context.taskID, title, objective, arguments.string("completion_criteria") ?? "", arguments.string("context") ?? "", arguments.string("worker_name"), arguments.string("worker_role"))
        }
        return .text(ToolCallID("pending"), name: spec.name, "Delegated as task \(id.rawValue). Call await_task with this id when you need the result.")
    }
}

public struct AwaitTaskTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "await_task", description: "Wait for a delegated task to finish and return its result summary and state.", inputSchema: JSONSchema.object([
            "task_id": JSONSchema.string("The delegated task id."),
            "timeout_seconds": JSONSchema.integer("Maximum seconds to wait (default 900, at least 60)."),
        ], required: ["task_id"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Delegation unavailable") }
        let id = TaskID(try arguments.requireString("task_id"))
        // Agents take tens of seconds to answer; a wait of a second or two only looks like a failure and gets the
        // request sent again.
        let timeout = Double(max(arguments.int("timeout_seconds") ?? 900, 60))
        let task: TaskRecord
        do { task = try await hooks.awaitTask(id, timeout) } catch ToolError.timeout {
            return .text(ToolCallID("pending"), name: spec.name, "Task \(id.rawValue) is still running after \(Int(timeout)) seconds; nothing is wrong. Call await_task with the same id to keep waiting. Don't send the request again.")
        }
        var text = "Task '\(task.title)' is \(task.state.rawValue)."
        if !task.stateReason.isEmpty { text += " Reason: \(task.stateReason)" }
        if let r = task.resultSummary { text += "\nResult:\n\(r)" }
        return ToolResult(callID: ToolCallID("pending"), name: spec.name, content: [.text(text)], isError: task.state == .failed)
    }
}

public struct AskUserTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "ask_user", description: "Ask the user a question and wait for the answer. The task pauses until they reply. Use it for decisions that are theirs or when you are blocked.", inputSchema: JSONSchema.object([
            "question": JSONSchema.string("The question, with the options if there are any."),
        ], required: ["question"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Cannot ask the user in this context") }
        let answer = try await hooks.askUser(context.taskID, try arguments.requireString("question"))
        return .text(ToolCallID("pending"), name: spec.name, "User answered: \(answer)")
    }
}
