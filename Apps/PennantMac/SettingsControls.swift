import AppKit
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

// Layout shells for the Settings tabs: a light panel that scrolls, white cards with a caption, label/value rows.
// Chrome uses theme tokens only; status colours come from the theme's task-state palette because the foundation
// has no standalone success/warning/danger tokens.

enum SettingsTone {
    static let success = PennantTheme.color(for: TaskState.completed)
    static let warning = PennantTheme.color(for: TaskState.paused)
    static let danger = PennantTheme.color(for: TaskState.failed)
    static let working = PennantTheme.color(for: TaskState.running)

    static func color(for state: ConnectionState) -> Color {
        switch state {
        case .connected: return success
        case .connecting, .reconnecting: return working
        case .failed: return danger
        case .disconnected: return PennantTheme.inkTertiary
        }
    }

    static func isBusy(_ state: ConnectionState) -> Bool {
        switch state {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }
}

/// A scrolling panel with a stack of cards.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
        }
        .scrollClipDisabled()
        .background(PennantTheme.panelBackground)
    }
}

/// A white card with a section caption above it.
struct SettingsCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .card(elevated: true)
        }
    }
}

/// Label on the left, value (or any view) on the right.
struct SettingsRow<Value: View>: View {
    var label: String
    var value: Value
    init(_ label: String, @ViewBuilder value: () -> Value) { self.label = label; self.value = value() }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 110, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension SettingsRow where Value == Text {
    init(_ label: String, value: String, monospaced: Bool = false) {
        self.init(label) {
            Text(value).font(monospaced ? .zoomed(.callout).monospaced() : .zoomed(.callout)).foregroundStyle(PennantTheme.ink)
        }
    }
}

/// Caption under a control or at the bottom of a card.
struct SettingsNote: View {
    var text: String
    var tone: Color = PennantTheme.inkSecondary
    init(_ text: String, tone: Color = PennantTheme.inkSecondary) { self.text = text; self.tone = tone }
    var body: some View {
        Text(text).font(.zoomed(.caption)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
    }
}

/// A secure field in Pennant's field chrome.
struct SettingsSecureField: View {
    var label: String
    var placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .pennantField(focused: focused)
        }
    }
}

/// Titles for token counts in menus: "8k", "128k", "1M", "4k".
func settingsTokenTitle(_ n: Int) -> String {
    if n >= 1_000_000, n % 1_000_000 == 0 { return "\(n / 1_000_000)M tokens" }
    if n >= 1024, n % 1024 == 0, n < 1_000_000 { return "\(n / 1024)k tokens" }
    if n >= 1000, n % 1000 == 0 { return "\(n / 1000)k tokens" }
    return "\(formatTokens(n)) tokens"
}

// MARK: - ChatGPT account block

/// Signed out: what signing in does and the two ways to do it (the browser, or the Codex CLI's login). Mid
/// sign-in: the browser wait. Signed in: who, on what plan, from where, and Sign out. The account changes on the
/// host, so the block asks for it until it says signed in.
struct ChatGPTAccountBlock: View {
    @Environment(\.hostSession) private var session
    @Binding var account: ChatGPTAccount?
    @State private var busy = false
    @State private var error: String?
    /// Set from the moment the host starts a sign-in until it reports the account or the wait ends.
    @State private var waiting = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Account")
            if let account, account.signedIn {
                signedIn(account)
            } else {
                SettingsNote("Uses your ChatGPT subscription through the same backend as the Codex CLI. Sign in opens your browser; the sign-in page returns to this Mac on port 1455.")
                if waiting {
                    browserWait
                } else {
                    HStack(spacing: 8) {
                        Button("Sign in with ChatGPT") { beginSignIn() }.buttonStyle(.pennantPrimaryCompact)
                        Button("Use Codex CLI login") { importLogin() }.buttonStyle(.pennantCompact)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .disabled(busy)
                }
                if let detail = account?.detail, !detail.isEmpty { SettingsNote(detail) }
            }
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
        .task { if account == nil { account = try? await session.chatGPTAccount() } }
        .onDisappear { cancel() }
    }

    // MARK: States

    private func signedIn(_ account: ChatGPTAccount) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.zoomed(.title2))
                .foregroundStyle(SettingsTone.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Signed in as \(account.email ?? "your ChatGPT account")").font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).textSelection(.enabled)
                HStack(spacing: 6) {
                    if let plan = account.plan, !plan.isEmpty { Chip("ChatGPT \(plan.capitalized)", color: PennantTheme.info) }
                    Chip(account.source == "codex-cli" ? "Codex CLI login" : "Signed in from Pennant")
                }
                SettingsNote(Self.expiryNote(account.expiresAt))
            }
            Spacer(minLength: 0)
            Button("Sign out") { signOut() }.buttonStyle(.pennantGhostCompact).disabled(busy)
        }
    }

    private var browserWait: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for you in the browser…").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            Button("Cancel") { cancel() }.buttonStyle(.pennantGhostCompact)
        }
    }

    private static func expiryNote(_ expiresAt: Date?) -> String {
        guard let expiresAt else { return "Session refreshes automatically." }
        return "Session refreshes automatically · current token until \(expiresAt.formatted(date: .omitted, time: .shortened))."
    }

    /// The host's own words for the errors it raises; the session's description otherwise.
    private static func message(for error: Error) -> String {
        if case HostSessionError.hostError(_, let message) = error { return message }
        return String(describing: error)
    }

    // MARK: Host calls

    private func beginSignIn() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let url = try await session.beginChatGPTSignIn()
                NSWorkspace.shared.open(url)
                waiting = true
                waitForAccount()
            } catch { self.error = Self.message(for: error) }
        }
    }

    /// The sign-in finishes on the host; ask for the account every two seconds until it says signed in or five
    /// minutes pass.
    private func waitForAccount() {
        pollTask?.cancel()
        pollTask = Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            var signedIn = false
            while !Task.isCancelled, !signedIn, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                if let a = try? await session.chatGPTAccount() {
                    account = a
                    signedIn = a.signedIn
                }
            }
            guard !Task.isCancelled else { return }
            waiting = false
            if !signedIn { error = "The browser sign-in did not finish within five minutes. Try again." }
        }
    }

    private func cancel() {
        pollTask?.cancel()
        pollTask = nil
        waiting = false
    }

    private func importLogin() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { account = try await session.importCodexLogin() } catch { self.error = Self.message(for: error) }
        }
    }

    private func signOut() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { account = try await session.signOutChatGPT() } catch { self.error = Self.message(for: error) }
        }
    }
}
