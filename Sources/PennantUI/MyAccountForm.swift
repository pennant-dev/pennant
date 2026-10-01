import PennantClientKit
import PennantCore
import SwiftUI

/// Your own account: name, email (what you sign in with), and a password. On the Mac itself it sets up the owner's
/// account, and no current password is asked for; elsewhere changing a password needs the current one.
public struct MyAccountForm: View {
    @Environment(\.hostSession) private var session
    /// The account as it is now; nil before the owner's account exists.
    var person: Person?
    /// Ask for the current password before setting a new one (not on the Mac itself).
    var asksCurrentPassword: Bool
    var onSaved: (() -> Void)?

    @State private var name = ""
    @State private var email = ""
    @State private var current = ""
    @State private var new = ""
    @State private var repeatNew = ""
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    public init(person: Person?, asksCurrentPassword: Bool, onSaved: (() -> Void)? = nil) {
        self.person = person
        self.asksCurrentPassword = asksCurrentPassword
        self.onSaved = onSaved
    }

    private static let minimum = 10

    private var detailsChanged: Bool {
        name.trimmingCharacters(in: .whitespaces) != (person?.name ?? "") || email.trimmingCharacters(in: .whitespaces).lowercased() != (person?.email ?? "").lowercased()
    }

    private var passwordProblem: String? {
        guard !new.isEmpty || !repeatNew.isEmpty else { return nil }
        if new.count < Self.minimum { return "Use at least \(Self.minimum) characters." }
        if new != repeatNew { return "The two passwords don't match." }
        if asksCurrentPassword, person?.hasPassword == true, current.isEmpty { return "Enter your current password." }
        return nil
    }

    private var canSave: Bool {
        !busy && email.contains("@") && passwordProblem == nil && (detailsChanged || !new.isEmpty)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PennantTextField("Name", placeholder: "Your name", text: $name)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Email")
                TextField("you@company.com", text: $email)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    #endif
                    .pennantField()
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(person?.hasPassword == true ? "Change password" : "Password")
                if asksCurrentPassword, person?.hasPassword == true {
                    secure("Current password", $current, content: .password)
                }
                secure(person?.hasPassword == true ? "New password" : "At least \(Self.minimum) characters", $new, content: .newPassword)
                secure("Repeat it", $repeatNew, content: .newPassword)
            }
            if let identities = person?.identities, !identities.isEmpty {
                Label("Also signs in with \(identities.map(\.provider.title).joined(separator: ", "))", systemImage: "checkmark.seal")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            }
            if let problem = passwordProblem {
                Text(problem).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger)
            }
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger)
            }
            HStack(spacing: 10) {
                if saved { Label("Saved", systemImage: "checkmark").font(.zoomed(.caption)).foregroundStyle(PennantTheme.success) }
                Spacer(minLength: 0)
                Button(busy ? "Saving…" : "Save account") { save() }
                    .buttonStyle(PennantButtonStyle(.primary, compact: true))
                    .disabled(!canSave)
            }
        }
        .onAppear { fill() }
        .onChange(of: person) { _, _ in if !busy { fill() } }
    }

    private func secure(_ placeholder: String, _ text: Binding<String>, content: SecureContent) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            #if os(iOS)
            .textContentType(content == .newPassword ? .newPassword : .password)
            #endif
            .pennantField()
    }

    private enum SecureContent { case password, newPassword }

    private func fill() {
        name = person?.name ?? ""
        email = person?.email ?? ""
    }

    private func save() {
        busy = true
        error = nil
        saved = false
        let (name, email, current, new) = (name, email, current, new)
        Task {
            defer { busy = false }
            do {
                if detailsChanged { try await session.updateMyAccount(name: name, email: email) }
                if !new.isEmpty { try await session.setMyPassword(current: current.isEmpty ? nil : current, new: new) }
                self.current = ""; self.new = ""; self.repeatNew = ""
                saved = true
                onSaved?()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
