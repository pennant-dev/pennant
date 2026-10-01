import AppKit
import Observation
import PennantUI
import Sparkle
import SwiftUI

/// Updates through Sparkle. The feed is a static file on pennant.dev (`SUFeedURL`), and an update is installed only
/// when it is signed with the key in Info.plist (`SUPublicEDKey`) and carries Apple's code signature. Sparkle asks on
/// the second launch whether to check automatically; Settings › General has the switches and a Check Now button.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    /// Nil in debug builds: there is nothing to update them to.
    private let controller: SPUStandardUpdaterController?

    private init() {
        #if DEBUG
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    var isAvailable: Bool { controller != nil }

    func checkNow() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var automaticChecks: Bool {
        get { access(keyPath: \.automaticChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { withMutation(keyPath: \.automaticChecks) { controller?.updater.automaticallyChecksForUpdates = newValue } }
    }

    var automaticDownloads: Bool {
        get { access(keyPath: \.automaticDownloads); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { withMutation(keyPath: \.automaticDownloads) { controller?.updater.automaticallyDownloadsUpdates = newValue } }
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        return "Pennant \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Settings › General › Updates.
struct UpdatesSettingsCard: View {
    @State private var updates = Updates.shared

    var body: some View {
        SettingsCard("Updates") {
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: $updates.automaticChecks).toggleStyle(.switch).controlSize(.small)
                Toggle("Download and install them automatically", isOn: $updates.automaticDownloads).toggleStyle(.switch).controlSize(.small)
                    .disabled(!updates.automaticChecks)
                HStack(spacing: 10) {
                    Button("Check Now") { updates.checkNow() }.buttonStyle(.pennantPrimaryCompact)
                    Text(Updates.versionLine).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                }
                SettingsNote("Pennant checks pennant.dev at most once a day and sends nothing about your Mac. An update installs only if it is signed by the Pennant project.")
            } else {
                SettingsNote("\(Updates.versionLine). This is a development build, so it doesn't update itself; build it again from source.")
            }
        }
    }
}
