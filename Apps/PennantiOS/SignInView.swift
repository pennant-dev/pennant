import AuthenticationServices
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI
import UIKit

/// First run: pick a host found on the network, scan the code the Mac shows (Settings › iPhone), or type its
/// Tailscale name, then sign in with an email and password or with Microsoft, Google or GitHub. Someone invited joins
/// with the owner's one-time code and chooses a password. Cloudflare and pasting a token live under Advanced.
struct SignInView: View {
    /// A connect code opened from the Camera app (pennant://connect?…), to fill in the host.
    var connectCode: HostEndpoint? = nil
    var onPaired: (HostEndpoint, String, String) -> Void
    @State private var discovery = HostDiscovery()
    @State private var host = PhoneSettings.endpoint.host
    @State private var port = String(PhoneSettings.endpoint.port)
    @State private var hostName = ""
    @State private var manualToken = ""
    /// The encrypted port and certificate fingerprint the chosen host advertised on Bonjour.
    @State private var advertisedTLS: (port: Int?, fingerprint: String?) = (nil, nil)
    /// The Mac's other addresses, from its connect code: kept with the host so it's found anywhere.
    @State private var codeAlternates: [String]?
    @State private var scanning = false
    @State private var email = ""
    @State private var password = ""
    @State private var showInvite = false
    @State private var inviteCode = ""
    @State private var inviteName = ""
    @State private var invitePassword = ""
    @State private var inviteRepeat = ""
    /// The host takes email-and-password sign-in and invite codes.
    @State private var busy = false
    @State private var error: String?
    @State private var showAdvanced = false
    /// The sign-in providers the chosen host offers; nil while asking.
    @State private var providers: [SignInProvider]?
    @State private var signingIn: SignInProvider?
    /// GitHub's device code, shown while the host waits for it to be entered.
    @State private var deviceCode: (code: String, url: URL)?
    /// Why the chosen host couldn't be asked for its sign-in options (unreachable, off the tailnet…).
    @State private var reachError: String?
    @State private var retry = 0
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var accessHost = AccessSignIn.suggestedHost
    @State private var accessBusy = false
    @Environment(\.openURL) private var openURL

    /// A host has been chosen (or typed under Advanced), so the code step can show.
    private var hasHost: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                hostsSection
                codeSection
                addressSection
                if hasHost, let reachError {
                    unreachable(reachError)
                } else if hasHost, providers == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Contacting \(plainHost(host))…").font(.callout).foregroundStyle(PennantTheme.inkSecondary)
                    }
                    .card(elevated: true)
                } else if hasHost, let providers {
                    signInSection(providers).transition(.opacity.combined(with: .move(edge: .top)))
                    inviteSection
                }
                advancedSection
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color(hex: "#E5484D"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .animation(.snappy, value: hasHost)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PennantTheme.panelBackground)
        .onAppear {
            discovery.start()
            if let connectCode { use(connectCode) }
        }
        .onChange(of: connectCode) { _, code in if let code { use(code) } }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $scanning) {
            CodeScannerSheet { code in
                scanning = false
                use(code)
            }
        }
        .task(id: "\(host)|\(port)|\(retry)") { await loadProviders() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            PennantMark(size: 56)
                .accessibilityLabel("Pennant")
            Text("Connect to your Mac")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PennantTheme.ink)
            Text("The host runs on a Mac. Pick it below, scan the code it shows, or type its Tailscale name, then sign in. Invited? Use the code the owner sent you.")
                .font(.callout)
                .foregroundStyle(PennantTheme.inkSecondary)
        }
    }

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("Hosts on this network")
                if discovery.isBrowsing { ProgressView().controlSize(.mini) }
            }
            if discovery.hosts.isEmpty {
                HStack(spacing: 12) {
                    if discovery.isBrowsing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(PennantTheme.inkTertiary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(discovery.isBrowsing ? "Looking for hosts on this network…" : "No hosts found yet.")
                            .font(.callout)
                            .foregroundStyle(PennantTheme.ink)
                        Text("Open Pennant on your Mac and keep both devices on the same network.")
                            .font(.caption)
                            .foregroundStyle(PennantTheme.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .card(elevated: true)
            }
            ForEach(discovery.hosts) { found in
                HostCard(host: found, selected: isSelected(found)) { select(found) }
            }
            // Browsing fails off Wi-Fi (on cellular it's expected); only say so when there's nothing to show.
            if let e = discovery.lastError, discovery.hosts.isEmpty, !e.contains("DefunctConnection") {
                Text(e).font(.caption).foregroundStyle(Color(hex: "#F0762B"))
            }
        }
    }

    /// Joining with the owner's one-time code: choose a name and password for the invited email.
    private var inviteSection: some View {
        DisclosureGroup(isExpanded: $showInvite) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Invite code", text: $inviteCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.weight(.semibold).monospaced())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .pennantField()
                TextField("Your name", text: $inviteName)
                    .textContentType(.name)
                    .textFieldStyle(.plain)
                    .pennantField()
                SecureField("Choose a password (at least 10 characters)", text: $invitePassword)
                    .textContentType(.newPassword)
                    .textFieldStyle(.plain)
                    .pennantField()
                SecureField("Repeat it", text: $inviteRepeat)
                    .textContentType(.newPassword)
                    .textFieldStyle(.plain)
                    .pennantField()
                if !inviteRepeat.isEmpty, invitePassword != inviteRepeat {
                    Text("The two passwords don't match.").font(.caption).foregroundStyle(Color(hex: "#E5484D"))
                }
                Button { redeemInvite() } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(PennantTheme.primaryButtonText) }
                        Text("Join")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pennantPrimary)
                .disabled(busy || PersonInvite.normalize(inviteCode).count != 8 || inviteName.trimmingCharacters(in: .whitespaces).isEmpty
                          || invitePassword.count < 10 || invitePassword != inviteRepeat)
            }
            .padding(.top, 10)
        } label: {
            Text("I have an invite code").font(.body.weight(.medium)).foregroundStyle(PennantTheme.ink)
        }
        .tint(PennantTheme.inkSecondary)
        .card(elevated: true)
    }

    /// Away from the Mac's network: its connect code has the Tailscale name, the other addresses and the certificate.
    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Not on the same network?")
            Button { scanning = true } label: {
                Label("Scan the Mac's code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.pennantSecondary)
            Text("On the Mac: Pennant › Settings › iPhone. The phone needs Tailscale on, signed in to the same tailnet.")
                .font(.caption).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    /// A host that isn't on this network: its Tailscale name (or any address).
    /// A Mac published through a Cloudflare Tunnel behind Access: the work account opens it and signs in.
    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("From anywhere, through Cloudflare")
            TextField("pennant.example.com", text: $accessHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.plain)
                .pennantField()
            Button { signInThroughAccess() } label: {
                Label(accessBusy ? "Signing in…" : "Sign in with Microsoft", systemImage: "building.2.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pennantPrimary)
            .disabled(accessBusy || accessHost.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Your work account opens the host, and it's your Pennant sign-in too.")
                .font(.caption).foregroundStyle(PennantTheme.inkTertiary)
        }
        .card(elevated: true)
    }

    private func signInThroughAccess() {
        accessBusy = true
        error = nil
        let host = accessHost.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Task {
            defer { accessBusy = false }
            do {
                let result = try await AccessSignIn.run(host: host, auth: webAuth)
                onPaired(HostEndpoint.access(host), result.token, host)
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Or connect by name")
            HStack(spacing: 8) {
                TextField("studio.tail1234.ts.net", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.plain)
                    .pennantField()
                TextField("7331", text: $port)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.plain)
                    .frame(width: 70)
                    .pennantField()
            }
            Text("Away from the Mac's network? Join its tailnet and use the Mac's Tailscale name.")
                .font(.caption).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    private func signInSection(_ providers: [SignInProvider]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Sign in to \(hostName.isEmpty ? plainHost(host) : hostName)")
            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .pennantField()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.plain)
                    .pennantField()
                    .onSubmit { if email.contains("@"), !password.isEmpty { signInWithPassword() } }
                Button { signInWithPassword() } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(PennantTheme.primaryButtonText) }
                        Text("Sign in")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pennantPrimary)
                .disabled(busy || !email.contains("@") || password.isEmpty)
                if !providers.isEmpty {
                    HStack(spacing: 8) {
                        Rectangle().fill(PennantTheme.border).frame(height: 1)
                        Text("or").font(.caption).foregroundStyle(PennantTheme.inkTertiary)
                        Rectangle().fill(PennantTheme.border).frame(height: 1)
                    }
                    .padding(.vertical, 2)
                }
                ForEach(providers) { p in
                    Button { signIn(p) } label: {
                        HStack(spacing: 10) {
                            if signingIn == p { ProgressView() } else { Image(systemName: Self.symbol(p)) }
                            Text("Continue with \(p.title)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pennantSecondary)
                    .disabled(signingIn != nil)
                }
                if let deviceCode {
                    VStack(spacing: 8) {
                        Text("Enter this code on GitHub").font(.callout).foregroundStyle(PennantTheme.inkSecondary)
                        Text(deviceCode.code).font(.title.weight(.semibold).monospaced()).textSelection(.enabled)
                        HStack(spacing: 10) {
                            Button("Copy code") { UIPasteboard.general.string = deviceCode.code }.buttonStyle(.pennantSecondary)
                            Button("Open GitHub") { openURL(deviceCode.url) }.buttonStyle(.pennantPrimary)
                        }
                        Text("Waiting for you to finish on GitHub…").font(.caption).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                }
            }
            .card(elevated: true)
        }
    }

    private static func symbol(_ p: SignInProvider) -> String {
        switch p { case .microsoft: return "building.2"; case .google: return "g.circle"; case .github: return "chevron.left.forwardslash.chevron.right" }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Token")
                    SecureField("Paste a token instead of signing in", text: $manualToken)
                        .textFieldStyle(.plain)
                        .pennantField()
                }
                Button("Connect with token") { useToken() }
                    .buttonStyle(.pennantSecondary)
                    .disabled(host.isEmpty || manualToken.isEmpty)
                accessSection
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(PennantTheme.inkSecondary)
                Text("Advanced").font(.body.weight(.medium)).foregroundStyle(PennantTheme.ink)
                Spacer(minLength: 0)
                Text("Token, Cloudflare").font(.caption).foregroundStyle(PennantTheme.inkTertiary)
            }
        }
        .tint(PennantTheme.inkSecondary)
        .card(elevated: true)
    }

    // MARK: Selection

    private func isSelected(_ found: DiscoveredHost) -> Bool {
        guard let e = found.endpoint else { return false }
        return plainHost(e.host) == plainHost(host) && String(e.port) == port
    }

    private func select(_ found: DiscoveredHost) {
        guard let e = found.endpoint else { return }
        host = e.host
        port = String(e.port)
        hostName = found.serviceName
        advertisedTLS = (e.tlsPort, e.fingerprint)
        codeAlternates = nil
        error = nil
    }

    /// Fills in the host from its connect code.
    private func use(_ code: HostEndpoint) {
        host = code.host
        port = String(code.port)
        hostName = code.name == code.host ? "" : code.name
        advertisedTLS = (code.tlsPort, code.fingerprint)
        codeAlternates = code.alternates
        error = nil
        retry += 1
    }

    // MARK: Signing in

    private var endpoint: HostEndpoint {
        var e = HostEndpoint(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 7331, name: hostName.isEmpty ? host : hostName,
                             tlsPort: advertisedTLS.port, fingerprint: advertisedTLS.fingerprint)
        e.alternates = codeAlternates
        return e
    }

    private func signInWithPassword() {
        busy = true
        error = nil
        let endpoint = endpoint
        let (email, password) = (email.trimmingCharacters(in: .whitespaces), password)
        Task {
            defer { busy = false }
            do {
                guard case .signedIn(let s) = try await SignInClient.request(endpoint, .signInWithPassword(email: email, password: password, clientID: ClientCredentials.deviceClientID(),
                                                                                                           clientName: UIDevice.current.name, platform: "iOS"), timeout: 30) else { return }
                onPaired(endpoint, s.token, s.hostName)
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private func redeemInvite() {
        busy = true
        error = nil
        let endpoint = endpoint
        let (code, name, password) = (inviteCode, inviteName, invitePassword)
        Task {
            defer { busy = false }
            do {
                guard case .signedIn(let s) = try await SignInClient.request(endpoint, .redeemInvite(code: code, name: name, password: password, clientID: ClientCredentials.deviceClientID(),
                                                                                                     clientName: UIDevice.current.name, platform: "iOS"), timeout: 30) else { return }
                onPaired(endpoint, s.token, s.hostName)
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private func loadProviders() async {
        providers = nil
        reachError = nil
        guard hasHost else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let options = try await SignInClient.signInOptions(endpoint)
            providers = options.providers
            if hostName.isEmpty, !options.hostName.isEmpty { hostName = options.hostName }
        } catch {
            guard !Task.isCancelled else { return }
            reachError = "\(error)"
        }
    }

    /// The host didn't answer: say so, with the usual reason for a Tailscale name, instead of falling back silently.
    private func unreachable(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Can't reach \(plainHost(host))", systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.semibold)).foregroundStyle(PennantTheme.ink)
            Text(host.contains(".ts.net") || host.hasPrefix("100.")
                 ? "Make sure Tailscale is connected on this phone (open the Tailscale app and switch it on), and that Pennant is running on the Mac."
                 : "Make sure the Mac is on and Pennant is running, and that this phone can reach it (same network, or Tailscale).")
                .font(.callout).foregroundStyle(PennantTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption.monospaced()).foregroundStyle(PennantTheme.inkTertiary).lineLimit(2)
            HStack {
                Button("Try again") { retry += 1 }.buttonStyle(.pennantPrimary)
            }
        }
        .card(elevated: true)
    }

    /// Signs in through the host: it hands back a browser page (Microsoft, Google) or a GitHub device code, and
    /// finishes the exchange itself, so this app only ever holds the host's session.
    private func signIn(_ provider: SignInProvider) {
        signingIn = provider
        error = nil
        let endpoint = endpoint
        Task {
            defer { signingIn = nil; deviceCode = nil }
            do {
                guard case .signInStarted(let start) = try await SignInClient.request(endpoint, .beginSignIn(provider: provider, redirectURI: "pennant://auth")) else { return }
                let clientID = ClientCredentials.deviceClientID()
                let reply: ReplyBody
                switch start.step {
                case .browser(let url, let scheme):
                    let callback = try await webAuth.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .shared)
                    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
                    if let message = item("error_description") ?? item("error") { throw SignInClient.Failure.rejected(code: "provider", message: message) }
                    guard item("state") == start.state, let code = item("code") else { throw SignInClient.Failure.rejected(code: "state", message: "The sign-in came back incomplete. Try again.") }
                    reply = try await SignInClient.request(endpoint, .completeSignIn(state: start.state, code: code, clientID: clientID, clientName: UIDevice.current.name, platform: "iOS"), timeout: 60)
                case .deviceCode(let userCode, let url, let expiresAt):
                    deviceCode = (userCode, url)
                    UIPasteboard.general.string = userCode
                    openURL(url)
                    reply = try await SignInClient.request(endpoint, .completeSignIn(state: start.state, code: nil, clientID: clientID, clientName: UIDevice.current.name, platform: "iOS"),
                                                            timeout: max(60, expiresAt.timeIntervalSinceNow + 30))
                }
                guard case .signedIn(let signedIn) = reply else { return }
                onPaired(endpoint, signedIn.token, signedIn.hostName)
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
                // Closed the sheet: nothing to say.
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private func useToken() {
        onPaired(endpoint, manualToken.trimmingCharacters(in: .whitespacesAndNewlines), hostName)
    }
}

/// Bonjour can resolve to a scoped address such as "192.168.1.53%en0"; the scope is not part of a hostname.
private func plainHost(_ raw: String) -> String {
    raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
}

/// A discovered host as a selectable card: name, resolved address (or a resolving spinner), and a check when chosen.
private struct HostCard: View {
    var host: DiscoveredHost
    var selected: Bool
    var action: () -> Void

    private var resolved: Bool { host.endpoint != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(selected ? PennantTheme.ink : PennantTheme.inkSecondary)
                    .frame(width: 36, height: 36)
                    .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.serviceName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PennantTheme.ink)
                        .lineLimit(1)
                    if let e = host.endpoint {
                        Text(verbatim: "\(plainHost(e.host)):\(e.port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(PennantTheme.inkSecondary)
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            if host.isResolving { ProgressView().controlSize(.mini) }
                            Text(host.isResolving ? "Resolving…" : "Not resolved")
                                .font(.caption)
                                .foregroundStyle(PennantTheme.inkTertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? PennantTheme.ink : PennantTheme.border)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous)
                    .stroke(selected ? PennantTheme.ink : PennantTheme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!resolved)
        .opacity(resolved ? 1 : 0.7)
        .accessibilityLabel(host.serviceName)
        .accessibilityValue(host.endpoint.map { "\($0.host):\($0.port)" } ?? (host.isResolving ? "Resolving" : "Not resolved"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Talks to the host before a session exists: opens a socket, sends one command, reads its reply.
enum SignInClient {
    enum Failure: Error, CustomStringConvertible {
        case rejected(code: String, message: String), closed, timeout
        var description: String {
            switch self { case .rejected(_, let m): return m; case .closed: return "The connection closed."; case .timeout: return "The Mac didn't answer in time." }
        }
    }

    /// One command, one reply. Sign-in commands may wait on a person (GitHub's code), so they get a long timeout.
    static func request(_ endpoint: HostEndpoint, _ body: CommandBody, timeout: TimeInterval = 15) async throws -> ReplyBody {
        let transport = WebSocketTransport()
        let inbound = try await transport.open(endpoint: endpoint)
        defer { Task { await transport.close() } }
        let command = ClientCommand(body: body)
        try await transport.send(.command(command))
        return try await withThrowingTaskGroup(of: ReplyBody.self) { group in
            group.addTask {
                for await item in inbound {
                    switch item {
                    case .message(.reply(let reply)) where reply.commandID == command.id:
                        if case .error(let code, let message) = reply.result { throw Failure.rejected(code: code, message: message) }
                        return reply.result
                    case .closed: throw Failure.closed
                    default: continue
                    }
                }
                throw Failure.closed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Failure.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func signInOptions(_ endpoint: HostEndpoint) async throws -> (providers: [SignInProvider], hostName: String) {
        guard case .signInOptions(let providers, let hostName) = try await request(endpoint, .signInOptions, timeout: 8) else { return ([], "") }
        return (providers, hostName)
    }
}
