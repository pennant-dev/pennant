import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Settings › General › Ask me before…: the three things Pennant can stop for, each off until the owner turns it on.
struct AskFirstSettingsCard: View {
    @Environment(\.hostSession) private var session
    @State private var askFirst: HostConfig.AskFirst?
    @State private var error: String?

    var body: some View {
        SettingsCard("Ask me before…") {
            if let askFirst {
                SettingsNote("Off, Pennant just does it and tells you what it did. A card nobody answers goes away after a day.")
                row("Sending and posting", "Emails, messages and posts wait on a card for you. Goals set to Only propose put proposals to you in their thread either way.", \.publishes, askFirst)
                row("Spending money", "Buying, subscribing or paying waits on a card for you.", \.spends, askFirst)
                row("Deletes that can't be undone", "Branches, cloud resources, records, emails wait on a card for you. Files Pennant deletes on this Mac go to the Trash.", \.deletes, askFirst)
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { SettingsNote(error, tone: SettingsTone.danger) }
        }
        .task { askFirst = try? await session.getConfig().config.askFirst }
    }

    private func row(_ title: String, _ detail: String, _ key: WritableKeyPath<HostConfig.AskFirst, Bool>, _ current: HostConfig.AskFirst) -> some View {
        Toggle(isOn: Binding(get: { current[keyPath: key] }, set: { set(key, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.zoomed(.callout))
                Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    private func set(_ key: WritableKeyPath<HostConfig.AskFirst, Bool>, _ on: Bool) {
        let before = askFirst
        askFirst?[keyPath: key] = on
        error = nil
        Task {
            do {
                var c = try await session.getConfig().config
                guard c.askFirst[keyPath: key] != on else { return }
                c.askFirst[keyPath: key] = on
                _ = try await session.updateConfig(c)
            } catch {
                self.error = HostSessionError.message(error)
                askFirst = before
            }
        }
    }
}
