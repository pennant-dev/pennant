import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

struct RootTabs: View {
    @Environment(\.hostSession) private var session
    var onUnpair: () -> Void
    @State private var push = PushCenter.shared
    @State private var opened: ConversationTarget?

    var body: some View {
        TabView {
            ThreadsTab()
                .tabItem { Label("Threads", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(needsYouCount)
            HomeTab()
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }
            NavigationStack {
                InboxView()
                    .navigationTitle("Inbox")
            }
            .tabItem { Label("Inbox", systemImage: "tray") }
            .badge(session.state.pendingApprovals.count)
            ComputerTab()
                .tabItem { Label("Computer", systemImage: "desktopcomputer") }
            MemoryTab()
            .tabItem { Label("Memory", systemImage: "brain") }
            NavigationStack {
                PhoneSettingsView(onUnpair: onUnpair)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .top) {
            if session.needsAccessSignIn { AccessExpiredBanner().transition(.move(edge: .top).combined(with: .opacity)) }
        }
        // Notifications: ask and register once connected; a tapped one opens its conversation.
        .task(id: session.connection.isConnected) {
            guard session.connection.isConnected else { return }
            push.start(with: session)
            push.connectionChanged()
        }
        .onChange(of: push.pendingOpen?.conversationID) { _, _ in
            guard let p = push.pendingOpen else { return }
            opened = ConversationTarget(agentID: p.agentID, conversationID: p.conversationID)
            push.pendingOpen = nil
        }
        .sheet(item: $opened) { t in
            NavigationStack { AgentConversationScreen(agentID: t.agentID, initialConversationID: t.conversationID) }
        }
    }

    /// Cards and questions waiting on you, for the Threads tab's badge.
    private var needsYouCount: Int {
        let cards = Set(session.state.pendingApprovals.map(\.conversationID))
        let questions = Set(session.state.tasks.filter { $0.state == .waitingForUser && $0.parentTaskID == nil }.map(\.conversationID))
        return cards.union(questions).count
    }
}

// MARK: - Threads

/// The main screen: what needs you, every thread newest first, and the closed ones folded away. Swipe a thread left
/// to close it; it comes back on its own when something happens in it.
struct ThreadsTab: View {
    @Environment(\.hostSession) private var session
    struct Target: Hashable, Identifiable {
        var agentID: AgentID
        var conversationID: ConversationID?
        var nonce = UUID()
        var id: String { agentID.rawValue + "/" + (conversationID?.rawValue ?? "new-" + nonce.uuidString) }
    }
    @State private var target: Target?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBanner()
                ThreadListView(selected: nil,
                               onOpen: { target = Target(agentID: $0, conversationID: $1) },
                               onNewThread: { if let lead { target = Target(agentID: lead, conversationID: nil) } })
            }
            .background(PennantTheme.sidebarBackground)
            .navigationTitle("Threads")
            .toolbar {
                Button { if let lead { target = Target(agentID: lead, conversationID: nil) } } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New thread")
            }
            .navigationDestination(item: $target) { t in
                AgentConversationScreen(agentID: t.agentID, initialConversationID: t.conversationID, startsNew: t.conversationID == nil)
            }
        }
    }

    private var lead: AgentID? { session.state.leadAgent?.id }
}

// MARK: - Home (Dashboard)

/// The dashboard: who is working on what, what needs you, today, what's next, the latest reports.
struct HomeTab: View {
    /// An agent and one of its conversations, or a fresh one.
    struct Target: Hashable, Identifiable {
        var agentID: AgentID
        var conversationID: ConversationID?
        var id: String { agentID.rawValue + "/" + (conversationID?.rawValue ?? "new") }
    }
    @State private var target: Target?
    @State private var showReports = false
    @State private var showGoals = false
    @State private var openGoal: GoalID?
    var body: some View {
        NavigationStack {
            DashboardView(onOpenChat: { target = Target(agentID: $0, conversationID: $1) }, onOpenReports: { showReports = true }, onOpenGoals: { showGoals = true },
                          onOpenGoal: { openGoal = $0; showGoals = true })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $target) { t in AgentConversationScreen(agentID: t.agentID, initialConversationID: t.conversationID) }
                .navigationDestination(isPresented: $showReports) {
                    ReportsView { target = Target(agentID: $0, conversationID: $1) }
                        .navigationTitle("Reports")
                }
                .navigationDestination(isPresented: $showGoals) {
                    GoalsView(open: $openGoal) { target = Target(agentID: $0, conversationID: $1) }
                        .navigationTitle("Goals")
                }
        }
    }
}

// MARK: - Memory

/// Memory, where a passage opens the conversation it came from.
struct MemoryTab: View {
    @State private var target: ConversationTarget?
    var body: some View {
        NavigationStack {
            MemoryView()
                .navigationTitle("Memory")
                .background(PennantTheme.windowBackground)
                .environment(\.openChat, { agentID, conversationID in
                    if let conversationID { target = ConversationTarget(agentID: agentID, conversationID: conversationID) }
                })
                .navigationDestination(item: $target) { t in AgentConversationScreen(agentID: t.agentID, initialConversationID: t.conversationID) }
        }
    }
}

// MARK: - Conversation

struct ConversationTarget: Hashable, Identifiable {
    var agentID: AgentID
    var conversationID: ConversationID
    var id: String { agentID.rawValue + "/" + conversationID.rawValue }
}

/// A conversation. Tapping the title lists the agent's conversations (label and time) with "New conversation"; the
/// trailing menu edits the agent (or retires a helper).
struct AgentConversationScreen: View {
    @Environment(\.hostSession) private var session
    var agentID: AgentID
    var initialConversationID: ConversationID? = nil
    /// Opened for a fresh thread: stay on it instead of landing on the latest one.
    var startsNew = false
    @State private var conversationID: ConversationID?
    @State private var editing: AgentProfile?
    @State private var showingList = false

    private var agent: AgentProfile? { session.state.agent(agentID) }

    var body: some View {
        ConversationView(agentID: agentID, conversationID: $conversationID)
            .background(PennantTheme.windowBackground)
            .navigationTitle(threadTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarTitleMenu {
                ConversationMenuItems(agentID: agentID, conversationID: $conversationID)
            }
            .toolbar {
                Button { conversationID = nil } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
                Menu {
                    Button { showingList = true } label: { Label("All conversations", systemImage: "list.bullet") }
                    if conversationID != nil {
                        CloseConversationButton(conversationID: $conversationID)
                    }
                    Divider()
                    if let agent {
                        Button { editing = agent } label: { Label("Edit agent", systemImage: "slider.horizontal.3") }
                        if agent.kind == .worker {
                            Button(role: .destructive) { Task { try? await session.retireAgent(agent.id) } } label: {
                                Label("Retire worker", systemImage: "person.crop.circle.badge.minus")
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Agent options")
            }
            .sheet(item: $editing) { AgentEditorView(agent: $0) }
            .navigationDestination(isPresented: $showingList) {
                PhoneConversationsView(agentID: agentID) { _, c in conversationID = c; showingList = false }
            }
            .onAppear { if conversationID == nil, !startsNew { conversationID = initialConversationID ?? session.state.conversationToOpen(agentID: agentID) } }
    }

    private var threadTitle: String {
        guard let id = conversationID, let c = session.state.conversation(id) else { return "New thread" }
        return conversationLabel(c)
    }
}

// MARK: - Computer

/// Live view with prominent controls. Touch maps to the pointer during takeover.
struct ComputerTab: View {
    @State private var fullscreen = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBanner()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ComputerPanelView(compact: false)
                            .frame(maxWidth: .infinity)
                        Text("Tap to click, touch and hold for a right click, drag to drag, two fingers to scroll the Mac. Pinch to zoom; zoomed in, two fingers move around and a two-finger double tap zooms back out. Use the keyboard button to type.")
                            .font(.caption)
                            .foregroundStyle(PennantTheme.inkTertiary)
                            .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(PennantTheme.windowBackground)
            .navigationTitle("Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("Full screen")
                }
            }
            .fullScreenCover(isPresented: $fullscreen) { FullScreenComputer() }
        }
    }
}

/// Edge-to-edge screen. It watches the stream itself: a full-screen cover takes the panel underneath off screen,
/// and the panel lets go of the stream when it goes.
struct FullScreenComputer: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var decoded: (seq: Int64, image: PlatformImage)?
    @State private var keyboardVisible = false
    @State private var keyboardBuffer = ""

    private var desktop: DesktopStatus { session.state.desktop }
    private var humanHasControl: Bool { if case .human = desktop.owner { return true }; return false }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if let decoded {
                ScreenImageView(image: decoded.image, interactive: humanHasControl) { input in
                    Task { try? await session.sendRemoteInput(input) }
                }
            } else {
                ProgressView().tint(.white)
            }
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    Spacer()
                    if humanHasControl {
                        Button { keyboardVisible.toggle() } label: { Image(systemName: "keyboard") .font(.title3) }
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.6), radius: 3)
                if keyboardVisible, humanHasControl { keyboardRow }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .ignoresSafeArea()
        .onChange(of: session.state.screenFrame?.header.sequence) { _, _ in decodeLatest() }
        .onAppear { decodeLatest() }
        .task { await session.watchScreen() }
        .onDisappear { Task { await session.stopWatchingScreen() } }
        .statusBarHidden(true)
    }

    private var keyboardRow: some View {
        HStack {
            TextField("Type to send keystrokes", text: $keyboardBuffer)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .onChange(of: keyboardBuffer) { old, new in
            if new.count > old.count, new.hasPrefix(old) {
                let added = String(new.dropFirst(old.count))
                Task { try? await session.sendRemoteInput(.typeText(added)) }
            } else if new.count < old.count {
                for _ in 0 ..< (old.count - new.count) { Task { try? await session.sendRemoteInput(.key(KeyChord(key: "delete"))) } }
            }
        }
        .onSubmit {
            Task { try? await session.sendRemoteInput(.key(KeyChord(key: "return"))) }
            keyboardBuffer = ""
        }
    }

    private func decodeLatest() {
        guard let frame = session.state.screenFrame else { decoded = nil; return }
        if decoded?.seq == frame.header.sequence { return }
        if let img = PlatformImage(data: frame.jpeg) { decoded = (frame.header.sequence, img) }
    }
}

// MARK: - Settings

struct PhoneSettingsView: View {
    @Environment(\.hostSession) private var session
    var onUnpair: () -> Void
    @State private var target: ConversationTarget?

    /// How an address is reached, in words.
    static func route(_ address: String) -> String {
        if address.hasSuffix(".ts.net") || address.hasPrefix("100.") || address.lowercased().hasPrefix("fd7a:115c:a1e0") { return "Tailscale" }
        if address.hasPrefix("192.168.") || address.hasPrefix("10.") || address.hasSuffix(".local") { return "Local network" }
        return "Network"
    }

    var body: some View {
        List {
            if let me = session.state.me {
                Section {
                    HStack(spacing: 12) {
                        Text(String(me.name.prefix(1)).uppercased())
                            .font(.headline).foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(hex: "#6A3FD9"), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.name).font(.body.weight(.semibold))
                            Text([me.email.isEmpty ? nil : me.email, me.role == .owner ? "Owner" : "Member"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(PennantTheme.inkSecondary)
                        }
                    }
                    if !me.identities.isEmpty {
                        LabeledContent("Signed in with", value: me.identities.map(\.provider.title).joined(separator: ", "))
                    }
                    NavigationLink {
                        ScrollView {
                            MyAccountForm(person: session.state.me, asksCurrentPassword: true)
                                .padding(20)
                        }
                        .background(PennantTheme.panelBackground)
                        .navigationTitle("Account")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label(me.hasPassword ? "Name, email and password" : "Set a password", systemImage: "key")
                    }
                    Button(role: .destructive) { onUnpair() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                } header: {
                    SettingsHeader("Account")
                }
                .listRowBackground(PennantTheme.cardElevated)
            }
            Section {
                LabeledContent("Address", value: "\(session.reachedAddress ?? session.endpoint.host):\(session.endpoint.port)")
                if let via = session.reachedAddress.map(Self.route) { LabeledContent("Through", value: via) }
                LabeledContent("Status", value: session.connectionLabel)
                if let others = session.endpoint.alternates, !others.isEmpty {
                    LabeledContent("Also tries", value: ([session.endpoint.host] + others).filter { $0 != session.reachedAddress }.joined(separator: ", "))
                }
                if let h = session.state.host {
                    LabeledContent("Name", value: h.hostName)
                    LabeledContent("Mode", value: h.mode.rawValue)
                    LabeledContent("Model", value: h.inferenceModel)
                }
                Button { Task { await session.disconnect(); session.connect() } } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            } header: {
                SettingsHeader("Host")
            }
            .listRowBackground(PennantTheme.cardElevated)

            Section {
                AppearancePicker()
            } header: {
                SettingsHeader("Appearance")
            }
            .listRowBackground(PennantTheme.cardElevated)

            Section {
                Toggle(isOn: Binding(
                    get: { session.state.desktop.pauseOnHumanInput },
                    set: { v in Task { try? await session.setPauseOnHumanInput(v) } }
                )) {
                    Text("Pause agents when someone uses the Mac")
                }
            } header: {
                SettingsHeader("Computer")
            }
            .listRowBackground(PennantTheme.cardElevated)

            Section {
                NavigationLink {
                    ScrollView { PermissionsView(readOnly: true).padding(16) }
                        .background(PennantTheme.windowBackground)
                        .navigationTitle("Mac permissions")
                } label: {
                    HStack {
                        Label("Mac permissions", systemImage: "lock.shield")
                        Spacer()
                        let p = session.state.desktop.permissions
                        Chip(p.allGranted ? "all granted" : "\(p.missing.count) missing", color: p.allGranted ? Color(hex: "#3DB553") : Color(hex: "#F0762B"))
                    }
                }
                NavigationLink {
                    SkillsView().navigationTitle("Skills")
                } label: {
                    Label("Skills", systemImage: "sparkles")
                }
                NavigationLink {
                    PhoneConversationsView { agentID, conversationID in target = ConversationTarget(agentID: agentID, conversationID: conversationID) }
                        .navigationDestination(item: $target) { t in AgentConversationScreen(agentID: t.agentID, initialConversationID: t.conversationID) }
                } label: {
                    Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                }
                NavigationLink {
                    GoalsView { agentID, conversationID in target = ConversationTarget(agentID: agentID, conversationID: conversationID) }
                        .navigationTitle("Goals")
                        .navigationDestination(item: $target) { t in AgentConversationScreen(agentID: t.agentID, initialConversationID: t.conversationID) }
                } label: {
                    Label("Goals", systemImage: "target")
                }
                NavigationLink {
                    SchedulesView { agentID, conversationID in target = ConversationTarget(agentID: agentID, conversationID: conversationID) }
                        .navigationTitle("Schedules")
                        .navigationDestination(item: $target) { t in AgentConversationScreen(agentID: t.agentID, initialConversationID: t.conversationID) }
                } label: {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                }
                NavigationLink {
                    ConnectionsView().navigationTitle("Connections")
                } label: {
                    Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                }
                NavigationLink {
                    DiagnosticsView().navigationTitle("Diagnostics")
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            } header: {
                SettingsHeader("More")
            }
            .listRowBackground(PennantTheme.cardElevated)

            Section {
                Button(role: .destructive, action: onUnpair) {
                    Label("Unpair this device", systemImage: "iphone.slash")
                        .foregroundStyle(Color(hex: "#E5484D"))
                }
            }
            .listRowBackground(PennantTheme.cardElevated)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PennantTheme.panelBackground)
        .foregroundStyle(PennantTheme.ink)
    }
}

/// Section caption in the theme's secondary ink, no uppercase.
struct SettingsHeader: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        SectionLabel(text).textCase(nil)
    }
}
