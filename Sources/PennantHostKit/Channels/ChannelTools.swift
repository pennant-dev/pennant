import PennantCore
import Foundation

/// Lets an agent reach a person on Telegram, iMessage or Teams. Allowed contacts get the message at once; anyone
/// else gets an approval card that sends exactly the approved text. Their reply comes back to this conversation.
public struct SendMessageTool: Tool {
    let channels: ChannelService
    public init(channels: ChannelService) { self.channels = channels }
    public var spec: ToolSpec {
        ToolSpec(name: "send_message", description: "Message a person outside Pennant (Telegram, iMessage, Teams) when you need something from them or they need to know. Their reply arrives in this conversation as a message from them. Use list_contacts to see who can be reached.", inputSchema: JSONSchema.object([
            "to": JSONSchema.string("The contact's name (or phone number, email, chat id)."),
            "text": JSONSchema.string("The message: plain text, short, and self-contained (they don't see this conversation)."),
            "channel": JSONSchema.string("Only this channel; otherwise the one they last used.", enumValues: ChannelKind.allCases.map(\.rawValue)),
            "card": JSONSchema.object([
                "title": JSONSchema.string("A short heading."),
                "facts": JSONSchema.array(of: JSONSchema.object(["title": JSONSchema.string("Label"), "value": JSONSchema.string("Value")], required: ["title", "value"]), "Label/value pairs."),
                "buttons": JSONSchema.array(of: JSONSchema.string("A button's words."), "Up to 6 quick replies; the one they tap comes back as their reply."),
            ], required: [], description: "Optional: show the message as a card (an Adaptive Card in Teams; text with the options elsewhere). `text` is its body."),
        ], required: ["to", "text"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let who = try arguments.requireString("to")
        let text = try arguments.requireString("text")
        let channel = arguments.string("channel").flatMap(ChannelKind.init(rawValue:))
        guard let contact = await channels.resolve(who, channel: channel) else {
            let known = await channels.contacts.map { "\($0.name) (\($0.kind.title))" }.joined(separator: ", ")
            throw ToolError.failed("No contact matches \"\(who)\"\(channel.map { " on \($0.title)" } ?? ""). Contacts: \(known.isEmpty ? "none yet — the owner adds them in Settings › Channels" : known)")
        }
        var outgoing = Outgoing.text(text)
        if let card = arguments["card"]?.objectValue {
            let facts = (card["facts"]?.arrayValue ?? []).compactMap { f -> (String, String)? in
                guard let t = f.string("title"), let v = f.string("value") else { return nil }
                return (t, v)
            }
            let buttons = (card["buttons"]?.arrayValue ?? []).compactMap(\.stringValue)
            outgoing = ChannelCards.simple(title: card["title"]?.stringValue, text: text, facts: facts, buttons: buttons)
        }
        switch try await channels.send(outgoing, to: contact, from: context.agentID, conversationID: context.conversationID) {
        case .sent(let c):
            return .text(ToolCallID("pending"), name: spec.name, "Sent to \(c.name) on \(c.kind.title). Their reply will arrive here.")
        case .needsApproval(let c, let token):
            guard let hooks = context.runtimeHooks else { throw ToolError.failed("Messages to \(c.name) need approval, which isn't available here.") }
            var request = ApprovalRequest(taskID: context.taskID, title: "Message \(c.name) on \(c.kind.title)", destination: "\(c.kind.title) · \(c.name)", text: text,
                                          notes: "\(c.name) isn't on the list of people agents may message freely, so this waits for you.")
            request.action = ApprovalAction(tool: ChannelSendTool.name, arguments: .object(["token": .string(token)]), textField: "text", label: "Approve & send")
            try await hooks.postApproval(context.taskID, request)
            return .text(ToolCallID("pending"), name: spec.name, "\(c.name) needs your owner's approval first: the message is on an approval card and goes out once approved. Their reply will arrive here.")
        }
    }
}

/// Sends a message the user approved on a card. It only works with the card's one-time token.
public struct ChannelSendTool: Tool {
    static let name = "channel_send"
    let channels: ChannelService
    public init(channels: ChannelService) { self.channels = channels }
    public var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Internal: sends a message approved on a card. Agents use send_message instead.", inputSchema: JSONSchema.object([
            "token": JSONSchema.string("The approval card's token."),
            "text": JSONSchema.string("The approved text."),
        ], required: ["token", "text"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let contact = try await channels.sendApproved(token: try arguments.requireString("token"), text: try arguments.requireString("text"))
        return .text(ToolCallID("pending"), name: spec.name, "Sent to \(contact.name) on \(contact.kind.title).")
    }
}

public struct ListContactsTool: Tool {
    let channels: ChannelService
    public init(channels: ChannelService) { self.channels = channels }
    public var spec: ToolSpec {
        ToolSpec(name: "list_contacts", description: "People agents can message outside Pennant, by channel, and whether each message to them needs approval.", inputSchema: JSONSchema.object([:], required: []))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let contacts = await channels.contacts
        let text = contacts.isEmpty ? "No contacts yet: the owner links people in Settings › Channels."
            : contacts.map { "- \($0.name) — \($0.kind.title)\($0.allowed ? "" : " (each message needs approval)")" }.joined(separator: "\n")
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}
