import PennantClientKit
import PennantCore
import PennantUI
import AppKit
import SwiftUI

/// Settings › Channels: how agents reach people outside Pennant. Telegram (a bot you create), iMessage (this Mac's
/// Messages), Teams (coming). Linked people and iMessage contacts, and who agents may message without asking.
struct ChannelsSettingsView: View {
    @Environment(\.hostSession) private var session
    @State private var overview = ChannelsOverview()
    @State private var telegramToken = ""
    @State private var link: ChannelLinkCode?
    @State private var newName = ""
    @State private var newHandle = ""
    @State private var teamsAppID = ""
    @State private var teamsTenantID = ""
    @State private var teamsURL = ""
    @State private var teamsSecret = ""
    @State private var busy = false
    @State private var askingMessages = false
    @State private var error: String?

    private func status(_ kind: ChannelKind) -> ChannelStatus? { overview.channels.first { $0.kind == kind } }

    var body: some View {
        SettingsPage {
            NotificationsSettingsCard()
            telegramCard
            imessageCard
            teamsCard
            contactsCard
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
        .task { await load() }
    }

    // MARK: Telegram

    private var telegramCard: some View {
        SettingsCard("Telegram") {
            if let s = status(.telegram) { statusRow(s) }
            if status(.telegram)?.configured != true {
                SettingsNote("In Telegram, message @BotFather, send /newbot, pick a name, and paste the token it gives you here. Agents can then reach people who link their Telegram, and you can talk to Pennant from Telegram.")
                HStack(spacing: 8) {
                    SecureField("123456789:AA…", text: $telegramToken).textFieldStyle(.plain).pennantField()
                    Button(busy ? "Checking…" : "Connect") { run(.setTelegramToken(telegramToken)) { telegramToken = "" } }
                        .buttonStyle(.pennantPrimaryCompact)
                        .disabled(busy || telegramToken.count < 20)
                }
            } else {
                Toggle("On", isOn: Binding(get: { status(.telegram)?.enabled ?? false }, set: { run(.setChannelEnabled(.telegram, enabled: $0)) }))
                HStack(spacing: 8) {
                    Button("Link my Telegram") { makeLink(.telegram) }.buttonStyle(.pennantCompact)
                    if let link, link.kind == .telegram {
                        if let url = link.url, let u = URL(string: url) {
                            Link("Open in Telegram", destination: u).font(.zoomed(.callout))
                        }
                        Text(link.code).font(.zoomed(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    }
                }
                SettingsNote("Opens a chat with the bot that links it to you (or send it the code). To link a teammate, send them the link: it works once, for 30 minutes.")
            }
        }
    }

    // MARK: iMessage

    private var imessageCard: some View {
        SettingsCard("iMessage") {
            if let s = status(.imessage) { statusRow(s) }
            Toggle("On", isOn: Binding(get: { status(.imessage)?.enabled ?? false }, set: { run(.setChannelEnabled(.imessage, enabled: $0)) }))
            if imessageNeedsSetup { imessageSetupGuide }
            SettingsNote("Uses this Mac's Messages. Only texts from your contacts and group chats below are read.")
            let personal = status(.imessage)?.settings?["personal"] != "false"
            Toggle("Messages here is my own Apple ID", isOn: Binding(get: { personal }, set: { run(.setIMessagePersonal($0)) }))
            SettingsNote(personal
                ? "Pennant answers only texts that start with “Pennant” (“Pennant, what's on today?”) and starts its replies with [Pennant]; your other conversations are left alone. Turn this off once Pennant has an Apple ID of its own."
                : "Pennant has its own Apple ID here: it answers every text from the contacts below.")
            HStack(spacing: 8) {
                TextField("Name", text: $newName).textFieldStyle(.plain).pennantField().frame(maxWidth: 180)
                TextField("Phone number or email", text: $newHandle).textFieldStyle(.plain).pennantField()
                Button("Add") {
                    let contact = ChannelContact(kind: .imessage, address: newHandle, name: newName, allowed: true)
                    run(.upsertChannelContact(contact)) { newName = ""; newHandle = "" }
                }
                .buttonStyle(.pennantPrimaryCompact)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newHandle.trimmingCharacters(in: .whitespaces).count < 3)
            }
            let groups = (status(.imessage)?.settings?["groups"] ?? "").split(separator: "\n").map(String.init)
            let added = Set(overview.contacts.filter { $0.kind == .imessage && $0.details?["type"] == "group" }.map { $0.address.lowercased() })
            Menu("Add a group chat") {
                ForEach(groups.filter { !added.contains($0.lowercased()) }, id: \.self) { name in
                    Button(name) {
                        var contact = ChannelContact(kind: .imessage, address: name, name: name, allowed: true)
                        contact.details = ["type": "group"]
                        run(.upsertChannelContact(contact))
                    }
                }
            }
            .fixedSize()
            .disabled(groups.allSatisfy { added.contains($0.lowercased()) })
            SettingsNote("In a group chat, anyone there can ask by starting a text with “Pennant”, and Pennant answers in the group, under the same rules as a Teams channel. Group chats need a name in Messages to be listed here.")
        }
    }

    /// iMessage is on but can't work yet: Messages can't be read, or Pennant hasn't been allowed to control it.
    private var imessageNeedsSetup: Bool {
        guard let s = status(.imessage), s.enabled else { return false }
        return s.settings?["fullDiskAccess"] != "granted" || s.settings?["messagesControl"] != "granted"
    }

    /// The two macOS grants iMessage needs, one step at a time, each ticking itself off once given.
    private var imessageSetupGuide: some View {
        let settings = status(.imessage)?.settings ?? [:]
        let grantee = settings["grantee"] ?? "Pennant Host"
        let canRead = settings["fullDiskAccess"] == "granted"
        let canSend = settings["messagesControl"] == "granted"
        return VStack(alignment: .leading, spacing: 12) {
            Text("Two macOS permissions, once").font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
            setupStep(1, done: canRead, title: "Let Pennant read Messages",
                      detail: "Open Full Disk Access, click +, choose “\(grantee)” (or drag it in from the Finder window) and turn it on. This screen ticks it off by itself.") {
                Button("Open Full Disk Access") { openPrivacyPane("Privacy_AllFiles") }.buttonStyle(.pennantPrimaryCompact)
                if let path = settings["granteePath"] {
                    Button("Show \(grantee) in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        .buttonStyle(.pennantCompact)
                }
            }
            setupStep(2, done: canSend, title: "Let Pennant send with Messages",
                      detail: settings["messagesControl"] == "denied"
                          ? "It was turned off: open Automation and turn on Messages under “Pennant”."
                          : "macOS asks once whether Pennant may control Messages: click Allow.") {
                if settings["messagesControl"] == "denied" {
                    Button("Open Automation") { openPrivacyPane("Privacy_Automation") }.buttonStyle(.pennantPrimaryCompact)
                } else {
                    Button(askingMessages ? "Asking…" : "Ask now") { askMessagesControl() }
                        .buttonStyle(.pennantPrimaryCompact).disabled(askingMessages)
                }
            }
        }
        .padding(12)
        .background(SettingsTone.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .task(id: imessageNeedsSetup) {
            // Grants show up here as soon as they're given.
            while imessageNeedsSetup, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let o = try? await session.channels() { overview = o }
            }
        }
    }

    private func setupStep<Actions: View>(_ n: Int, done: Bool, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.zoomed(.title3)).foregroundStyle(done ? SettingsTone.success : PennantTheme.inkSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(done ? PennantTheme.inkSecondary : PennantTheme.ink)
                if !done {
                    Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) { actions() }
                }
            }
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    private func askMessagesControl() {
        askingMessages = true
        Task {
            _ = try? await session.requestPermissions(["com.apple.MobileSMS"])
            if let o = try? await session.channels() { overview = o }
            askingMessages = false
        }
    }

    // MARK: Teams

    private var teamsCard: some View {
        SettingsCard("Microsoft Teams") {
            if let s = status(.teams), s.configured { statusRow(s) }
            PennantTextField("Bot app (client) ID", placeholder: "00000000-0000-0000-0000-000000000000", text: $teamsAppID)
            PennantTextField("Tenant ID", placeholder: "Your organisation's tenant id", text: $teamsTenantID)
            PennantTextField("Webhook address", placeholder: "https://<this-mac>.<tailnet>.ts.net/api/teams/messages", text: $teamsURL)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Client secret")
                SecureField(status(.teams)?.configured == true ? "Saved (leave empty to keep it)" : "The bot's client secret", text: $teamsSecret)
                    .textFieldStyle(.plain).pennantField()
            }
            HStack(spacing: 8) {
                Button(busy ? "Saving…" : "Save") {
                    run(.setTeamsBot(appID: teamsAppID, tenantID: teamsTenantID, publicURL: teamsURL, secret: teamsSecret.isEmpty ? nil : teamsSecret)) { teamsSecret = "" }
                }
                .buttonStyle(.pennantPrimaryCompact)
                .disabled(busy || teamsAppID.count < 30 || teamsTenantID.count < 30 || !teamsURL.hasPrefix("https://"))
                if status(.teams)?.configured == true {
                    Toggle("On", isOn: Binding(get: { status(.teams)?.enabled ?? false }, set: { run(.setChannelEnabled(.teams, enabled: $0)) }))
                    Button("Download Teams app…") { downloadTeamsPackage() }.buttonStyle(.pennantCompact)
                    Button("Link a Teams chat") { makeLink(.teams) }.buttonStyle(.pennantCompact)
                    if let link, link.kind == .teams {
                        Text(link.code).font(.zoomed(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            SettingsNote("Teammates who sign in to Pennant with Microsoft are linked on their first message to the bot; anyone else sends it a link code. Teams reaches this Mac only through the webhook address (Tailscale Funnel on that one path); only messages Microsoft signed for this bot are accepted.")
        }
        .onChange(of: status(.teams)?.settings) { _, settings in
            guard let settings else { return }
            if teamsAppID.isEmpty { teamsAppID = settings["appID"] ?? "" }
            if teamsTenantID.isEmpty { teamsTenantID = settings["tenantID"] ?? "" }
            if teamsURL.isEmpty { teamsURL = settings["publicURL"] ?? "" }
        }
    }

    /// The Teams app for the organisation: a manifest for this bot and the icons, zipped, for an admin to upload
    /// (Teams admin center › Manage apps › Upload) or to sideload.
    private func downloadTeamsPackage() {
        guard let appID = status(.teams)?.settings?["appID"] else { return }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-teams-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try TeamsAppPackage.manifest(botID: appID).write(to: dir.appendingPathComponent("manifest.json"))
            try TeamsAppPackage.png(PennantMark(size: 150).padding(21).frame(width: 192, height: 192).background(Color.white), size: 192).write(to: dir.appendingPathComponent("color.png"))
            try TeamsAppPackage.png(PennantShape().fill(Color.white).padding(2).frame(width: 32, height: 32), size: 32).write(to: dir.appendingPathComponent("outline.png"))
            let zip = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Pennant-Teams-app.zip")
            try? FileManager.default.removeItem(at: zip)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = ["-q", "-j", zip.path, "manifest.json", "color.png", "outline.png"]
            try p.run()
            p.waitUntilExit()
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: Contacts

    private var contactsCard: some View {
        SettingsCard("People agents can reach") {
            if overview.contacts.isEmpty {
                SettingsNote("Nobody yet. Link your Telegram above, or add iMessage contacts.")
            }
            ForEach(overview.contacts) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.kind == .telegram ? "paperplane" : c.kind == .imessage ? "message" : "person.2.wave.2")
                        .foregroundStyle(PennantTheme.inkSecondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        Text("\(c.kind.title) · \(c.address)\(c.lastMessageAt.map { " · last message \(relativeTime($0))" } ?? "")")
                            .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("Approvals", isOn: Binding(get: { c.forwardApprovals ?? false }, set: { on in
                        var updated = c
                        updated.forwardApprovals = on
                        run(.upsertChannelContact(updated))
                    }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Send every new approval card here too\(c.kind == .teams ? ", with Approve / Request changes / Reject buttons" : "")")
                    Toggle("Message without asking", isOn: Binding(get: { c.allowed }, set: { on in
                        var updated = c
                        updated.allowed = on
                        run(.upsertChannelContact(updated))
                    }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Off: every message an agent writes to \(c.name) waits for your approval first.")
                    Button { run(.removeChannelContact(id: c.id)) } label: { Image(systemName: "trash") }
                        .buttonStyle(.pennantIcon).help("Remove")
                }
            }
            SettingsNote("What they send arrives in the conversation of the agent that last wrote to them (for a day), or in their own thread with Pennant, whose answers go back to them.")
        }
    }

    private func statusRow(_ s: ChannelStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(s.healthy ? SettingsTone.success : (s.configured ? SettingsTone.warning : PennantTheme.inkTertiary)).frame(width: 8, height: 8)
            Text(s.detail).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2)
        }
    }

    // MARK: Actions

    private func load() async {
        do { overview = try await session.channels() } catch { self.error = String(describing: error) }
    }

    private func makeLink(_ kind: ChannelKind) {
        Task {
            do { link = try await session.channelLink(kind) } catch { self.error = String(describing: error) }
        }
    }

    private func run(_ body: CommandBody, then: @escaping () -> Void = {}) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { overview = try await session.channels(body); then() } catch { self.error = String(describing: error) }
        }
    }
}

/// The Teams app package's pieces.
enum TeamsAppPackage {
    static func manifest(botID: String) throws -> Data {
        let manifest: [String: Any] = [
            "$schema": "https://developer.microsoft.com/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
            "manifestVersion": "1.17",
            "version": "1.1.0",
            "id": botID,
            "developer": ["name": "Pennant", "websiteUrl": "https://pennant.dev", "privacyUrl": "https://pennant.dev/privacy", "termsOfUseUrl": "https://pennant.dev/terms"],
            "name": ["short": "Pennant", "full": "Pennant"],
            "description": ["short": "Your Pennant agents, in Teams.", "full": "Talk to your Pennant agents from Teams, in a chat of your own or by @mentioning Pennant in a channel or group chat, and let them reach you when something needs you."],
            "icons": ["color": "color.png", "outline": "outline.png"],
            "accentColor": "#7A4FE6",
            "bots": [["botId": botID, "scopes": ["personal", "team", "groupChat"], "supportsFiles": false, "isNotificationOnly": false]],
            "permissions": ["identity", "messageTeamMembers"],
            "validDomains": [String](),
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    @MainActor
    static func png(_ view: some View, size: CGFloat) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
