import PennantCore
import Foundation
import MCP

/// Microsoft 365 through Microsoft Graph with the user's own delegated sign-in: Outlook mail, calendar, Teams chats
/// and channels, OneDrive and SharePoint files. No Copilot licence needed; the permissions are the ones the user's
/// app registration grants.
struct MicrosoftGraphConnector: NativeConnector {
    static let id = "microsoft365"
    let displayName = "Microsoft 365"
    private static let base = "https://graph.microsoft.com/v1.0"

    var tools: [MCP.Tool] {
        [
            .make("whoami", "The signed-in Microsoft 365 user: name, email, job title.", readOnly: true),
            // Mail
            .make("mail_search", "Search or list Outlook mail. Without a query, lists the newest messages of the folder.", properties: [
                "query": Prop.str("Search words (KQL, e.g. from:dana subject:invoice). Optional."),
                "folder": Prop.oneOf("Folder to list when there is no query", ["inbox", "sentitems", "drafts", "archive", "deleteditems"]),
                "unread_only": Prop.bool("Only unread messages"),
                "limit": Prop.int("How many (default 15, max 50)"),
            ], readOnly: true),
            .make("mail_read", "Read one Outlook message in full (plain text body), with its thread id (for mail_thread) and Outlook link.", properties: ["id": Prop.str("Message id from mail_search")], required: ["id"], readOnly: true),
            .make("mail_thread", "Read a whole email conversation, oldest first: every message in the thread (received and sent), trimmed of quoted history.", properties: [
                "conversation_id": Prop.str("Thread id from mail_read"),
                "limit": Prop.int("How many messages at most (default 20)"),
            ], required: ["conversation_id"], readOnly: true),
            .make("mail_send", "Send an email from the user's mailbox.", properties: [
                "to": Prop.strings("Recipient addresses"),
                "cc": Prop.strings("Cc addresses"),
                "subject": Prop.str("Subject"),
                "body": Prop.str("Body; plain text unless html is true"),
                "html": Prop.bool("The body is HTML"),
            ], required: ["to", "subject", "body"], readOnly: false, destructive: true),
            .make("mail_reply", "Reply to an Outlook message.", properties: [
                "id": Prop.str("Message id"),
                "body": Prop.str("Reply text"),
                "reply_all": Prop.bool("Reply to all recipients"),
            ], required: ["id", "body"], readOnly: false, destructive: true),
            .make("mail_draft", "Save a draft in Outlook without sending it.", properties: [
                "to": Prop.strings("Recipient addresses"),
                "subject": Prop.str("Subject"),
                "body": Prop.str("Body"),
            ], required: ["subject", "body"], readOnly: false),
            // Calendar
            .make("calendar_events", "Events between two times (default: now to 7 days ahead).", properties: [
                "start": Prop.str("ISO 8601 start, e.g. 2026-09-22T00:00:00"),
                "end": Prop.str("ISO 8601 end"),
                "limit": Prop.int("How many (default 25)"),
            ], readOnly: true),
            .make("calendar_create_event", "Create a calendar event, optionally a Teams meeting with invitees.", properties: [
                "subject": Prop.str("Title"),
                "start": Prop.str("ISO 8601 local start, e.g. 2026-09-23T15:00:00"),
                "end": Prop.str("ISO 8601 local end"),
                "time_zone": Prop.str("IANA or Windows time zone of start/end, e.g. America/New_York (default UTC)"),
                "attendees": Prop.strings("Attendee email addresses"),
                "body": Prop.str("Description"),
                "location": Prop.str("Location"),
                "teams_meeting": Prop.bool("Add a Teams meeting link"),
            ], required: ["subject", "start", "end"], readOnly: false, destructive: true),
            // Teams chats
            .make("teams_chats", "The user's recent Teams chats (one-on-one, group, meeting) with members and topic.", properties: ["limit": Prop.int("How many (default 20)")], readOnly: true),
            .make("teams_chat_messages", "Recent messages in a Teams chat, newest first.", properties: [
                "chat_id": Prop.str("Chat id from teams_chats"),
                "limit": Prop.int("How many (default 20, max 50)"),
            ], required: ["chat_id"], readOnly: true),
            .make("teams_send_chat", "Send a message in an existing Teams chat. With Pennant's Teams bot set up it goes from Pennant, in chats Pennant has been added to (it can't post elsewhere).", properties: [
                "chat_id": Prop.str("Chat id"),
                "text": Prop.str("Message text"),
            ], required: ["chat_id", "text"], readOnly: false, destructive: true),
            .make("teams_message_person", "Send a one-on-one Teams message to someone in the organisation (found by their work email). With Pennant's Teams bot set up it goes from Pennant and their reply comes back to you.", properties: [
                "email": Prop.str("The person's work email"),
                "text": Prop.str("Message text"),
            ], required: ["email", "text"], readOnly: false, destructive: true),
            .make("people_lookup", "Find someone in the organisation by work email: their name and Microsoft account id.", properties: [
                "email": Prop.str("Their work email"),
            ], required: ["email"], readOnly: true),
            // Teams channels
            .make("teams_teams", "Teams the user belongs to.", readOnly: true),
            .make("teams_channels", "Channels of a team.", properties: ["team_id": Prop.str("Team id from teams_teams")], required: ["team_id"], readOnly: true),
            .make("teams_channel_messages", "Recent posts in a channel (needs the ChannelMessage.Read.All permission, which an admin must grant).", properties: [
                "team_id": Prop.str("Team id"),
                "channel_id": Prop.str("Channel id"),
                "limit": Prop.int("How many (default 15, max 50)"),
            ], required: ["team_id", "channel_id"], readOnly: true),
            .make("teams_post_channel", "Post a message in a channel, or reply to a post. With Pennant's Teams bot set up it goes from Pennant, in channels Pennant has been added to (it can't post elsewhere).", properties: [
                "team_id": Prop.str("Team id"),
                "channel_id": Prop.str("Channel id"),
                "text": Prop.str("Message text"),
                "reply_to": Prop.str("Message id to reply to (optional)"),
            ], required: ["team_id", "channel_id", "text"], readOnly: false, destructive: true),
            // Files
            .make("files_search", "Search the user's OneDrive and files shared with them.", properties: [
                "query": Prop.str("Search words"),
                "limit": Prop.int("How many (default 20)"),
            ], required: ["query"], readOnly: true),
            .make("files_read", "Read a text file (txt, md, csv, json, html…) from OneDrive or SharePoint by item id. Office files come back as their text when Graph can convert them.", properties: [
                "item_id": Prop.str("Item id from files_search"),
                "drive_id": Prop.str("Drive id, for items outside the user's own OneDrive"),
            ], required: ["item_id"], readOnly: true),
        ]
    }

    func call(_ tool: String, arguments a: [String: Value], api: ConnectorAPI) async throws -> String {
        switch tool {
        case "whoami":
            let me = try await get(api, "/me?$select=displayName,mail,userPrincipalName,jobTitle,officeLocation")
            return "\(me["displayName"] ?? "") <\(me["mail"] as? String ?? me["userPrincipalName"] as? String ?? "")>\(title(me["jobTitle"]))"

        case "mail_search":
            let limit = min(max(a.int("limit") ?? 15, 1), 50)
            var path: String
            var headers: [String: String] = [:]
            let select = "$select=id,subject,from,receivedDateTime,isRead,bodyPreview,hasAttachments"
            if let q = a.string("query") {
                path = "/me/messages?$search=\"\(ConnectorText.encodeQuery(q.replacingOccurrences(of: "\"", with: "")))\"&$top=\(limit)&\(select)"
                headers["ConsistencyLevel"] = "eventual"
            } else {
                let folder = a.string("folder") ?? "inbox"
                path = "/me/mailFolders/\(folder)/messages?$top=\(limit)&$orderby=receivedDateTime desc&\(select)"
                if a.bool("unread_only") == true { path += "&$filter=isRead eq false" }
            }
            let reply = try await get(api, path, headers: headers)
            let items = reply["value"] as? [[String: Any]] ?? []
            if items.isEmpty { return "No messages." }
            return items.map { m in
                let from = ((m["from"] as? [String: Any])?["emailAddress"] as? [String: Any])
                let who = "\(from?["name"] as? String ?? "") <\(from?["address"] as? String ?? "")>"
                let unread = (m["isRead"] as? Bool) == false ? " [unread]" : ""
                return "• \(m["subject"] as? String ?? "(no subject)")\(unread)\n  from \(who) · \(m["receivedDateTime"] as? String ?? "")\n  \(String((m["bodyPreview"] as? String ?? "").prefix(160)))\n  id: \(m["id"] as? String ?? "")"
            }.joined(separator: "\n")

        case "mail_read":
            let id = try a.require("id")
            let m = try await get(api, "/me/messages/\(id)?$select=subject,from,toRecipients,ccRecipients,receivedDateTime,body,hasAttachments,conversationId,webLink,importance", headers: ["Prefer": "outlook.body-content-type=\"text\""])
            let body = (m["body"] as? [String: Any])?["content"] as? String ?? ""
            let from = ((m["from"] as? [String: Any])?["emailAddress"] as? [String: Any])?["address"] as? String ?? ""
            return ConnectorText.clip("""
            Subject: \(m["subject"] as? String ?? "")
            From: \(from)
            To: \(addresses(m["toRecipients"]))
            Cc: \(addresses(m["ccRecipients"]))
            Date: \(m["receivedDateTime"] as? String ?? "")\((m["hasAttachments"] as? Bool) == true ? "\nHas attachments" : "")\((m["importance"] as? String) == "high" ? "\nImportance: high" : "")
            Thread: \(m["conversationId"] as? String ?? "")
            Link: \(m["webLink"] as? String ?? "")

            \(body)
            """)

        case "mail_thread":
            let conversation = try a.require("conversation_id").replacingOccurrences(of: "'", with: "''")
            let limit = min(max(a.int("limit") ?? 20, 1), 50)
            let filter = ConnectorText.encodeQuery("conversationId eq '\(conversation)'")
            let reply = try await get(api, "/me/messages?$filter=\(filter)&$top=\(limit)&$select=subject,from,toRecipients,receivedDateTime,uniqueBody,isDraft", headers: ["Prefer": "outlook.body-content-type=\"text\""])
            let items = (reply["value"] as? [[String: Any]] ?? []).filter { ($0["isDraft"] as? Bool) != true }
                .sorted { ($0["receivedDateTime"] as? String ?? "") < ($1["receivedDateTime"] as? String ?? "") }
            if items.isEmpty { return "No messages in that thread." }
            return ConnectorText.clip(items.map { m in
                let from = ((m["from"] as? [String: Any])?["emailAddress"] as? [String: Any])
                let body = ((m["uniqueBody"] as? [String: Any])?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return "— \(from?["name"] as? String ?? "") <\(from?["address"] as? String ?? "")> · \(m["receivedDateTime"] as? String ?? "")\n\(body)"
            }.joined(separator: "\n\n"))

        case "mail_send":
            let to = a.strings("to")
            guard !to.isEmpty else { throw ConnectorAPI.Failure(status: 0, message: "Give at least one recipient.") }
            let message: [String: Any] = [
                "subject": try a.require("subject"),
                "body": ["contentType": a.bool("html") == true ? "HTML" : "Text", "content": try a.require("body")],
                "toRecipients": recipients(to),
                "ccRecipients": recipients(a.strings("cc")),
            ]
            _ = try await api.send("POST", url("/me/sendMail"), json: ["message": message, "saveToSentItems": true])
            return "Sent “\(a.string("subject") ?? "")” to \(to.joined(separator: ", "))."

        case "mail_reply":
            let id = try a.require("id")
            let verb = a.bool("reply_all") == true ? "replyAll" : "reply"
            // Graph reads a reply's `comment` as HTML, so plain text sent that way loses its line breaks. Create the
            // reply as a draft (it carries the quoted thread), put the text above the quote as HTML, then send it.
            let body = try a.require("body")
            let draft = try await api.json("POST", url("/me/messages/\(id)/\(verb == "reply" ? "createReply" : "createReplyAll")"), json: [:])
            guard let draftID = draft["id"] as? String else { throw ConnectorAPI.Failure(status: 0, message: "Outlook didn't return the reply draft.") }
            let quoted = ((draft["body"] as? [String: Any])?["content"] as? String) ?? ""
            _ = try await api.json("PATCH", url("/me/messages/\(draftID)"), json: ["body": ["contentType": "HTML", "content": Self.replyHTML(body, above: quoted)]])
            _ = try await api.send("POST", url("/me/messages/\(draftID)/send"))
            return a.bool("reply_all") == true ? "Replied to all." : "Replied."

        case "mail_draft":
            let draft: [String: Any] = [
                "subject": try a.require("subject"),
                "body": ["contentType": "Text", "content": try a.require("body")],
                "toRecipients": recipients(a.strings("to")),
            ]
            let saved = try await api.json("POST", url("/me/messages"), json: draft)
            return "Saved a draft (id \(saved["id"] as? String ?? "?")). Open Outlook's Drafts to review and send it."

        case "calendar_events":
            let now = Date()
            let iso = ISO8601DateFormatter()
            let start = a.string("start") ?? iso.string(from: now)
            let end = a.string("end") ?? iso.string(from: now.addingTimeInterval(7 * 86_400))
            let limit = min(max(a.int("limit") ?? 25, 1), 100)
            let reply = try await get(api, "/me/calendarView?startDateTime=\(ConnectorText.encodeQuery(start))&endDateTime=\(ConnectorText.encodeQuery(end))&$top=\(limit)&$orderby=start/dateTime&$select=id,subject,start,end,location,organizer,attendees,isOnlineMeeting,onlineMeeting")
            let items = reply["value"] as? [[String: Any]] ?? []
            if items.isEmpty { return "No events between \(start) and \(end)." }
            return items.map { e in
                let s = (e["start"] as? [String: Any])?["dateTime"] as? String ?? ""
                let en = (e["end"] as? [String: Any])?["dateTime"] as? String ?? ""
                let tz = (e["start"] as? [String: Any])?["timeZone"] as? String ?? ""
                let place = ((e["location"] as? [String: Any])?["displayName"] as? String).flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
                let who = (e["attendees"] as? [[String: Any]] ?? []).compactMap { (($0["emailAddress"] as? [String: Any])?["name"] as? String) }.prefix(6).joined(separator: ", ")
                let link = ((e["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String).map { "\n  join: \($0)" } ?? ""
                return "• \(e["subject"] as? String ?? "(no title)") — \(s) to \(en) \(tz)\(place)\(who.isEmpty ? "" : "\n  with \(who)")\(link)\n  id: \(e["id"] as? String ?? "")"
            }.joined(separator: "\n")

        case "calendar_create_event":
            let tz = a.string("time_zone") ?? "UTC"
            var event: [String: Any] = [
                "subject": try a.require("subject"),
                "start": ["dateTime": try a.require("start"), "timeZone": tz],
                "end": ["dateTime": try a.require("end"), "timeZone": tz],
                "attendees": a.strings("attendees").map { ["emailAddress": ["address": $0], "type": "required"] },
            ]
            if let body = a.string("body") { event["body"] = ["contentType": "Text", "content": body] }
            if let location = a.string("location") { event["location"] = ["displayName": location] }
            if a.bool("teams_meeting") == true {
                event["isOnlineMeeting"] = true
                event["onlineMeetingProvider"] = "teamsForBusiness"
            }
            let created = try await api.json("POST", url("/me/events"), json: event)
            let join = ((created["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String).map { " Teams link: \($0)" } ?? ""
            return "Created “\(created["subject"] as? String ?? "")”.\(join) Invitations went to \(a.strings("attendees").joined(separator: ", ").ifEmpty("nobody"))."

        case "teams_chats":
            let limit = min(max(a.int("limit") ?? 20, 1), 50)
            let reply = try await get(api, "/me/chats?$top=\(limit)&$expand=members,lastMessagePreview&$orderby=lastMessagePreview/createdDateTime desc")
            let items = reply["value"] as? [[String: Any]] ?? []
            if items.isEmpty { return "No chats." }
            return items.map { c in
                let members = (c["members"] as? [[String: Any]] ?? []).compactMap { $0["displayName"] as? String }.prefix(8).joined(separator: ", ")
                let preview = c["lastMessagePreview"] as? [String: Any]
                let last = ((preview?["body"] as? [String: Any])?["content"] as? String).map { ConnectorText.plain(fromHTML: $0) } ?? ""
                let topic = (c["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? members
                return "• \(topic) [\(c["chatType"] as? String ?? "")]\n  last: \(String(last.prefix(140)))\n  id: \(c["id"] as? String ?? "")"
            }.joined(separator: "\n")

        case "teams_chat_messages":
            let chat = try a.require("chat_id")
            let limit = min(max(a.int("limit") ?? 20, 1), 50)
            let reply = try await get(api, "/me/chats/\(chat)/messages?$top=\(limit)")
            return render(messages: reply["value"] as? [[String: Any]] ?? [])

        case "teams_send_chat":
            let chat = try a.require("chat_id")
            let sent = try await api.json("POST", url("/chats/\(chat)/messages"), json: ["body": ["contentType": "text", "content": try a.require("text")]])
            return "Sent (message id \(sent["id"] as? String ?? "?"))."

        case "teams_message_person":
            let email = try a.require("email")
            let me = try await get(api, "/me?$select=id")
            guard let myID = me["id"] as? String else { throw ConnectorAPI.Failure(status: 0, message: "Could not read your own user id.") }
            let chat = try await api.json("POST", url("/chats"), json: [
                "chatType": "oneOnOne",
                "members": [
                    ["@odata.type": "#microsoft.graph.aadUserConversationMember", "roles": ["owner"], "user@odata.bind": "https://graph.microsoft.com/v1.0/users('\(myID)')"],
                    ["@odata.type": "#microsoft.graph.aadUserConversationMember", "roles": ["owner"], "user@odata.bind": "https://graph.microsoft.com/v1.0/users('\(email)')"],
                ],
            ])
            guard let chatID = chat["id"] as? String else { throw ConnectorAPI.Failure(status: 0, message: "Teams did not return a chat.") }
            _ = try await api.json("POST", url("/chats/\(chatID)/messages"), json: ["body": ["contentType": "text", "content": try a.require("text")]])
            return "Sent to \(email) (chat id \(chatID))."

        case "people_lookup":
            let email = try a.require("email").trimmingCharacters(in: .whitespaces)
            let user = try await get(api, "/users/\(ConnectorText.encodeQuery(email))?$select=id,displayName,mail,userPrincipalName")
            let found: [String: Any] = ["id": user["id"] as? String ?? "", "name": user["displayName"] as? String ?? email, "email": user["mail"] as? String ?? user["userPrincipalName"] as? String ?? email]
            return String(data: try JSONSerialization.data(withJSONObject: found, options: [.sortedKeys]), encoding: .utf8) ?? "{}"

        case "teams_teams":
            let reply = try await get(api, "/me/joinedTeams?$select=id,displayName,description")
            let items = reply["value"] as? [[String: Any]] ?? []
            if items.isEmpty { return "Not a member of any team." }
            return items.map { "• \($0["displayName"] as? String ?? "")\(title($0["description"]))\n  id: \($0["id"] as? String ?? "")" }.joined(separator: "\n")

        case "teams_channels":
            let team = try a.require("team_id")
            let reply = try await get(api, "/teams/\(team)/channels?$select=id,displayName,description,membershipType")
            let items = reply["value"] as? [[String: Any]] ?? []
            return items.map { "• \($0["displayName"] as? String ?? "") [\($0["membershipType"] as? String ?? "")]\n  id: \($0["id"] as? String ?? "")" }.joined(separator: "\n").ifEmpty("No channels.")

        case "teams_channel_messages":
            let team = try a.require("team_id"), channel = try a.require("channel_id")
            let limit = min(max(a.int("limit") ?? 15, 1), 50)
            let reply = try await get(api, "/teams/\(team)/channels/\(channel)/messages?$top=\(limit)")
            return render(messages: reply["value"] as? [[String: Any]] ?? [])

        case "teams_post_channel":
            let team = try a.require("team_id"), channel = try a.require("channel_id")
            var path = "/teams/\(team)/channels/\(channel)/messages"
            if let parent = a.string("reply_to") { path += "/\(parent)/replies" }
            let sent = try await api.json("POST", url(path), json: ["body": ["contentType": "text", "content": try a.require("text")]])
            return "Posted (message id \(sent["id"] as? String ?? "?"))."

        case "files_search":
            let q = try a.require("query").replacingOccurrences(of: "'", with: "''")
            let limit = min(max(a.int("limit") ?? 20, 1), 50)
            let reply = try await get(api, "/me/drive/root/search(q='\(ConnectorText.encodeQuery(q))')?$top=\(limit)&$select=id,name,webUrl,size,lastModifiedDateTime,parentReference,file,folder")
            let items = reply["value"] as? [[String: Any]] ?? []
            if items.isEmpty { return "No files match." }
            return items.map { f in
                let drive = (f["parentReference"] as? [String: Any])?["driveId"] as? String ?? ""
                let kind = f["folder"] != nil ? "folder" : ((f["file"] as? [String: Any])?["mimeType"] as? String ?? "file")
                return "• \(f["name"] as? String ?? "") [\(kind), \(f["size"] as? Int ?? 0) bytes, modified \(f["lastModifiedDateTime"] as? String ?? "")]\n  \(f["webUrl"] as? String ?? "")\n  item_id: \(f["id"] as? String ?? "") drive_id: \(drive)"
            }.joined(separator: "\n")

        case "files_read":
            let item = try a.require("item_id")
            let prefix = a.string("drive_id").map { "/drives/\($0)" } ?? "/me/drive"
            let meta = try await get(api, "\(prefix)/items/\(item)?$select=name,size,file")
            let name = meta["name"] as? String ?? "file"
            let ext = (name as NSString).pathExtension.lowercased()
            let textTypes: Set<String> = ["txt", "md", "csv", "json", "html", "htm", "xml", "yaml", "yml", "log", "tsv"]
            // Office documents convert to plain text through Graph's format conversion where supported.
            let officeTypes: Set<String> = ["docx", "doc", "pptx", "rtf", "odt"]
            var path = "\(prefix)/items/\(item)/content"
            if officeTypes.contains(ext) { path += "?format=html" } else if !textTypes.contains(ext) {
                throw ConnectorAPI.Failure(status: 0, message: "\(name) is not a text file Pennant can read here; open its web link instead.")
            }
            let (data, _) = try await api.send("GET", url(path))
            var text = String(decoding: data.prefix(400_000), as: UTF8.self)
            if officeTypes.contains(ext) || ext == "html" || ext == "htm" { text = ConnectorText.plain(fromHTML: text) }
            return ConnectorText.clip("\(name)\n\n\(text)", 20_000)

        default:
            throw ConnectorAPI.Failure(status: 0, message: "Unknown tool \(tool).")
        }
    }

    // MARK: Helpers

    private func url(_ path: String) -> URL {
        URL(string: Self.base + path) ?? URL(string: Self.base)!
    }

    private func get(_ api: ConnectorAPI, _ path: String, headers: [String: String] = [:]) async throws -> [String: Any] {
        // Values are encoded where they are built; only the literal spaces and quotes of OData syntax remain.
        let encoded = path.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "\"", with: "%22")
        guard let u = URL(string: Self.base + encoded) else { throw ConnectorAPI.Failure(status: 0, message: "Bad Graph path \(path)") }
        return try await api.json("GET", u, headers: headers)
    }

    private func recipients(_ list: [String]) -> [[String: Any]] {
        list.map { ["emailAddress": ["address": $0]] }
    }

    private func addresses(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).compactMap { (($0["emailAddress"] as? [String: Any])?["address"] as? String) }.joined(separator: ", ")
    }

    private func title(_ value: Any?) -> String {
        guard let s = value as? String, !s.isEmpty else { return "" }
        return " — \(s)"
    }

    private func render(messages: [[String: Any]]) -> String {
        let lines = messages.compactMap { m -> String? in
            guard (m["messageType"] as? String ?? "message") == "message" else { return nil }
            let who = ((m["from"] as? [String: Any])?["user"] as? [String: Any])?["displayName"] as? String ?? "someone"
            let body = ConnectorText.plain(fromHTML: (m["body"] as? [String: Any])?["content"] as? String ?? "")
            return "• \(who) · \(m["createdDateTime"] as? String ?? "")\n  \(body)\n  id: \(m["id"] as? String ?? "")"
        }
        return lines.isEmpty ? "No messages." : ConnectorText.clip(lines.joined(separator: "\n"))
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension MicrosoftGraphConnector {
    /// Plain text as Outlook HTML: blank lines separate paragraphs, single line breaks stay line breaks.
    static func html(fromPlainText text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        return paragraphs.map { "<p style=\"margin:0 0 12px 0\">" + $0.replacingOccurrences(of: "\n", with: "<br>") + "</p>" }.joined()
    }

    /// The reply's text placed at the top of the draft's body (above Outlook's quoted thread).
    static func replyHTML(_ text: String, above quoted: String) -> String {
        let reply = "<div style=\"font-family:Aptos,Calibri,Arial,sans-serif;font-size:11pt\">" + html(fromPlainText: text) + "</div>"
        guard let open = quoted.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) else { return reply + quoted }
        var out = quoted
        out.insert(contentsOf: reply, at: open.upperBound)
        return out
    }
}
