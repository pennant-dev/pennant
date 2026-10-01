import PennantCore
import Foundation

/// Links someone's GitHub for reviews: they get GitHub's device code (in their own chat, or here for the owner), and
/// once they enter it, their approvals in chats are posted to GitHub as them.
public struct LinkReviewerTool: Tool {
    let reviews: ReviewService
    let channels: ChannelService
    let owner: @Sendable () async -> Person?
    public init(reviews: ReviewService, channels: ChannelService, owner: @escaping @Sendable () async -> Person?) {
        self.reviews = reviews; self.channels = channels; self.owner = owner
    }
    public var spec: ToolSpec {
        ToolSpec(name: "link_reviewer", description: "Link a person's GitHub account so they can approve pull requests from a chat (\"approve all\" in iMessage or Teams, or the owner's button in Pennant), posted on GitHub as them. They get a one-time GitHub code in their own chat (the owner: in this reply) to enter at github.com/login/device. Do it once per person.", inputSchema: JSONSchema.object([
            "who": JSONSchema.string("The contact's name (their own chat, not a group), or \"me\" for the owner."),
        ], required: ["who"]))   // not acting: it only sends a code, and nothing links unless that person enters it
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let who = try arguments.requireString("who").trimmingCharacters(in: .whitespacesAndNewlines)
        let isOwner = ["me", "myself", "owner", "i"].contains(who.lowercased())
        var keys: Set<String> = []
        let name: String
        var contact: ChannelContact?
        if isOwner {
            guard let me = await owner() else { throw ToolError.failed("There's no owner account yet.") }
            name = me.name
            keys.insert(me.id.rawValue)
        } else {
            guard let found = await channels.resolve(who, channel: nil) else { throw ToolError.failed("No contact matches \"\(who)\". Use list_contacts.") }
            guard found.details?["group"] == nil, !ChannelService.isIMessageGroup(found) else { throw ToolError.failed("\(found.name) is a group chat: link each person in it.") }
            contact = found
            name = found.name
            // The same person on every channel they're a contact on.
            for c in await channels.contacts where c.name.lowercased() == found.name.lowercased() && c.details?["group"] == nil && !ChannelService.isIMessageGroup(c) {
                keys.formUnion(await channels.reviewKeys(of: c))
            }
        }
        let link = try await reviews.startLink(name: name, keys: keys)
        let conversation = context.conversationID, agent = context.agentID
        let reviews = self.reviews
        Task {
            do {
                let r = try await link.finished.value
                await reviews.announce(agent, conversation, "\(name)'s GitHub (\(r.login)) is linked: their approvals in chats are posted on GitHub as them.")
            } catch {
                await reviews.announce(agent, conversation, "Linking \(name)'s GitHub didn't finish: \(error)")
            }
        }
        let instructions = "open \(link.url) and enter \(link.code) (within 15 minutes)"
        if let contact {
            let text = "Pennant here. To approve pull requests from chat (\"approve all\"), link your GitHub once: \(instructions). Approvals are posted on GitHub as you."
            switch try await channels.send(text, to: contact, from: context.agentID, conversationID: context.conversationID) {
            case .sent: return .text(ToolCallID("pending"), name: spec.name, "Sent \(name) the GitHub code. You'll hear here when they've linked.")
            case .needsApproval: return .text(ToolCallID("pending"), name: spec.name, "\(name) isn't cleared for messages: tell them to \(instructions). You'll hear here when they've linked.")
            }
        }
        return .text(ToolCallID("pending"), name: spec.name, "Tell the owner, word for word: to link your GitHub for reviews, \(instructions). You'll hear here when it's done.")
    }
}

/// Opens a batch of pull requests for review: posted to a chat, where linked reviewers approve with "approve all",
/// and to the owner's Pennant app as a card. The asking agent hears as approvals land.
public struct RequestReviewsTool: Tool {
    let reviews: ReviewService
    let channels: ChannelService
    let owner: @Sendable () async -> Person?
    public init(reviews: ReviewService, channels: ChannelService, owner: @escaping @Sendable () async -> Person?) {
        self.reviews = reviews; self.channels = channels; self.owner = owner
    }
    public var spec: ToolSpec {
        ToolSpec(name: "request_reviews", description: "Ask for pull request approvals where the reviewers are: the PRs are listed in a chat (a group chat or a person's) and on a card in the owner's Pennant app; each linked reviewer approves with \"approve all\" or \"approve 1 3\" and Pennant posts the approvals on GitHub as them, on the listed commits. You get a message here as approvals land; with merge on, merge what's ready then. Reviewers link GitHub once with link_reviewer.", inputSchema: JSONSchema.object([
            "title": JSONSchema.string("What the batch is for, e.g. \"Release 0.1.15\"."),
            "prs": JSONSchema.array(of: JSONSchema.string("owner/repo#number"), "The pull requests, in the order they should merge."),
            "place": JSONSchema.string("The chat to post them in (a contact or group chat name). Omit to ask only in the Pennant app."),
            "merge": JSONSchema.boolean("Whether you'll merge them as approvals land (you're told when)."),
        ], required: ["title", "prs"]), isConsequential: true)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let title = try arguments.requireString("title")
        let refs: [(repo: String, number: Int)] = try (arguments["prs"]?.arrayValue ?? []).compactMap(\.stringValue).map { ref in
            let parts = ref.split(separator: "#")
            guard parts.count == 2, parts[0].contains("/"), let n = Int(parts[1]) else { throw ToolError.invalidArguments("\"\(ref)\" isn't owner/repo#number") }
            return (String(parts[0]), n)
        }
        guard !refs.isEmpty else { throw ToolError.invalidArguments("List at least one pull request.") }
        var place: ChannelContact?
        if let name = arguments.string("place"), !name.isEmpty {
            guard let found = await channels.resolve(name, channel: nil) else { throw ToolError.failed("No chat matches \"\(name)\". Use list_contacts.") }
            place = found
        }
        let batch = try await reviews.open(title: title, prs: refs, placeID: place?.id, agentID: context.agentID,
                                           conversationID: context.conversationID, merge: arguments["merge"]?.boolValue ?? false)
        // The owner's button: approving the card approves them all as the owner.
        var onCard = false
        if let me = await owner(), await reviews.reviewer(forKeys: [me.id.rawValue]) != nil, let hooks = context.runtimeHooks {
            var request = ApprovalRequest(taskID: context.taskID, title: "Approve \(batch.prs.count) pull request\(batch.prs.count == 1 ? "" : "s") as you",
                                          destination: "GitHub · \(title)",
                                          text: batch.prs.enumerated().map { "\($0.offset + 1). \($0.element.label) \($0.element.title) (\($0.element.author))" }.joined(separator: "\n"),
                                          notes: "Approving posts a GitHub review as you on each listed commit. Your own PRs and any that changed since are skipped.")
            request.action = ApprovalAction(tool: ApproveReviewBatchTool.name, arguments: .object(["batch": .string(batch.id)]), textField: "summary", label: "Approve on GitHub")
            try await hooks.postApproval(context.taskID, request)
            onCard = true
        }
        return .text(ToolCallID("pending"), name: spec.name,
                     "Batch \(batch.id) open: \(batch.prs.map(\.label).joined(separator: ", "))\(place.map { ". Posted in \($0.name)" } ?? "")\(onCard ? ", and on a card for the owner" : "")." +
                     " You'll get a message here as approvals land.")
    }
}

/// The owner's button: approves a batch on GitHub as the owner. Runs only from the card.
public struct ApproveReviewBatchTool: Tool {
    static let name = "approve_review_batch"
    let reviews: ReviewService
    let owner: @Sendable () async -> Person?
    public init(reviews: ReviewService, owner: @escaping @Sendable () async -> Person?) { self.reviews = reviews; self.owner = owner }
    public var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Internal: approves a review batch as the owner, from their card.", inputSchema: JSONSchema.object([
            "batch": JSONSchema.string("The batch id."),
        ], required: ["batch"]), isConsequential: true, access: .approvalOnly)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let me = await owner(), let reviewer = await reviews.reviewer(forKeys: [me.id.rawValue]) else { throw ToolError.failed("The owner's GitHub isn't linked.") }
        let answer = await reviews.approve(batchID: try arguments.requireString("batch"), reviewer: reviewer, which: nil, via: "the Pennant app")
        return .text(ToolCallID("pending"), name: spec.name, answer)
    }
}

public struct ReviewStatusTool: Tool {
    let reviews: ReviewService
    public init(reviews: ReviewService) { self.reviews = reviews }
    public var spec: ToolSpec {
        ToolSpec(name: "review_status", description: "The open review batches: each PR and who approved it; and who has linked GitHub for reviews.", inputSchema: JSONSchema.object([:], required: []))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let linked = await reviews.reviewers.map { "\($0.name) (\($0.login))" }
        return .text(ToolCallID("pending"), name: spec.name, await reviews.status() + "\n\nLinked for reviews: \(linked.isEmpty ? "nobody yet" : linked.joined(separator: ", ")).")
    }
}
