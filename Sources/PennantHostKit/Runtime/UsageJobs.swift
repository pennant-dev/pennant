import PennantCore
import Foundation

/// Which job a run's spend belongs to, for the usage view. With one agent, "by agent" says nothing; the jobs it runs
/// do: a scheduled job's name, "Coding runs" for coding threads, a helper's spend under the run that started it,
/// else the thread's title.
enum UsageJobs {
    static let codingRuns = "Coding runs"

    /// The job a scheduled run's objective names (`Scheduled job "Inbox drafts":…`).
    static func scheduledName(_ objective: String) -> String? {
        let lead = Scheduler.jobLead + "\""
        guard objective.hasPrefix(lead) else { return nil }
        let rest = objective.dropFirst(lead.count)
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let name = rest[..<end].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A thread's title without the ⏰/🎯 mark and the run's date the scheduler adds ("⏰ Inbox drafts · Sep 30, 8:00 AM").
    static func threadName(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        for mark in ["⏰", "🎯"] where t.hasPrefix(mark) {
            t = t.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: " · ", options: .backwards) { t = String(t[..<r.lowerBound]) }
        }
        return t.isEmpty ? "Untitled thread" : t
    }

    /// The job for each task.
    static func resolve(_ taskIDs: Set<TaskID>, store: any StoreProtocol) async -> [TaskID: String] {
        var tasks: [TaskID: TaskRecord] = [:]
        var conversations: [ConversationID: Conversation?] = [:]
        func task(_ id: TaskID) async -> TaskRecord? {
            if let t = tasks[id] { return t }
            let t = try? await store.task(id)
            tasks[id] = t
            return t
        }
        var out: [TaskID: String] = [:]
        for id in taskIDs {
            guard var run = await task(id) else { continue }
            // A helper's spend is part of the run that started it.
            var depth = 0
            while let parent = run.parentTaskID, depth < 6, let p = await task(parent) { run = p; depth += 1 }
            if conversations[run.conversationID] == nil { conversations[run.conversationID] = .some(try? await store.conversation(run.conversationID)) }
            let conversation = conversations[run.conversationID] ?? nil
            if conversation?.isCodingRun == true {
                out[id] = codingRuns
            } else if let name = scheduledName(run.objective) {
                out[id] = name
            } else if let conversation {
                out[id] = threadName(conversation.title)
            } else {
                out[id] = run.title
            }
        }
        return out
    }
}
