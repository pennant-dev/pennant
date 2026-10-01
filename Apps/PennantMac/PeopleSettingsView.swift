import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Settings › People: your own account, who can use this Mac's agents, who is invited, and how people sign in.
/// Everyone signs in on their devices with an email and password or with Microsoft, Google or GitHub; invited
/// people join with a one-time code, and anyone from an allowed Microsoft organisation joins without an invite.
struct PeopleSettingsView: View {
    @Environment(\.hostSession) private var session
    @State private var inviteEmail = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmRemove: Person?
    @State private var copied = false
    // The sign-in form, edited locally and saved together.
    @State private var msClientID = ""
    @State private var msTenant = ""
    @State private var allowedTenants = ""
    @State private var googleClientID = ""
    @State private var githubClientID = ""
    @State private var loadedSettings: SignInSettings?

    private var directory: PeopleDirectory? { session.state.people }

    var body: some View {
        SettingsPage {
            accountCard
            peopleCard
            inviteCard
            signInCard
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
        .task { await load() }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { p in
            Button("Remove", role: .destructive) { run(.removePerson(p.id)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They're signed out on every device, and their Microsoft access is forgotten. Their messages stay.")
        }
    }

    // MARK: Cards

    /// The owner's account on this Mac: what you sign in with on your phone and other devices.
    private var owner: Person? { directory?.people.first { $0.role == .owner } }

    private var accountCard: some View {
        SettingsCard("Your account") {
            if owner?.canSignIn != true {
                SettingsNote("Set an email and password so you can sign in from your phone and other Macs. This Mac is always signed in as you.", tone: SettingsTone.warning)
            }
            MyAccountForm(person: owner, asksCurrentPassword: false)
        }
    }

    private var peopleCard: some View {
        SettingsCard("People") {
            SettingsRow("You", value: session.state.me.map { "\($0.name) · owner · this Mac" } ?? "Owner · this Mac")
            let members = directory?.people ?? []
            if members.isEmpty {
                SettingsNote("No teammates yet. Invite someone below, or allow your Microsoft organisation to join without invites.")
            }
            ForEach(members) { p in
                HStack(spacing: 10) {
                    Text(String(p.name.prefix(1)).uppercased())
                        .font(.zoomed(.callout).weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color(hex: "#6A3FD9"), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        Text(([p.email] + p.identities.map(\.provider.title)).joined(separator: " · "))
                            .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let seen = p.lastSeenAt {
                        Text("Seen \(relativeTime(seen))").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    if p.role == .owner { Chip("Owner", color: PennantTheme.brandInk) }
                    Menu {
                        if p.role == .owner {
                            Button("Make member") { run(.setPersonRole(p.id, .member)) }
                        } else {
                            Button("Make owner") { run(.setPersonRole(p.id, .owner)) }
                        }
                        Divider()
                        Button("Remove…", role: .destructive) { confirmRemove = p }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.pennantIcon).fixedSize()
                }
            }
        }
    }

    private var inviteCard: some View {
        SettingsCard("Invite") {
            HStack(spacing: 8) {
                TextField("name@company.com", text: $inviteEmail)
                    .textFieldStyle(.plain).pennantField()
                    .onSubmit(invite)
                Button("Invite", action: invite).buttonStyle(.pennantPrimaryCompact)
                    .disabled(!inviteEmail.contains("@") || busy)
            }
            ForEach(directory?.invites ?? []) { i in
                HStack(spacing: 10) {
                    Image(systemName: "envelope").foregroundStyle(PennantTheme.inkSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.email).font(.zoomed(.callout))
                        Text(i.isExpired ? "Code expired" : "Invited \(relativeTime(i.invitedAt))\(i.expiresAt.map { " · code works until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
                            .font(.zoomed(.caption)).foregroundStyle(i.isExpired ? PennantTheme.danger : PennantTheme.inkTertiary)
                    }
                    Spacer()
                    if let code = i.displayCode, !i.isExpired {
                        Text(code).font(.zoomed(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        Button("Copy invite") { copyInvite(i, code: code) }.buttonStyle(.pennantCompact)
                    } else {
                        Button("New code") { run(.invitePerson(email: i.email)) }.buttonStyle(.pennantCompact)
                    }
                    Menu {
                        Button("New code") { run(.invitePerson(email: i.email)) }
                        Button("Cancel invite", role: .destructive) { run(.removeInvite(email: i.email)) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.pennantIcon).fixedSize()
                }
            }
            if copied { SettingsNote("Invite copied. Paste it into an email or message.") }
            SettingsNote("They install Pennant, choose this Mac, then either sign in with Microsoft, Google or GitHub using this email, or tap “I have an invite code” and choose a password. Codes last a week and work once.")
        }
    }

    private var signInCard: some View {
        SettingsCard("Sign-in") {
            providerFields("Microsoft", systemImage: "building.2") {
                PennantTextField("Application (client) ID", placeholder: "00000000-0000-0000-0000-000000000000", text: $msClientID)
                PennantTextField("Tenant", placeholder: "Your tenant ID, or organizations", text: $msTenant)
                PennantTextField("Organisations that join without an invite", placeholder: "Tenant IDs, comma-separated", text: $allowedTenants)
                SettingsNote("An Entra app registration (public client). Add the redirect URI pennant://auth under Mobile and desktop applications. The Microsoft 365 permissions it grants are what agents can use on each person's behalf.")
                if let clientID = connectorClientID, msClientID.isEmpty {
                    Button("Use the Microsoft 365 connection's app") { msClientID = clientID }.buttonStyle(.pennantCompact)
                }
            }
            providerFields("Google", systemImage: "g.circle") {
                PennantTextField("iOS client ID", placeholder: "…apps.googleusercontent.com", text: $googleClientID)
                SettingsNote("A Google Cloud OAuth client of type iOS, for the phone app's bundle ID.")
            }
            providerFields("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                PennantTextField("OAuth app client ID", placeholder: "Iv1.…", text: $githubClientID)
                SettingsNote("A GitHub OAuth app with Device Flow enabled. No secret is needed.")
            }
            SettingsNote("Sign-ins are only accepted over encrypted connections: the Pennant app always encrypts, on your network or over Tailscale.")
            HStack {
                Spacer()
                Button(busy ? "Saving…" : "Save sign-in settings", action: saveSignIn).buttonStyle(.pennantPrimaryCompact).disabled(busy || !changed)
            }
        }
    }

    private func providerFields<Content: View>(_ title: String, systemImage: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
            content()
        }
        .padding(.bottom, 6)
    }

    // MARK: Actions

    /// The client id the Microsoft 365 connection already signs in with, if it's connected.
    private var connectorClientID: String? {
        for s in session.state.mcpServers where s.config.catalogID == "microsoft365" {
            if case .oauth(_, let id?, _) = s.config.auth, !id.isEmpty { return id }
        }
        return nil
    }

    private var edited: SignInSettings {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        return SignInSettings(
            microsoft: trimmed(msClientID).isEmpty ? nil : .init(clientID: trimmed(msClientID), tenant: trimmed(msTenant).isEmpty ? nil : trimmed(msTenant)),
            google: trimmed(googleClientID).isEmpty ? nil : .init(clientID: trimmed(googleClientID)),
            github: trimmed(githubClientID).isEmpty ? nil : .init(clientID: trimmed(githubClientID)),
            allowedTenants: allowedTenants.split(separator: ",").map { trimmed(String($0)) }.filter { !$0.isEmpty })
    }

    private var changed: Bool { loadedSettings != edited }

    private func load() async {
        do {
            try await session.loadPeople()
            if let s = session.state.people?.signIn { fill(s) }
        } catch { self.error = String(describing: error) }
    }

    private func fill(_ s: SignInSettings) {
        msClientID = s.microsoft?.clientID ?? ""
        msTenant = s.microsoft?.tenant ?? ""
        allowedTenants = s.allowedTenants.joined(separator: ", ")
        googleClientID = s.google?.clientID ?? ""
        githubClientID = s.github?.clientID ?? ""
        loadedSettings = s
    }

    private func invite() {
        let email = inviteEmail
        guard email.contains("@") else { return }
        run(.invitePerson(email: email)) { inviteEmail = "" }
    }

    /// A message to send the invitee: which Mac, the code, and what to do.
    private func copyInvite(_ invite: PersonInvite, code: String) {
        let host = session.state.host?.hostName ?? Host.current().localizedName ?? "my Mac"
        let text = """
        You're invited to Pennant on \(host).

        1. Install Pennant on your iPhone (TestFlight) and open it.
        2. Choose \(host) (on the same network, or by its Tailscale name).
        3. Tap “I have an invite code”, enter \(code), and choose a password. Your email is \(invite.email).

        The code works once and expires in a week.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func saveSignIn() {
        let settings = edited
        run(.updateSignInSettings(settings)) { loadedSettings = settings }
    }

    private func run(_ body: CommandBody, then: @escaping () -> Void = {}) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await session.peopleCommand(body); then() } catch { self.error = String(describing: error) }
        }
    }
}

/// First run on the host's Mac: set up the owner's account so phones and other Macs can sign in.
struct AccountSetupSheet: View {
    @Environment(\.hostSession) private var session
    var onDone: () -> Void

    private var owner: Person? { session.state.people?.people.first { $0.role == .owner } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PennantMark(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up your account").font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                    Text("Your phone and other Macs sign in with this email and password (or Microsoft, Google, GitHub once set up in Settings › People). This Mac is always signed in as you.")
                        .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            MyAccountForm(person: owner, asksCurrentPassword: false) { onDone() }
            HStack {
                Spacer()
                Button("Later", action: onDone).buttonStyle(.pennantCompact)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

