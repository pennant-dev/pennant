import PennantClientKit
import PennantCore
import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

/// Sign-ins and secrets that skills' scripts use so the user does not sign in by hand every time. Secrets are
/// write-only here: the list shows what is stored, never the values, and agents only ever see the names.
public struct VaultView: View {
    @Environment(\.hostSession) private var session
    @State private var items: [VaultItem] = []
    @State private var editing: VaultItem?
    @State private var creating = false
    @State private var importing = false
    @State private var signIns: [BrowserSignIn] = []
    @State private var confirmRemove: BrowserSignIn?
    @State private var removing: String?
    @State private var error: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(summary).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                Spacer()
                Button { importing = true } label: { Label("Sign-ins from Chrome", systemImage: "arrow.down.circle") }.buttonStyle(.pennantCompact)
                Button { creating = true } label: { Label("New entry", systemImage: "plus") }.buttonStyle(.pennantPrimaryCompact)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            if items.isEmpty && signIns.isEmpty {
                EmptyState(title: "Nothing in the vault", message: "Save a site's sign-in once and scripts sign in by themselves, authenticator code included. Agents see the entry's name, never the password.") {
                    Button("New entry") { creating = true }.buttonStyle(.pennantPrimary)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !items.isEmpty {
                            SectionLabel("Passwords and keys")
                            ForEach(items) { item in
                                Button { editing = item } label: { VaultRow(item: item) }.buttonStyle(.plain)
                            }
                        }
                        if !signIns.isEmpty {
                            HStack {
                                SectionLabel("Sign-ins copied from your browser")
                                Spacer()
                                Button("Copy more") { importing = true }.buttonStyle(.pennantGhostCompact)
                            }
                            .padding(.top, items.isEmpty ? 0 : 12)
                            ForEach(signIns) { signIn in
                                BrowserSignInRow(signIn: signIn, removing: removing == signIn.site) { confirmRemove = signIn }
                            }
                        }
                        if !items.isEmpty {
                            Label("Passwords and keys are stored in this Mac's Keychain. Only a script an agent runs with the entry's name receives the details, and they are blanked out of anything the agent reads back.", systemImage: "lock.shield")
                                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                                .padding(.top, 8)
                        }
                        if !signIns.isEmpty {
                            Label("Copied sign-ins live only in Pennant's own browser, which scripts use. Agents never see them. Remove one and Pennant is signed out of that site; your own browser is not affected.", systemImage: "globe.badge.chevron.backward")
                                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                                .padding(.top, items.isEmpty ? 8 : 0)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 760)
                }
            }
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .background(PennantTheme.panelBackground)
        .task {
            if let fresh = try? await session.listVault() { items = fresh }
            if let fresh = try? await session.browserSignIns() { signIns = fresh }
        }
        .sheet(isPresented: $creating) { VaultEditor(item: nil) { items = $0 } }
        .sheet(item: $editing) { item in VaultEditor(item: item) { items = $0 } }
        .sheet(isPresented: $importing, onDismiss: {
            Task { if let fresh = try? await session.browserSignIns() { signIns = fresh } }
        }) { ChromeSignInImporter() }
        .confirmationDialog("Remove the \(confirmRemove?.site ?? "") sign-in?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { signIn in
            Button("Remove from Pennant", role: .destructive) { remove(signIn) }
            Button("Cancel", role: .cancel) {}
        } message: { signIn in
            Text("Pennant's browser forgets its \(signIn.site) cookies, so scripts are signed out there. Your own \(signIn.browser) stays signed in.")
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !items.isEmpty { parts.append("\(items.count) saved") }
        if !signIns.isEmpty { parts.append("\(signIns.count) site\(signIns.count == 1 ? "" : "s") copied from your browser") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    private func remove(_ signIn: BrowserSignIn) {
        removing = signIn.site
        error = nil
        Task {
            defer { removing = nil }
            do { signIns = try await session.removeBrowserSignIn(site: signIn.site) } catch { self.error = HostSessionError.message(error) }
        }
    }
}

/// A site Pennant's browser holds a copied sign-in for: where it came from, when, and until when it should last.
struct BrowserSignInRow: View {
    var signIn: BrowserSignIn
    var removing: Bool
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe").font(.zoomed(.title3)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(signIn.site).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2)
            }
            Spacer()
            if expired { Chip("expired", color: PennantTheme.warning) } else { Chip("signed in", color: PennantTheme.success) }
            Button(removing ? "Removing…" : "Remove", role: .destructive, action: onRemove)
                .buttonStyle(.pennantGhostCompact)
                .disabled(removing)
        }
        .card(elevated: true)
    }

    private var expired: Bool { signIn.expiresAt.map { $0 < Date() } ?? false }

    private var detail: String {
        var parts = ["From \(signIn.browser) · \(signIn.profileName)\(signIn.account.map { " (\($0))" } ?? "")"]
        parts.append("copied \(signIn.importedAt.formatted(date: .abbreviated, time: .shortened))")
        if let until = signIn.expiresAt { parts.append((expired ? "ended " : "lasts until ") + until.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

/// Copies chosen sites' sign-ins from the user's Chrome into Pennant's browser, so scripts start signed in. Sites come
/// from the Chrome profile itself: search to pick, or tap one of the most-used.
struct ChromeSignInImporter: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [ChromeProfile] = []
    @State private var profile = "Default"
    @State private var sites: [ChromeSite] = []
    @State private var picked: [String] = []
    @State private var query = ""
    @State private var loadingSites = false
    @State private var busy = false
    @State private var result: ChromeImportResult?
    @State private var error: String?

    /// Sites Pennant's skills and connectors use, offered first when the profile has them.
    private static let preferred = ["linkedin.com", "reddit.com", "x.com", "facebook.com", "instagram.com", "github.com", "google.com", "microsoft.com", "hubspot.com", "canva.com"]

    init(previewProfiles: [ChromeProfile] = [], sites: [ChromeSite] = [], picked: [String] = []) {
        _profiles = State(initialValue: previewProfiles)
        _sites = State(initialValue: sites)
        _picked = State(initialValue: picked)
    }

    private var suggested: [ChromeSite] {
        let preferred = Self.preferred.compactMap { p in sites.first { $0.site == p } }
        let rest = sites.filter { s in !Self.preferred.contains(s.site) }.prefix(max(0, 10 - preferred.count))
        return (preferred + rest).filter { !picked.contains($0.site) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign-ins from Chrome").font(.zoomed(.title3).weight(.semibold))
            Text("Copies your sign-in for the sites you pick from Chrome into Pennant's own browser, so scripts start signed in as you. Only those sites' cookies are copied. macOS asks once to let Pennant read Chrome's cookie key; choose Always Allow.")
                .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            ChoiceMenu("Chrome profile", selection: $profile, options: profiles.map { ChoiceOption($0.id, title: $0.name, subtitle: $0.account) })
            VStack(alignment: .leading, spacing: 8) {
                AutocompleteField("Sites", placeholder: loadingSites ? "Reading this profile's sites…" : "Search \(sites.count) sites in this profile", text: $query) { (q: String) -> [ChoiceOption<String>] in
                    let needle = q.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !needle.isEmpty else { return [] }
                    return sites.filter { $0.site.contains(needle) && !picked.contains($0.site) }.prefix(8)
                        .map { ChoiceOption($0.site, title: $0.site, subtitle: "\($0.cookies) cookies", symbol: "globe") }
                } onPick: { (option: ChoiceOption<String>) in
                    picked.append(option.value)
                    query = ""
                }
                if !picked.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(picked, id: \.self) { site in
                            ChipButton(title: site, symbol: "xmark", selected: true) { picked.removeAll { $0 == site } }
                        }
                    }
                }
                if !suggested.isEmpty {
                    Text("Most used in this profile").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(suggested) { s in
                            ChipButton(title: s.site, symbol: "plus", selected: false) { picked.append(s.site) }
                        }
                    }
                }
            }
            if let result {
                Label("Copied \(result.cookies) cookie(s): " + result.perSite.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.success)
            }
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(.pennantSecondary)
                Button(busy ? "Copying…" : picked.count > 1 ? "Copy \(picked.count) sign-ins" : "Copy sign-in") { run() }
                    .buttonStyle(.pennantPrimary)
                    .disabled(busy || picked.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 500)
        .task {
            do { profiles = try await session.chromeProfiles() } catch { self.error = HostSessionError.message(error) }
            if !profiles.contains(where: { $0.id == profile }), let first = profiles.first { profile = first.id }
            if profiles.isEmpty, error == nil { error = "No Chrome profiles found. If Chrome is installed, give Pennant Host Full Disk Access in System Settings → Privacy & Security." }
        }
        // Re-run once the profiles arrive as well as when the choice changes.
        .task(id: "\(profile)|\(profiles.count)") { await loadSites() }
    }

    private func loadSites() async {
        guard profiles.contains(where: { $0.id == profile }) else { return }
        loadingSites = true
        defer { loadingSites = false }
        do {
            sites = try await session.chromeSites(profile: profile)
            picked.removeAll { p in !sites.contains { $0.site == p } }
        } catch {
            self.error = HostSessionError.message(error)
        }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { result = try await session.importChromeSignIns(profile: profile, sites: picked) } catch { self.error = HostSessionError.message(error) }
        }
    }
}

struct VaultRow: View {
    var item: VaultItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .login ? "person.badge.key" : "key")
                .font(.zoomed(.title3)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.zoomed(.callout).weight(.semibold).monospaced()).foregroundStyle(PennantTheme.ink)
                Text([item.url, item.username].compactMap { $0?.nilIfEmpty }.joined(separator: " · ").nilIfEmpty ?? item.notes)
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
            }
            Spacer()
            if item.hasPassword { Chip("password") }
            if item.hasTOTP { Chip("2FA code", color: PennantTheme.success) }
            if item.hasSecret { Chip("secret") }
        }
        .card(elevated: true)
        .contentShape(Rectangle())
    }
}

struct VaultEditor: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    var original: VaultItem?
    var onChange: ([VaultItem]) -> Void
    @State private var item: VaultItem
    @State private var password = ""
    @State private var totp = ""
    @State private var secret = ""
    @State private var importingFor: String?
    /// The file a secret was just loaded from, for the confirmation line.
    @State private var loadedFile: String?
    @State private var clear: Set<String> = []
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var busy = false

    init(item: VaultItem?, onChange: @escaping ([VaultItem]) -> Void) {
        original = item
        self.onChange = onChange
        _item = State(initialValue: item ?? VaultItem(name: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New vault entry" : "Edit \(item.name)").font(.zoomed(.title3).weight(.semibold))
            ChipRow(selection: $item.kind, options: [ChoiceOption(.login, title: "Website sign-in", symbol: "person.badge.key"), ChoiceOption(.secret, title: "API key or token", symbol: "key")])
            PennantTextField("Name agents use", placeholder: item.kind == .login ? "linkedin" : "openai-api", text: $item.name)
            if item.kind == .login {
                PennantTextField("Site", placeholder: "https://www.linkedin.com", text: Binding(get: { item.url ?? "" }, set: { item.url = $0.nilIfEmpty }))
                PennantTextField("Email or username", placeholder: "you@example.com", text: Binding(get: { item.username ?? "" }, set: { item.username = $0.nilIfEmpty }))
                secretField("Password", stored: item.hasPassword, key: "password", text: $password)
                secretField("Authenticator secret (optional)", stored: item.hasTOTP, key: "totp", text: $totp,
                            hint: "The setup key shown under the QR code when you turn on two-step sign-in (\"can't scan it?\"). Scripts then type the current 6-digit code themselves.")
            } else {
                secretField("Secret", stored: item.hasSecret, key: "secret", text: $secret)
            }
            PennantTextField("Notes", placeholder: "Company page admin account", text: $item.notes)
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
            HStack {
                if original != nil { Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.pennantGhost) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantSecondary)
                Button("Save") { save() }.buttonStyle(.pennantPrimary).disabled(busy || item.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .fileImporter(isPresented: Binding(get: { importingFor != nil }, set: { if !$0 { importingFor = nil } }), allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { loadSecret(from: url) }
            importingFor = nil
        }
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    if let items = try? await session.deleteVaultItem(id: item.id) { onChange(items) }
                    dismiss()
                }
            }
        } message: { Text("Scripts that use it will ask you to sign in by hand again.") }
    }

    @ViewBuilder private func secretField(_ label: String, stored: Bool, key: String, text: Binding<String>, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldLabel(label)
                Spacer()
                if stored && !clear.contains(key) {
                    Chip("saved", color: PennantTheme.success)
                    Button("Remove") { clear.insert(key); text.wrappedValue = "" }.buttonStyle(.pennantGhostCompact)
                }
            }
            HStack(spacing: 8) {
                SecureField(stored && !clear.contains(key) ? "Leave empty to keep the saved one" : (text.wrappedValue.contains("\n") ? "Loaded from a file" : ""), text: text)
                    .textFieldStyle(.plain)
                    .pennantField()
                if key == "secret" {
                    // Keys that span lines (a PEM private key) keep their line breaks when read from the file.
                    Button("From file…") { chooseSecretFile(key) }
                        .buttonStyle(.pennantGhostCompact)
                        .fixedSize()
                        .help("Load the secret from a file, such as a .pem private key")
                }
            }
            if key == "secret", let loaded = loadedFile {
                Label("Loaded \(loaded) (\(text.wrappedValue.split(separator: "\n").count) lines). Press Save to store it.", systemImage: "checkmark.circle.fill")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.success)
            }
            if let hint { Text(hint).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary) }
        }
    }

    /// Reads a secret from a file the user picks (a .pem key keeps its line breaks). The Mac uses the Open panel
    /// directly: SwiftUI's file importer inside this sheet can fail without a word.
    private func chooseSecretFile(_ key: String) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the file that holds the secret (for example a .pem private key)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSecret(from: url)
        #else
        importingFor = key
        #endif
    }

    private func loadSecret(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 64_000, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "\(url.lastPathComponent) isn't a text secret (a .pem key or a token file)."
            return
        }
        secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clear.remove("secret")
        loadedFile = url.lastPathComponent
        error = nil
    }

    private func value(_ key: String, _ text: String) -> String? {
        if !text.isEmpty { return text }
        return clear.contains(key) ? "" : nil
    }

    private func save() {
        busy = true
        error = nil
        let secretParts = VaultSecret(password: value("password", password), totp: value("totp", totp), secret: value("secret", secret))
        let changed = secretParts.password != nil || secretParts.totp != nil || secretParts.secret != nil
        Task {
            defer { busy = false }
            do {
                onChange(try await session.saveVaultItem(item, secret: changed ? secretParts : nil))
                dismiss()
            } catch {
                self.error = HostSessionError.message(error)
            }
        }
    }
}
