import Foundation

/// News from one of Pennant's threads, posted in the Pennant chat. People talk only to Pennant; the work happens in
/// threads Pennant starts (and in scheduled runs and goals), and what comes of it lands here: a thread finished or
/// failed, asks something, or put up a card. The update links to the thread, which holds the steps.
public struct WorkUpdate: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case finished, failed, question, approval

        /// A kind from a newer host reads as a plain result rather than failing the message.
        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .finished
        }
    }

    public var id: String
    public var kind: Kind
    public var threadID: ConversationID
    public var taskID: TaskID?
    /// The thread's title when the update was posted.
    public var thread: String
    /// The result, the reason it failed, the question, or the card's title.
    public var text: String
    /// For a card: its id, and once decided, what became of it ("Approved", "Rejected", "Replaced"…).
    public var approvalID: String?
    public var outcome: String?
    public var createdAt: Date
    /// Pennant had nothing to tell the owner about it (they already knew): it stays in the chat's history for Pennant,
    /// and the apps don't show it.
    public var silent: Bool?

    public init(id: String = UUID().uuidString, kind: Kind, threadID: ConversationID, taskID: TaskID? = nil, thread: String, text: String,
                approvalID: String? = nil, outcome: String? = nil, createdAt: Date = Date(), silent: Bool? = nil) {
        self.id = id; self.kind = kind; self.threadID = threadID; self.taskID = taskID; self.thread = thread; self.text = text
        self.approvalID = approvalID; self.outcome = outcome; self.createdAt = createdAt; self.silent = silent
    }

    /// The thread's short id, the one Pennant's thread tools take.
    public var shortThreadID: String { String(threadID.rawValue.prefix(8)) }

    /// What Pennant reads in the chat's history.
    public var modelLine: String {
        let head = "[Update from the thread “\(thread)” (thread \(shortThreadID))"
        switch kind {
        case .finished: return head + ": finished" + (silent == true ? "; you didn't mention it to them" : "") + "]\n" + Self.clipped(text, 1500)
        case .failed: return head + ": failed] " + Self.clipped(text, 600)
        case .question: return head + ": it asks the owner] " + Self.clipped(text, 1200) + "\n(Their answer goes back with message_thread.)"
        case .approval:
            return head + ": a card waits for the owner] “\(text)”" + (approvalID.map { " (approval \($0))" } ?? "") + (outcome.map { " — \($0)" } ?? "")
        }
    }

    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
