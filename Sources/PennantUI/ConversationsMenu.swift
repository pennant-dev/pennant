import PennantClientKit
import PennantCore
import SwiftUI

// Shared pieces for switching between an agent's conversations: the label rules the roster, the
// Mac header and the iPhone screens all use, and the menu that lists them.

/// What a list calls a conversation: its title, else the first line of its latest message, else a placeholder.
/// The ⏰/🎯 the host puts at the start of scheduled runs' and goals' titles are left off: lists draw an icon instead
/// (`threadSymbol`).
public func conversationLabel(_ conversation: Conversation) -> String {
    if !conversation.title.isEmpty { return ThreadMark.strip(conversation.title).text }
    if !conversation.preview.isEmpty { return conversation.preview }
    return "New conversation"
}

/// The icon for a thread's kind: a clock for a scheduled run, a target for a goal, nil for a conversation.
public func threadSymbol(_ conversation: Conversation) -> String? { ThreadMark.strip(conversation.title).symbol }

/// A schedule's name without the goal mark (its icon is drawn separately).
public func scheduleLabel(_ name: String) -> String { ThreadMark.strip(name).text }

/// The emoji marks at the start of generated names, and the SF Symbols the apps show in their place.
public enum ThreadMark {
    static let marks: [(prefix: String, symbol: String)] = [("⏰", "clock"), ("🎯", "target")]

    public static func strip(_ s: String) -> (symbol: String?, text: String) {
        for m in marks where s.hasPrefix(m.prefix) {
            return (m.symbol, String(s.dropFirst(m.prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        return (nil, s)
    }
}

/// Menu items listing an agent's conversations newest first, the open one checked, then "New conversation".
/// Drop it into any `Menu` (the Mac header title, the iPhone navigation title).
public struct ConversationMenuItems: View {
    @Environment(\.hostSession) private var session
    @Environment(\.openInNewWindow) private var openInNewWindow
    var agentID: AgentID
    @Binding var conversationID: ConversationID?

    public init(agentID: AgentID, conversationID: Binding<ConversationID?>) {
        self.agentID = agentID
        _conversationID = conversationID
    }

    public var body: some View {
        let conversations = session.state.conversations(for: agentID)
        ForEach(conversations) { c in
            Toggle(isOn: Binding(get: { conversationID == c.id }, set: { _ in conversationID = c.id })) {
                #if os(macOS)
                // AppKit menu items are one line: label, then the time.
                Text("\(Self.menuLabel(c))  ·  \(conversationTimestamp(c.updatedAt))")
                #else
                Text(Self.menuLabel(c))
                Text(conversationTimestamp(c.updatedAt))
                #endif
            }
        }
        if !conversations.isEmpty { Divider() }
        Button { conversationID = nil } label: { Label("New conversation", systemImage: "square.and.pencil") }
            .disabled(conversationID == nil)
        if let id = conversationID, let openInNewWindow {
            Button { openInNewWindow(agentID, id) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
        }
        if let id = conversationID, let current = session.state.conversation(id) {
            if current.isClosed {
                Button { Task { try? await session.closeConversation(id, closed: false) } } label: {
                    Label("Reopen conversation", systemImage: "arrow.uturn.backward.circle")
                }
            } else {
                CloseConversationButton(conversationID: $conversationID)
            }
        }
        let closed = session.state.closedConversations(for: agentID)
        if !closed.isEmpty {
            Menu {
                ForEach(closed.prefix(30)) { c in
                    Button(Self.menuLabel(c)) { conversationID = c.id }
                }
            } label: {
                Label("Closed (\(closed.count))", systemImage: "archivebox")
            }
        }
    }

    /// Menu rows stay short; the full preview lives in the roster and the header.
    static func menuLabel(_ c: Conversation, limit: Int = 64) -> String {
        let label = conversationLabel(c)
        return label.count > limit ? String(label.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : label
    }
}

/// Closes the open conversation as done and moves to a new one. Its running task, if any, stops.
public struct CloseConversationButton: View {
    @Environment(\.hostSession) private var session
    @Binding var conversationID: ConversationID?
    var iconOnly = false

    public init(conversationID: Binding<ConversationID?>, iconOnly: Bool = false) {
        _conversationID = conversationID
        self.iconOnly = iconOnly
    }

    public var body: some View {
        Button {
            guard let id = conversationID else { return }
            conversationID = nil
            Task { try? await session.closeConversation(id) }
        } label: {
            if iconOnly { Image(systemName: "checkmark.circle") } else { Label("Close conversation", systemImage: "checkmark.circle") }
        }
        .disabled(conversationID.flatMap { session.state.conversation($0) }.map { $0.isClosed } ?? true)
        .help("Done with this conversation: close it (stops any running work). Writing in it later reopens it.")
        .accessibilityLabel("Close conversation")
    }
}

/// The conversation's name as a small clickable title (with a tiny chevron) that opens the conversations
/// menu. Sits under the agent's name in the Mac header so switching does not need the far-right icons.
public struct ConversationTitleMenu: View {
    @Environment(\.hostSession) private var session
    var agentID: AgentID
    @Binding var conversationID: ConversationID?

    public init(agentID: AgentID, conversationID: Binding<ConversationID?>) {
        self.agentID = agentID
        _conversationID = conversationID
    }

    private var title: String {
        guard let id = conversationID, let c = session.state.conversation(id) else { return "New conversation" }
        return conversationLabel(c)
    }

    public var body: some View {
        Menu {
            ConversationMenuItems(agentID: agentID, conversationID: $conversationID)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.zoomed(size: 8, weight: .semibold))
                    .foregroundStyle(PennantTheme.inkTertiary)
            }
            .frame(maxWidth: 360, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: true)
        .help("Switch conversation")
        .accessibilityLabel("Conversations")
    }
}
