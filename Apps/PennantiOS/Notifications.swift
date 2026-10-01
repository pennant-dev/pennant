import AuthenticationServices
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI
import UIKit
import UserNotifications

/// iPhone notifications: asks once, registers with Apple, hands the device token to the host (which sends a
/// notification when something needs this person), and opens the right conversation when one is tapped.
@MainActor @Observable
final class PushCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCenter()
    /// A conversation a tapped notification asked to open; RootTabs takes it and clears it.
    var pendingOpen: (agentID: AgentID, conversationID: ConversationID)?
    private(set) var token: String?
    private weak var session: HostSession?
    private var registeredToken: String?

    /// APNs environment of this build: debug builds use the sandbox, TestFlight and the App Store production.
    static var environment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    /// Called once the app is connected and signed in: ask (the first time), register with Apple, tell the host.
    func start(with session: HostSession) {
        self.session = session
        UNUserNotificationCenter.current().delegate = self
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
                settings = await center.notificationSettings()
            }
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            UIApplication.shared.registerForRemoteNotifications()
            await sendTokenIfNeeded()
        }
    }

    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await sendTokenIfNeeded() }
    }

    private func sendTokenIfNeeded() async {
        guard let token, let session, session.connection.isConnected, registeredToken != token else { return }
        let team = Bundle.main.object(forInfoDictionaryKey: "PennantTeamID") as? String
        do {
            try await session.registerPushDevice(token: token, environment: Self.environment, teamID: team?.isEmpty == false ? team : nil,
                                                 name: UIDevice.current.name, bundleID: Bundle.main.bundleIdentifier ?? "dev.pennant.ios")
            registeredToken = token
        } catch {}
    }

    /// Reconnected (or signed in as someone else): register again.
    func connectionChanged() {
        registeredToken = nil
        Task { await sendTokenIfNeeded() }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let agent = info["agentID"] as? String, let conversation = info["conversationID"] as? String else { return }
        await MainActor.run { self.pendingOpen = (AgentID(agent), ConversationID(conversation)) }
    }
}

final class PennantAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushCenter.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before launch finishes, so a tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = PushCenter.shared
        return true
    }
}

/// Through Cloudflare Access, when the work-account sign-in has run out: one tap signs in again and reconnects.
struct AccessExpiredBanner: View {
    @Environment(\.hostSession) private var session
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your sign-in to \(session.endpoint.host) ran out.").font(.callout.weight(.semibold))
            if let error { Text(error).font(.caption).foregroundStyle(PennantTheme.danger) }
            Button(busy ? "Signing in…" : "Sign in with Microsoft") { signIn() }
                .buttonStyle(.pennantPrimaryCompact).disabled(busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    private func signIn() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await AccessSignIn.run(host: session.endpoint.host, auth: webAuth)
                try? ClientCredentials.save(ClientCredentials(clientID: session.clientID, token: r.token, hostName: session.endpoint.host), for: session.endpoint)
                session.accessToken = r.token
                session.connect()
                error = nil
            } catch { self.error = "\(error)" }
        }
    }
}
