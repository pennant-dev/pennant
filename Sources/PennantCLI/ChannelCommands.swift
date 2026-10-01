import PennantClientKit
import PennantCore
import Foundation

// Chat channels: Teams, iMessage, and approvals from a chat.

@MainActor
func channelApprovalsCommand(_ options: CLIOptions) async throws {
    // pennant channels approvals <contact name> on|off: every approval card is also sent to that chat.
    guard options.args.count >= 3, ["on", "off"].contains(options.args.last!) else { fail("Usage: pennant channels approvals <contact name> on|off") }
    let who = options.args.dropFirst().dropLast().joined(separator: " ").lowercased()
    let session = try await connect(options)
    guard case .channels(let o) = try await session.send(.listChannels, timeout: 30) else { fail("Couldn't read the channels.") }
    guard var contact = o.contacts.first(where: { $0.name.lowercased() == who }) else {
        await session.disconnect()
        fail("No contact named \(who). Contacts: \(o.contacts.map(\.name).joined(separator: ", "))")
    }
    contact.forwardApprovals = options.args.last == "on"
    let r = try await session.send(.upsertChannelContact(contact), timeout: 30)
    await session.disconnect()
    guard case .channels = r else { fail(replyError(r)) }
    out("Approval cards \(contact.forwardApprovals == true ? "now also go to" : "no longer go to") \(contact.name) (\(contact.kind.title)).")
}

@MainActor
func iMessageCommand(_ options: CLIOptions) async throws {
    // pennant channels                               what's set up, and the contacts
    // pennant channels imessage on|off               iMessage through this Mac's Messages
    // pennant channels imessage personal on|off      Messages here is the owner's own Apple ID
    // pennant channels imessage add <name> <phone or email>
    // pennant channels imessage group <name>         a group chat in Messages, by its name
    let rest = Array(options.args.dropFirst())
    let usage = "Usage: pennant channels imessage on|off | personal on|off | add <name> <phone or email> | group <name>"
    let body: CommandBody
    switch (rest.first, rest.count) {
    case (nil, _): body = .listChannels
    case ("on", 1), ("off", 1): body = .setChannelEnabled(.imessage, enabled: rest[0] == "on")
    case ("personal", 2) where ["on", "off"].contains(rest[1]): body = .setIMessagePersonal(rest[1] == "on")
    case ("add", 3...): body = .upsertChannelContact(ChannelContact(kind: .imessage, address: rest.dropFirst(2).joined(separator: " "), name: rest[1], allowed: true))
    case ("group", 2...):
        var contact = ChannelContact(kind: .imessage, address: rest.dropFirst().joined(separator: " "), name: rest.dropFirst().joined(separator: " "), allowed: true)
        contact.details = ["type": "group"]
        body = .upsertChannelContact(contact)
    default: fail(usage)
    }
    let session = try await connect(options)
    let r = try await session.send(body, timeout: 30)
    await session.disconnect()
    guard case .channels(let o) = r else { fail(replyError(r)) }
    for c in o.channels { out("\(c.kind.title): \(c.enabled ? "on" : "off") · \(c.detail)\(c.settings?["personal"].map { " · personal Apple ID: \($0)" } ?? "")") }
    if let im = o.channels.first(where: { $0.kind == .imessage }), im.enabled, let set = im.settings {
        let grantee = set["grantee"] ?? "Pennant Host"
        if set["fullDiskAccess"] != "granted" { out("iMessage needs: Full Disk Access for “\(grantee)” (System Settings › Privacy & Security › Full Disk Access)") }
        if set["messagesControl"] != "granted" { out("iMessage needs: control of Messages (Settings › Channels › iMessage › Ask now, or the first reply asks)") }
    }
    if let groups = o.channels.first(where: { $0.kind == .imessage })?.settings?["groups"], !groups.isEmpty {
        out("Group chats in Messages: " + groups.split(separator: "\n").joined(separator: ", "))
    }
    for c in o.contacts {
        let group = c.details?["type"] == "group" ? (c.details?["group"] != nil ? " (group chat)" : " (group chat, not found in Messages yet)") : ""
        out("- \(c.kind.title) · \(c.name) · \(c.kind == .teams ? String(c.address.prefix(24)) : c.address)\(group)\(c.allowed ? "" : " · asks first")")
    }
}

@MainActor
func channelsCommand(_ options: CLIOptions) async throws {
    // pennant channels teams --app-id <guid> --tenant <guid> --url <https://…> [--secret-stdin]
    // The secret is read from stdin so it never lands in shell history or output.
    guard options.args.first == "teams" else { fail("Usage: pennant channels teams --app-id <guid> --tenant <guid> --url <https://…> [--secret-stdin]") }
    var rest = Array(options.args.dropFirst())
    func take(_ flag: String) -> String? {
        guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
        let v = rest[i + 1]; rest.removeSubrange(i...(i + 1)); return v
    }
    guard let appID = take("--app-id"), let tenant = take("--tenant"), let url = take("--url") else { fail("Need --app-id, --tenant and --url") }
    var secret: String?
    if rest.contains("--secret-stdin") {
        secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if secret?.isEmpty == true { fail("No secret on stdin") }
    }
    let session = try await connect(options)
    let r = try await session.send(.setTeamsBot(appID: appID, tenantID: tenant, publicURL: url, secret: secret), timeout: 30)
    await session.disconnect()
    guard case .channels(let o) = r else { fail(replyError(r)) }
    out("Teams: \(o.channels.first { $0.kind == .teams }?.detail ?? "saved")")
}
