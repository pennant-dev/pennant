import PennantCore
import Foundation

/// Shows the user an approval card (text, carousel images, notes) and waits for Approve, Request changes or Reject.
/// Publishing tools take the returned approval id and use exactly what was approved.
public struct RequestApprovalTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "request_approval",
            description: "Show the user something you want to publish (a post with its images, or a video with its title and description) as an approval card in the app, and wait for their decision: approve (possibly with their edits), request changes (with a comment), or reject. Call it with the FINAL text and images. On approval, publish with the returned approval_id; publishing tools use exactly the approved text and images.",
            inputSchema: JSONSchema.object([
                "title": JSONSchema.string("What this is, e.g. \"LinkedIn post: why AI agents need approval gates\"."),
                "destination": JSONSchema.string("Where it goes if approved, e.g. \"LinkedIn · Acme company page\"."),
                "text": JSONSchema.string("The exact text to publish."),
                "images": .object(["type": "array", "items": .object(["type": "string"]), "description": "Absolute paths of the images, in carousel order (PNG or JPG)."]),
                "video": JSONSchema.string("Absolute path of a finished video (MP4/MOV) to publish. The card plays a preview; publishing uses this file."),
                "headline": JSONSchema.string("A title published with the content, such as the video's title (the text is then its description)."),
                "tags": .object(["type": "array", "items": .object(["type": "string"]), "description": "Keywords published with the content, such as a video's tags."]),
                "details": .object(["type": "array", "description": "Settings published with the content, for the user to approve, e.g. [{\"label\": \"Altered or synthetic content\", \"value\": \"Yes: the narration is a cloned voice\"}]. The publishing script reads them by label.", "items": .object(["type": "object", "properties": .object(["label": JSONSchema.string("The setting."), "value": JSONSchema.string("Its value.")])])]),
                "on_approve": .object(["type": "object", "description": "Optional. What Pennant does itself when the user approves, e.g. send an email reply: {\"tool\": \"<tool name>\", \"arguments\": {…}, \"text_field\": \"body\", \"label\": \"Approve & send\"}. The approved text (with the user's edits) goes into arguments[text_field]. With on_approve the card doesn't wait: this returns at once, so you can put up several cards; Pennant runs the action on approval, and a change request comes back to you as a new message.", "properties": .object([
                    "tool": JSONSchema.string("The tool to call on approval, e.g. mcp:<server>:mail_reply."),
                    "arguments": .object(["type": "object", "description": "Its arguments, without the text (Pennant fills text_field)."]),
                    "text_field": JSONSchema.string("Which argument receives the approved text (e.g. body)."),
                    "label": JSONSchema.string("The approve button's words (default \"Approve & send\")."),
                ])]),
                "notes": JSONSchema.string("For the reviewer: why this topic now, the sources behind each claim, and what checks the text passed."),
                "approve_label": JSONSchema.string("Optional. The approve button's words when the default doesn't fit what approving does, e.g. \"Approve & deploy\" or \"Approve & pay\". Default: \"Approve & post\" for posts, \"Approve & send\" for messages, otherwise \"Approve\"."),
            ], required: ["title", "destination", "text"]),
            isConsequential: false,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Approvals are unavailable in this context") }
        let text = try arguments.requireString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.invalidArguments("text is empty") }
        var images: [ImageRef] = []
        for path in arguments.stringArray("images") ?? [] {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw ToolError.invalidArguments("Cannot read image \(path)") }
            let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            let record = ArtifactRecord(kind: "approval-image", mimeType: mime, byteCount: data.count, fileName: url.lastPathComponent, taskID: context.taskID, agentID: context.agentID, caption: url.lastPathComponent)
            try await context.store.putArtifact(record, data: data)
            images.append(ImageRef(artifactID: record.id, mimeType: mime, caption: url.path))
        }
        var video: ApprovalVideo?
        if let path = arguments.string("video") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.invalidArguments("Cannot find the video \(path)") }
            let made = try await VideoPreview.make(from: url)
            let previewRecord = ArtifactRecord(kind: "approval-video", mimeType: "video/mp4", byteCount: made.preview.count, fileName: "preview-" + url.deletingPathExtension().lastPathComponent + ".mp4", taskID: context.taskID, agentID: context.agentID, caption: url.lastPathComponent)
            try await context.store.putArtifact(previewRecord, data: made.preview)
            var poster: ImageRef?
            if let still = made.poster {
                let posterRecord = ArtifactRecord(kind: "approval-image", mimeType: "image/jpeg", byteCount: still.count, fileName: "poster.jpg", taskID: context.taskID, agentID: context.agentID, caption: "Poster of \(url.lastPathComponent)")
                try await context.store.putArtifact(posterRecord, data: still)
                poster = ImageRef(artifactID: posterRecord.id, mimeType: "image/jpeg", caption: "Poster of \(url.lastPathComponent)")
            }
            video = ApprovalVideo(sourcePath: url.path, preview: ImageRef(artifactID: previewRecord.id, mimeType: "video/mp4", width: made.width, height: made.height, caption: url.path),
                                  poster: poster, durationSeconds: made.duration, width: made.width, height: made.height, sha256: try VideoPreview.sha256(of: url))
        }
        let request = ApprovalRequest(
            taskID: context.taskID,
            title: try arguments.requireString("title"),
            destination: arguments.string("destination") ?? "",
            text: text,
            images: images,
            video: video,
            headline: arguments.string("headline")?.nilIfEmpty,
            tags: (arguments.stringArray("tags") ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            details: (arguments["details"]?.arrayValue ?? []).compactMap { item in
                guard let label = item["label"]?.stringValue?.nilIfEmpty, let value = item["value"]?.stringValue else { return nil }
                return ApprovalDetail(label: label, value: value)
            },
            notes: arguments.string("notes") ?? ""
        )
        var labelled = request
        labelled.approveLabel = arguments.string("approve_label")?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if case .object(let spec)? = arguments["on_approve"] {
            guard let tool = spec["tool"]?.stringValue, !tool.isEmpty, let field = spec["text_field"]?.stringValue, !field.isEmpty else {
                throw ToolError.invalidArguments("on_approve needs tool and text_field")
            }
            var withAction = labelled
            withAction.action = ApprovalAction(tool: tool, arguments: spec["arguments"] ?? .object([:]), textField: field, label: spec["label"]?.stringValue ?? "Approve & send")
            try await hooks.postApproval(context.taskID, withAction)
            return .text(ToolCallID("pending"), name: "request_approval", "Card \(withAction.id) is up. When the user approves, Pennant runs \(tool) with the approved text; you don't need to wait. A change request will come back to you as a new message.")
        }
        let decided = try await hooks.requestApproval(context.taskID, labelled)
        let body: String
        switch decided.state {
        case .approved:
            body = """
            APPROVED (approval_id \(decided.id)). \(decided.approvedText == nil ? "Publish it exactly as shown." : "The user edited the text; the approved version is below.") Publish now with the approval_id; the publishing tool uses exactly this text\(decided.headline.map { ", the headline \"\($0)\"" } ?? "")\(decided.video.map { ", the video \($0.sourcePath)" } ?? "")\(decided.tags.isEmpty ? "" : ", the tags " + decided.tags.joined(separator: ", "))\(decided.details.isEmpty ? "" : ", the settings " + decided.details.map { "\($0.label): \($0.value)" }.joined(separator: "; ")) and these \(decided.images.count) image(s).\(decided.comment.map { "\nUser's note: \($0)" } ?? "")

            Approved text:
            \(decided.finalText)
            """
        case .changesRequested:
            body = "CHANGES REQUESTED: \(decided.comment ?? "(no comment)"). Revise the text and/or images accordingly, run your checks again, and call request_approval with the new version. Do not publish."
        case .rejected:
            body = "REJECTED\(decided.comment.map { ": \($0)" } ?? ""). Do not publish anything. Report back and stop."
        case .pending:
            body = "No decision was recorded. Do not publish."
        }
        return .text(ToolCallID("pending"), name: spec.name, body)
    }
}
