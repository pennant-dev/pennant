import Foundation

/// Something an agent wants to do in public (a LinkedIn post, say) shown to the user as a card with Approve,
/// Request changes and Reject. The agent's task waits until the user decides; publishing tools take the approval's
/// id and use exactly the approved text and images.
public struct ApprovalRequest: Hashable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending, approved, changesRequested, rejected
    }

    public var id: String
    public var taskID: TaskID
    /// "LinkedIn post for Acme".
    public var title: String
    /// Where it goes if approved: "LinkedIn · Acme company page".
    public var destination: String
    /// The exact text to publish.
    public var text: String
    /// Images, in order (a carousel), stored as artifacts.
    public var images: [ImageRef]
    /// A video to publish (a product demo), when there is one.
    public var video: ApprovalVideo?
    /// A short title published with the content, like a video's title. The card title describes the request.
    public var headline: String?
    /// Keywords published with the content (a video's tags), in order.
    public var tags: [String]
    /// Settings published with the content, shown for approval: "Altered or synthetic content: Yes", "Category:
    /// Science & Technology". Publishing scripts read them by label.
    public var details: [ApprovalDetail]
    /// Why this, and the sources behind its claims, for the reviewer.
    public var notes: String
    public var state: State
    /// The text as approved, when the user edited it on the card.
    public var approvedText: String?
    /// The user's reason, or the changes they asked for.
    public var comment: String?
    public var createdAt: Date
    public var decidedAt: Date?
    /// Who approved, sent back or rejected it, on a host several people share.
    public var decidedBy: MessageAuthor?
    /// Set by the publishing tool once the approved content is live.
    public var publishedURL: String?
    /// What Pennant itself does on approval (send this reply…), with the approved text in `action.textField`.
    /// Cards with an action don't hold their task: several can wait for the user at once.
    public var action: ApprovalAction?
    /// The action's outcome once approved: what happened, or why it failed.
    public var actionResult: String?
    public var actionFailed: Bool?
    /// The approve button's words when the default (see `approveButtonLabel`) doesn't fit, such as "Allow" for a command.
    public var approveLabel: String?
    /// A second approve button that also covers what comes next, e.g. "Allow for the rest of this task" on a coding
    /// agent's command. Nil: no such button.
    public var allowRestLabel: String?
    /// The second button was the one pressed.
    public var approvedForRest: Bool?

    public init(id: String = UUID().uuidString, taskID: TaskID, title: String, destination: String, text: String, images: [ImageRef] = [], video: ApprovalVideo? = nil, headline: String? = nil, tags: [String] = [], details: [ApprovalDetail] = [], notes: String = "", state: State = .pending, approvedText: String? = nil, comment: String? = nil, createdAt: Date = Date(), decidedAt: Date? = nil, publishedURL: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.destination = destination
        self.text = text
        self.images = images
        self.video = video
        self.headline = headline
        self.tags = tags
        self.details = details
        self.notes = notes
        self.state = state
        self.approvedText = approvedText
        self.comment = comment
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.publishedURL = publishedURL
    }

    /// What gets published: the edited text when there is one.
    public var finalText: String { approvedText ?? text }

    /// The approve button's words: the action's or the card's own, else what the card does: a post "Approve & post",
    /// a video "Approve & upload", a message "Approve & send", anything else plain "Approve".
    public var approveButtonLabel: String {
        if let l = action?.label, !l.isEmpty { return l }
        if let l = approveLabel, !l.isEmpty { return l }
        let about = " " + (destination + " " + title).lowercased() + " "
        if video != nil { return "Approve & upload" }
        let publishing = ["linkedin", "reddit", "youtube", "instagram", "facebook", "twitter", " x ", "blog", "company page", " post", "carousel"]
        if !images.isEmpty || headline != nil || !tags.isEmpty || publishing.contains(where: about.contains) { return "Approve & post" }
        let sending = ["email", "e-mail", "outlook", " mail", "reply", "message", "teams", "slack", "imessage", "telegram", "whatsapp"]
        if sending.contains(where: about.contains) { return "Approve & send" }
        return "Approve"
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, title, destination, text, images, video, headline, tags, details, notes, state, approvedText, comment, createdAt, decidedAt, decidedBy, publishedURL, action, actionResult, actionFailed, approveLabel, allowRestLabel, approvedForRest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskID = try c.decode(TaskID.self, forKey: .taskID)
        title = try c.decode(String.self, forKey: .title)
        destination = try c.decode(String.self, forKey: .destination)
        text = try c.decode(String.self, forKey: .text)
        images = try c.decodeIfPresent([ImageRef].self, forKey: .images) ?? []
        video = try c.decodeIfPresent(ApprovalVideo.self, forKey: .video)
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        // Cards stored before tags and details existed have neither.
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        details = try c.decodeIfPresent([ApprovalDetail].self, forKey: .details) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        state = try c.decode(State.self, forKey: .state)
        approvedText = try c.decodeIfPresent(String.self, forKey: .approvedText)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        decidedBy = try c.decodeIfPresent(MessageAuthor.self, forKey: .decidedBy)
        publishedURL = try c.decodeIfPresent(String.self, forKey: .publishedURL)
        action = try c.decodeIfPresent(ApprovalAction.self, forKey: .action)
        actionResult = try c.decodeIfPresent(String.self, forKey: .actionResult)
        actionFailed = try c.decodeIfPresent(Bool.self, forKey: .actionFailed)
        approveLabel = try c.decodeIfPresent(String.self, forKey: .approveLabel)
        allowRestLabel = try c.decodeIfPresent(String.self, forKey: .allowRestLabel)
        approvedForRest = try c.decodeIfPresent(Bool.self, forKey: .approvedForRest)
    }
}

/// One setting published with approved content, as the card shows it.
public struct ApprovalDetail: Hashable, Codable, Sendable {
    public var label: String
    public var value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

/// A video on an approval card. The full-quality file stays on the host (`sourcePath`) for publishing; the card
/// plays a smaller preview stored as an artifact.
public struct ApprovalVideo: Hashable, Codable, Sendable {
    /// The file that gets published, on the host.
    public var sourcePath: String
    /// A playable preview (H.264 MP4, small enough to send to the app).
    public var preview: ImageRef
    /// A still frame shown before playing.
    public var poster: ImageRef?
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    /// SHA-256 of the file when it was put up for approval; publishing refuses a file that has changed since.
    public var sha256: String

    public init(sourcePath: String, preview: ImageRef, poster: ImageRef? = nil, durationSeconds: Double, width: Int, height: Int, sha256: String) {
        self.sourcePath = sourcePath
        self.sha256 = sha256
        self.preview = preview
        self.poster = poster
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
    }
}

/// A tool call Pennant makes when the user approves a card: the approved text (their edits included) replaces
/// `arguments[textField]`, so exactly what they approved is what gets sent.
public struct ApprovalAction: Hashable, Codable, Sendable {
    public var tool: String
    public var arguments: JSONValue
    public var textField: String
    /// The approve button's words: "Approve & send".
    public var label: String

    public init(tool: String, arguments: JSONValue, textField: String, label: String = "Approve & send") {
        self.tool = tool
        self.arguments = arguments
        self.textField = textField
        self.label = label
    }
}

/// The user's answer to an approval card.
public struct ApprovalDecision: Hashable, Codable, Sendable {
    /// `approveRest`: approve, and what comes next of the same kind too (the card's `allowRestLabel` button).
    public enum Verdict: String, Codable, Sendable { case approve, approveRest, requestChanges, reject }
    public var approvalID: String
    public var verdict: Verdict
    /// Edited text when approving a changed version.
    public var editedText: String?
    public var comment: String?

    public init(approvalID: String, verdict: Verdict, editedText: String? = nil, comment: String? = nil) {
        self.approvalID = approvalID
        self.verdict = verdict
        self.editedText = editedText
        self.comment = comment
    }
}

extension String {
    /// nil for an empty (or whitespace-only) string.
    public var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

/// An approval card still waiting for the user, with where it lives (for the app's approvals list).
public struct PendingApproval: Hashable, Codable, Sendable, Identifiable {
    public var request: ApprovalRequest
    public var agentID: AgentID
    public var conversationID: ConversationID
    public var messageID: MessageID
    public var id: String { request.id }
    public init(request: ApprovalRequest, agentID: AgentID, conversationID: ConversationID, messageID: MessageID) {
        self.request = request
        self.agentID = agentID
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

/// The message the host writes to hand a decision back to the agent that asked, when the agent isn't waiting on that
/// card any more ("Decision on "…": APPROVED (approval_id …). Publish with …"). It's written for the model; people see
/// it as one short line.
public struct DecisionNote: Hashable, Sendable {
    public var title: String
    public var verdict: ApprovalRequest.State

    public init?(text: String) {
        let prefixes: [(String, ApprovalRequest.State?)] = [("Decision on \"", nil), ("Changes requested on \"", .changesRequested)]
        guard let (prefix, fixed) = prefixes.first(where: { text.hasPrefix($0.0) }) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard let close = rest.range(of: "\"") else { return nil }
        title = String(rest[..<close.lowerBound])
        let after = rest[close.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        if let fixed { verdict = fixed }
        else if after.hasPrefix("APPROVED") { verdict = .approved }
        else if after.hasPrefix("CHANGES REQUESTED") { verdict = .changesRequested }
        else if after.hasPrefix("REJECTED") { verdict = .rejected }
        else { return nil }
    }
}
