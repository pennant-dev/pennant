import PennantCore
import Foundation

extension Message {
    /// The line a conversation list shows for this message: the first line of a user or assistant message.
    /// Nil for tool and system messages, empty bodies, and assistant messages still streaming.
    public var conversationPreview: String? {
        guard role == .user || role == .assistant, !isStreaming else { return nil }
        let line = Conversation.previewLine(text)
        return line.isEmpty ? nil : line
    }
}

extension Conversation {
    /// Applies a message to the list metadata the host maintains: `preview` and `updatedAt`.
    /// Returns false, and changes nothing, when the message does not count (tool, system, empty, streaming).
    @discardableResult
    public mutating func absorb(_ message: Message) -> Bool {
        guard let line = message.conversationPreview else { return false }
        preview = line
        updatedAt = max(message.createdAt, Date())
        return true
    }
}
