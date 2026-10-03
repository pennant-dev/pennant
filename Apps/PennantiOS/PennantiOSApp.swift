import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI
import UIKit

@main
struct PennantiOSApp: App {
    @UIApplicationDelegateAdaptor(PennantAppDelegate.self) private var appDelegate
    @State private var session: HostSession
    @State private var paired: Bool
    /// A Mac's connect code opened from the Camera app (pennant://connect?…).
    @State private var connectCode: HostEndpoint?

    init() {
        LegacyDefaults.migrate()
        #if DEBUG
        if let debug = DebugLaunch.session() {
            _session = State(initialValue: debug)
            _paired = State(initialValue: true)
            return
        }
        #endif
        let endpoint = PhoneSettings.endpoint
        PhoneSettings.migrateLegacyToken(for: endpoint)
        let credentials = endpoint.host.isEmpty ? nil : ClientCredentials.load(for: endpoint)
        let s = HostSession(
            transport: WebSocketTransport(),
            endpoint: endpoint,
            token: credentials?.token,
            clientID: credentials?.clientID ?? ClientCredentials.deviceClientID(),
            displayName: UIDevice.current.name,
            platform: "iOS"
        )
        // Through Cloudflare Access the saved token is the Access token.
        if endpoint.isAccess { s.token = nil; s.accessToken = credentials?.token }
        // The host's other addresses (its Tailscale name, say), so the phone finds it away from home too.
        s.onAddressesChanged = { PhoneSettings.endpoint = $0 }
        s.state.persistReadMarks(in: .standard)
        _session = State(initialValue: s)
        _paired = State(initialValue: credentials != nil)
    }

    var body: some Scene {
        WindowGroup {
            rootContent.pennantAppearance()
        }
    }

    @ViewBuilder private var rootContent: some View {
            Group {
                if let screen = DebugLaunch.screen {
                    DebugLaunch.view(for: screen)
                        .task { session.connect() }
                } else if paired {
                    RootTabs(onUnpair: unpair)
                        .task { session.connect() }
                } else {
                    SignInView(connectCode: connectCode) { endpoint, token, hostName in
                        PhoneSettings.endpoint = endpoint
                        try? ClientCredentials.save(ClientCredentials(clientID: session.clientID, token: token, hostName: hostName), for: endpoint)
                        if endpoint.isAccess { session.token = nil; session.accessToken = token } else { session.token = token }
                        session.connect(to: endpoint)
                        paired = true
                    }
                }
            }
            .hostSession(session)
            .onOpenURL { url in
                guard let code = HostEndpoint(connectURL: url) else { return }
                if !paired { connectCode = code; return }
                // The Mac this phone already uses (same certificate): keep its addresses.
                if let pin = HostPins.pin(for: session.endpoint), pin == code.fingerprint {
                    session.rememberAddresses([code.host] + (code.alternates ?? []))
                }
            }
            // Pennant's chrome is quiet: one accent for controls, theme tokens for every surface.
            .tint(Color(hex: PennantPalette.defaultHex))
            .background(PennantTheme.windowBackground)
    }

    private func unpair() {
        Task {
            await session.disconnect()
            ClientCredentials.remove(for: session.endpoint)
            // A reinstalled Mac has a new certificate; signing in again trusts that one.
            HostPins.forget(session.endpoint)
            session.token = nil
            paired = false
        }
    }
}

enum PhoneSettings {
    private static var defaults: UserDefaults { .standard }

    static var endpoint: HostEndpoint {
        get {
            let host = defaults.string(forKey: "pennant.host") ?? ""
            if defaults.bool(forKey: "pennant.viaAccess"), !host.isEmpty { return .access(host) }
            let port = defaults.integer(forKey: "pennant.port")
            var endpoint = HostEndpoint(host: host, port: port == 0 ? 7331 : port, name: host)
            endpoint.alternates = defaults.stringArray(forKey: "pennant.hostAlternates")
            return endpoint
        }
        set {
            defaults.set(newValue.host, forKey: "pennant.host")
            defaults.set(newValue.port, forKey: "pennant.port")
            defaults.set(newValue.isAccess, forKey: "pennant.viaAccess")
            defaults.set(newValue.alternates, forKey: "pennant.hostAlternates")
        }
    }

    /// Earlier builds kept the token in UserDefaults. Move it into the Keychain once.
    static func migrateLegacyToken(for endpoint: HostEndpoint) {
        guard !endpoint.host.isEmpty else { return }
        let key = "pennant.token.\(endpoint.host):\(endpoint.port)"
        guard let token = defaults.string(forKey: key), !token.isEmpty else { return }
        if ClientCredentials.load(for: endpoint) == nil {
            let clientID = defaults.string(forKey: "pennant.clientID").map { ClientID($0) } ?? ClientCredentials.deviceClientID()
            try? ClientCredentials.save(ClientCredentials(clientID: clientID, token: token, hostName: endpoint.name), for: endpoint)
        }
        defaults.removeObject(forKey: key)
    }
}

/// Debug builds only: the simulator opens one screen against the host on this Mac, for layout checks.
/// `SIMCTL_CHILD_PENNANT_DEBUG_HOST=127.0.0.1:7331`, `SIMCTL_CHILD_PENNANT_DEBUG_TOKEN_FILE=<the host's client-token
/// file>`, `SIMCTL_CHILD_PENNANT_DEBUG_SCREEN=skills` (or pennant, computer, fullscreen, memory, home, threads, approval:<job>, agent:<name>; touchlab needs no host). Release builds ignore all of it.
enum DebugLaunch {
    static var screen: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PENNANT_DEBUG_SCREEN"]
        #else
        return nil
        #endif
    }

    #if DEBUG
    @MainActor static func session() -> HostSession? {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["PENNANT_DEBUG_HOST"], let file = env["PENNANT_DEBUG_TOKEN_FILE"],
              let token = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        let parts = address.split(separator: ":")
        let host = String(parts.first ?? "127.0.0.1")
        let port = parts.count > 1 ? Int(parts[1]) ?? 7331 : 7331
        return HostSession(transport: WebSocketTransport(), endpoint: HostEndpoint(host: host, port: port, name: "Debug host"), token: token, clientID: ClientID("ios-simulator-debug"), displayName: "Simulator", platform: "iOS")
    }
    #endif

    @MainActor @ViewBuilder
    static func view(for screen: String) -> some View {
        switch screen {
        case "skills":
            NavigationStack { SkillsView().navigationTitle("Skills") }
        case "computer":
            ComputerTab()
        case "fullscreen":
            FullScreenComputer()
        #if DEBUG
        case "touchlab":
            TouchLab()
        #endif
        case "memory":
            MemoryTab()
        case "home":
            HomeTab()
        case "pennant":
            DebugPennantChat()
        case "threads":
            NavigationStack {
                ThreadListView(selected: nil, onOpen: { _, _ in }, onNewThread: {})
                    .background(PennantTheme.sidebarBackground)
                    .navigationTitle("Threads")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case let s where s.hasPrefix("approval:"):
            DebugLatestApproval(name: String(s.dropFirst(9)))
        case let s where s.hasPrefix("agent:"):
            DebugAgentConversation(name: String(s.dropFirst(6)))
        default:
            Text("Unknown debug screen \(screen)")
        }
    }
}

/// Debug screen "pennant": the Pennant tab, without asking for notifications.
private struct DebugPennantChat: View {
    @Environment(\.hostSession) private var session
    var body: some View {
        if let chat = session.state.mainConversation { PennantTab(chat: chat) } else { ProgressView("Waiting for the Pennant chat…") }
    }
}

/// Debug screen "agent:<name>": that agent's latest conversation, as the phone shows it.
private struct DebugAgentConversation: View {
    @Environment(\.hostSession) private var session
    var name: String
    @State private var conversationID: ConversationID?

    var body: some View {
        let agent = session.state.agents.first { $0.name == name }
        NavigationStack {
            if let agent {
                ConversationView(agentID: agent.id, conversationID: $conversationID)
                    .navigationTitle(agent.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .task {
                        if conversationID == nil {
                            conversationID = session.state.tasks.filter { $0.agentID == agent.id }.max { $0.createdAt < $1.createdAt }?.conversationID
                        }
                    }
            } else {
                ProgressView("Waiting for \(name)…")
            }
        }
    }
}

/// Debug screen "approval:<name>": the latest card in the newest threads whose title has <name> (a job, like "Company
/// post"), else in the latest work of the agent with that name, on its own at phone width.
private struct DebugLatestApproval: View {
    @Environment(\.hostSession) private var session
    var name: String
    @State private var card: ApprovalRequest?

    private func threads() -> [ConversationID] {
        let named = session.state.conversations.filter { $0.title.localizedCaseInsensitiveContains(name) }.sorted { $0.updatedAt > $1.updatedAt }
        if !named.isEmpty { return named.prefix(6).map(\.id) }
        guard let agent = session.state.agents.first(where: { $0.name == name }) else { return [] }
        return session.state.tasks.filter { $0.agentID == agent.id }.sorted { $0.createdAt > $1.createdAt }.prefix(6).map(\.conversationID)
    }

    var body: some View {
        ScrollView {
            if let card { ApprovalCard(request: card).padding(12) } else { ProgressView("Loading the \(name) card…").padding(40) }
        }
        // PENNANT_DEBUG_ANCHOR=bottom shows the card's end (its buttons).
        .defaultScrollAnchor(ProcessInfo.processInfo.environment["PENNANT_DEBUG_ANCHOR"] == "bottom" ? .bottom : .top)
        .task {
            for _ in 0..<40 where card == nil {
                for id in threads() {
                    _ = try? await session.loadMessages(conversationID: id, limit: 400)
                    if let found = (session.state.messages[id] ?? []).flatMap(\.parts).compactMap({ part -> ApprovalRequest? in if case .approval(let a) = part { return a }; return nil }).last {
                        card = found; break
                    }
                }
                if card == nil { try? await Task.sleep(for: .milliseconds(250)) }
            }
        }
    }
}

#if DEBUG
/// Debug screen "touchlab": the live screen's gestures against a test grid the shape of a Mac display, with no host.
/// It shows the input it would send and the zoom (as the screen's accessibility value), for the touch UI tests.
/// `PENNANT_DEBUG_POINTER=trackpad` starts in trackpad mode.
private struct TouchLab: View {
    @State private var last = "none"
    @State private var zoomRequest: ScreenZoomRequest?
    @State private var viewport = "whole"
    @State private var keyboard = false
    private let mode = RemotePointerMode(rawValue: ProcessInfo.processInfo.environment["PENNANT_DEBUG_POINTER"] ?? "") ?? .touch
    private static let grid: UIImage = {
        let size = CGSize(width: 1728, height: 1117)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.lightGray.setStroke()
            for x in stride(from: 0, through: size.width, by: 144) { context.cgContext.stroke(CGRect(x: x, y: 0, width: 1, height: size.height)) }
            for y in stride(from: 0, through: size.height, by: 144) { context.cgContext.stroke(CGRect(x: 0, y: y, width: size.width, height: 1)) }
        }
    }()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                Button("Zoom out") { zoomRequest = ScreenZoomRequest(zoomIn: false) }.accessibilityIdentifier("zoom-out")
                Button("Zoom in") { zoomRequest = ScreenZoomRequest(zoomIn: true) }.accessibilityIdentifier("zoom-in")
                Button("Keyboard") { keyboard.toggle() }.accessibilityIdentifier("keyboard")
            }
            .background { RemoteKeyboard(isActive: $keyboard) { last = Self.describe($0) }.frame(width: 1, height: 1) }
            ScreenImageView(image: Self.grid, interactive: true, zoomRequest: zoomRequest, onViewport: { region in
                viewport = region.map { String(format: "%.3f %.3f %.3f %.3f", $0.x, $0.y, $0.width, $0.height) } ?? "whole"
            }) { input in last = Self.describe(input) }
                .aspectRatio(1728.0 / 1117.0, contentMode: .fit)
                .environment(\.remotePointerMode, mode)
            Text(last).font(.caption.monospaced()).accessibilityIdentifier("last-input")
            Text(viewport).font(.caption.monospaced()).accessibilityIdentifier("viewport")
        }
        .padding(.vertical, 40)
    }

    static func describe(_ input: RemoteInput) -> String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        switch input {
        case .click(let x, let y, let b, let n): return "click \(b.rawValue) \(f(x)) \(f(y)) \(n)"
        case .pointerMove(let x, let y): return "move \(f(x)) \(f(y))"
        case .pointerDown(let x, let y, let b): return "down \(b.rawValue) \(f(x)) \(f(y))"
        case .pointerUp(let x, let y, let b): return "up \(b.rawValue) \(f(x)) \(f(y))"
        case .scroll(_, _, let dx, let dy): return "scroll \(f(dx)) \(f(dy))"
        case .typeText(let text): return "type \(text)"
        case .key(let chord): return "key \(chord.key)"
        }
    }
}
#endif
