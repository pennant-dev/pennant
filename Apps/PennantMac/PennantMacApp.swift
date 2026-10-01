import AppKit
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

@main
struct PennantMacApp: App {
    @State private var session: HostSession
    @State private var launcher = HostLauncher()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Settings and the data folder from before Pennant had its name come over before anything reads settings
        // or creates folders (the host does the same with the folder when it starts first).
        LegacyDefaults.migrate(domains: LegacyDefaults.macDomains)
        DataFolder.migrateLegacy()
        var endpoint = AppSettings.endpoint
        var token = AppSettings.token(for: endpoint) ?? ClientCredentials.readLocalHostToken()
        #if DEBUG
        if let demo = DemoLaunch.host { endpoint = demo.endpoint; token = demo.token }
        #endif
        let s = HostSession(
            transport: WebSocketTransport(),
            endpoint: endpoint,
            token: token,
            clientID: AppSettings.clientID,
            displayName: Host.current().localizedName ?? "Mac",
            platform: "macOS"
        )
        #if DEBUG
        // Another host's read marks stay out of this Mac's settings.
        if DemoLaunch.host == nil { s.state.persistReadMarks(in: .standard) }
        #else
        s.state.persistReadMarks(in: .standard)
        #endif
        _session = State(initialValue: s)
    }

    var body: some Scene {
        // One main window: File › New Thread starts a thread in it. A window group gave File › New Window (⌘N), which
        // opened a second, empty Pennant whose messages turned up as threads in the first.
        Window("Pennant", id: "main") {
            MainWindow()
                .hostSession(session)
                .environment(launcher)
                // No minimum width of our own: the split view's (sidebar, detail, computer panel) is the window's. A
                // smaller one (it was 900) let the window be narrower than the columns fit in, restored or resized, and
                // AppKit then relaid the split view out until it gave up ("more Update Constraints in Window passes
                // than there are views in the window"): a crash at launch at the default 1180 with the panel open.
                .frame(minHeight: 560)
                .pennantAppearance()
                .modifier(OpenSettingsAtLaunch())
                .task { await start() }
        }
        .windowStyle(.hiddenTitleBar)
        // Compact toolbar: the window draws its own header row, so the system band only carries the traffic lights.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            // The toolbar's sidebar button is gone, so keep View > Toggle Sidebar (⌃⌘S).
            SidebarCommands()
            ZoomCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkNow() }
                    .disabled(!Updates.shared.isAvailable)
                Button("Stop computer use") { Task { try? await session.pauseDesktop() } }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowList) {
                OpenConversationsCommand()
            }
            CommandGroup(replacing: .newItem) {
                NewThreadCommand()
            }
        }

        // Every thread in one window, and any thread in a window of its own.
        Window("Conversations", id: "conversations") {
            ConversationsWindow()
                .hostSession(session)
                .pennantAppearance()
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup("Conversation", id: "conversation", for: ConversationRef.self) { $ref in
            if let ref {
                ConversationWindow(ref: ref)
                    .hostSession(session)
                    .pennantAppearance()
            }
        }
        .defaultSize(width: 640, height: 720)

        MenuBarExtra {
            MenuBarContent().hostSession(session)
        } label: {
            MenuBarLabel().hostSession(session)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().hostSession(session).environment(launcher)
        }
    }

    private func start() async {
        #if DEBUG
        if DemoLaunch.host != nil { session.connect(); return }
        #endif
        let loopback = AppSettings.endpoint.host == "127.0.0.1" || AppSettings.endpoint.host == "localhost"
        if loopback {
            await launcher.ensureHostRunning(port: session.endpoint.port)
            if let t = ClientCredentials.readLocalHostToken() { session.token = t }
        }
        session.connect()
        // Keep the local host alive and the token current for as long as the app runs:
        // a freshly spawned host writes its token a moment after starting, and a host that exits
        // (crash, update, manual stop) is started again instead of leaving the app disconnected.
        if loopback {
            Task { @MainActor in
                var downSince: Date?
                var restartedForUpdate = false
                while true {
                    if session.connection.isConnected {
                        downSince = nil
                        // After an update the host from before it can still be running (launchd keeps it alive):
                        // once it is idle, restart it so it runs the helper this app carries.
                        if !restartedForUpdate, let host = session.state.host, let hostBuild = host.build,
                           let appBuild = PennantVersion.build, hostBuild != appBuild, host.activeTaskCount == 0 {
                            restartedForUpdate = true
                            await session.disconnect()
                            await launcher.restartHost(port: session.endpoint.port)
                            if let t = ClientCredentials.readLocalHostToken() { session.token = t }
                            session.connect()
                        }
                    } else {
                        if let t = ClientCredentials.readLocalHostToken(), t != session.token { session.token = t }
                        downSince = downSince ?? Date()
                        if Date().timeIntervalSince(downSince!) > 6 {
                            await launcher.ensureHostRunning(port: session.endpoint.port)
                            downSince = Date()
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle starts with the app, so a scheduled check runs even while no window is open.
        _ = Updates.shared
        ZoomCommands.acceptCommandEquals()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The Dock reads the icon through LaunchServices, which caches by bundle path and version; a rebuilt
        // bundle at the same path can come up with a blank tile. Setting the icon directly makes it deterministic.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Menu-bar dot: green when an agent is using the computer, blue when you hold control, yellow when paused.
struct MenuBarLabel: View {
    @Environment(\.hostSession) private var session
    var body: some View {
        let d = session.state.desktop
        let symbol: String = {
            switch d.owner {
            case .agent: return "circle.fill"
            case .human: return "hand.raised.circle.fill"
            case .nobody: return d.pausedByHuman ? "pause.circle.fill" : "circle"
            }
        }()
        Image(systemName: symbol)
    }
}

struct MenuBarContent: View {
    @Environment(\.hostSession) private var session
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let d = session.state.desktop
        switch d.owner {
        case .agent(let id, _):
            Text("\(session.state.agent(id)?.name ?? "An agent") is using the computer")
        case .human:
            Text("You have control of the computer")
        case .nobody:
            Text(d.pausedByHuman ? "Computer use is paused" : "No agent is using the computer")
        }
        Divider()
        if d.pausedByHuman {
            Button("Resume computer use") { Task { try? await session.resumeDesktop() } }
        } else {
            Button("Stop computer use") { Task { try? await session.pauseDesktop() } }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        if case .human = d.owner {
            Button("Release control") { Task { try? await session.releaseDesktop() } }
        } else {
            Button("Take over") { Task { try? await session.takeoverDesktop() } }
        }
        Divider()
        Button("Open Pennant") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        if Updates.shared.isAvailable {
            Button("Check for Updates…") { Updates.shared.checkNow() }
        }
        Button("Quit Pennant") { NSApp.terminate(nil) }
    }
}

/// `PENNANT_OPEN_SETTINGS=<pane>` opens Settings on that pane at launch (for screenshots and support).
private struct OpenSettingsAtLaunch: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.task {
            guard let pane = ProcessInfo.processInfo.environment["PENNANT_OPEN_SETTINGS"] else { return }
            if SettingsView.Pane(rawValue: pane) != nil { UserDefaults.standard.set(pane, forKey: "pennant.settings.pane") }
            openSettings()
        }
    }
}
