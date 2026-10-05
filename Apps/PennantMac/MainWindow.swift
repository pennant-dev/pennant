import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard, goals, approvals, reports, memory, skills, library, vault, usage, schedules, connections, diagnostics
    var id: String { rawValue }
    /// The rows under the thread list. The dashboard has its own row on top; the rest sit in the More menu.
    static let utilities: [SidebarSection] = [.goals, .reports, .memory, .schedules, .skills]
    static let more: [SidebarSection] = [.library, .vault, .usage, .connections, .diagnostics, .approvals]
    var title: String { self == .approvals ? "Approval history" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .approvals: return "checkmark.seal"
        case .reports: return "doc.text.magnifyingglass"
        case .memory: return "brain.head.profile"
        case .skills: return "wand.and.stars"
        case .library: return "photo.on.rectangle.angled"
        case .vault: return "lock.shield"
        case .usage: return "chart.bar.xaxis"
        case .schedules: return "calendar.badge.clock"
        case .goals: return ThreadMark.goalSymbol
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// The main window: a warm grey sidebar with the threads, a white conversation pane with its own slim
/// header, and the computer inspector on the right. The system toolbar is hidden; the traffic lights
/// sit in the sidebar's top band.
struct MainWindow: View {
    @Environment(\.hostSession) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var selectedAgent: AgentID?
    /// The window opens on the Pennant chat (on hosts from before it, the dashboard; see `pickDefaultAgent`).
    @State private var section: SidebarSection?
    /// A goal the dashboard asked the Goals page to open.
    @State private var openGoal: GoalID?
    @State private var conversationID: ConversationID?
    @State private var showComputer = AppSettings.showComputerPanel
    /// The model switcher opened from the sidebar's host row.
    @State private var showModels = false
    @State private var showMore = false
    /// The teach-mode review sheet, shown when a demonstration stops.
    @State private var showTeachingReview = false
    /// The agent whose prompt the inspector shows.
    @State private var inspecting: AgentProfile?
    @State private var editingAgent: AgentProfile?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(HostLauncher.self) private var launcher
    @State private var showPermissions = false
    /// First run on the host's own Mac: the owner has no way to sign in from other devices yet.
    @State private var showAccountSetup = false
    @State private var accountSetupDismissed = false
    @State private var permissionsDismissed = false
    /// The window has been put on the Pennant chat once; after that, it stays where the owner goes.
    @State private var placedOnChat = false

    /// Height of the band under the window's traffic lights. Matches the compact toolbar height.
    private let titleBand: CGFloat = 38

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            detail
                // The computer beside the work. What needs you lives on the dashboard.
                .inspector(isPresented: $showComputer) {
                    // The column sizes the panel, never its content: the live screen's aspect ratio (it changes when
                    // the first frame lands) used to move the column's min/max size mid-layout, and AppKit aborted the
                    // launch ("more Update Constraints in Window passes than there are views").
                    Color.clear
                        .overlay(alignment: .top) {
                            ComputerPanelView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .background(PennantTheme.windowBackground)
                        .inspectorColumnWidth(min: 320, ideal: 420, max: 720)
                }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        // Menus and the thread list offer "Open in New Window".
        .environment(\.openInNewWindow, { [openWindow] agent, conversation in
            openWindow(id: "conversation", value: ConversationRef(agentID: agent, conversationID: conversation))
        })
        // Threads lead back to the one place to talk.
        .environment(\.openPennantChat, { [section = $section, conversation = $conversationID, agent = $selectedAgent, session] in
            guard let chat = session.state.mainConversation else { return }
            section.wrappedValue = nil
            conversation.wrappedValue = chat.id
            agent.wrappedValue = chat.agentID
        })
        .onAppear { pickDefaultAgent() }
        .onReceive(NotificationCenter.default.publisher(for: .pennantNewThread)) { _ in
            if let chat = session.state.mainConversation { openConversation(agentID: chat.agentID, conversationID: chat.id) }
            else if let lead = session.state.leadAgent?.id { openConversation(agentID: lead, conversationID: nil) }
        }
        // There are no new threads to start by hand: an empty pane is the Pennant chat.
        .onChange(of: conversationID) { _, new in
            if new == nil, section == nil, let chat = session.state.mainConversation {
                conversationID = chat.id
                selectedAgent = chat.agentID
            }
        }
        .onChange(of: session.state.mainConversation?.id) { old, new in
            if old == nil, new != nil, !placedOnChat { pickDefaultAgent(force: true) }
        }
        .task {
            #if DEBUG
            if let folder = DemoLaunch.shotsFolder { await takeDemoShots(into: folder) }
            #endif
        }
        .onChange(of: session.state.agents.count) { _, _ in pickDefaultAgent() }
        .onChange(of: selectedAgent) { old, new in
            // Opening the agent at launch keeps the dashboard up; opening a thread later leaves it.
            if old != nil { section = nil }
            // The thread list and the schedules pane set the conversation before the agent; keep one that belongs
            // to it, otherwise land on its latest. `nil` stays `nil`: that is a fresh conversation.
            if let c = conversationID, session.state.conversation(c)?.agentID != new {
                conversationID = new.flatMap { session.state.conversations(for: $0).first?.id }
            }
        }
        .onChange(of: session.state.desktop.owner) { old, new in
            if case .agent = new { showComputer = true }
            if case .nobody = new, case .agent = old, session.state.desktop.queue.isEmpty { /* keep the panel open; the user closes it */ }
        }
        .onChange(of: showComputer) { _, v in
            #if DEBUG
            if DemoLaunch.host != nil { return }
            #endif
            AppSettings.showComputerPanel = v
        }
        .onChange(of: permissionsPromptNeeded, initial: true) { _, needed in
            if needed, !permissionsDismissed, !showPermissions { showPermissions = true }
        }
        .sheet(isPresented: $showPermissions) {
            PermissionsSheet(onRestartHost: { await restartHost() }) { permissionsDismissed = true }
        }
        .sheet(item: $editingAgent) { agent in AgentEditorView(agent: agent) }
        .sheet(item: $inspecting) { agent in PromptInspectorView(agentID: agent.id) }
        .sheet(isPresented: $showTeachingReview) {
            TeachingReviewView { showTeachingReview = false }
        }
        // Teach mode: the panel floats while recording and Pennant steps aside; when recording stops, Pennant comes
        // back with the review sheet. A cancelled session just brings Pennant back.
        .onChange(of: teachingPhase) { _, phase in
            switch phase {
            case .recording:
                showTeachingReview = false
                TeachingPanelController.shared.show(session: session)
                PennantWindows.stepAside()
            case .stopped:
                TeachingPanelController.shared.hide()
                PennantWindows.comeBack()
                showTeachingReview = true
            case .none:
                TeachingPanelController.shared.hide()
                if !showTeachingReview { PennantWindows.comeBack() }
            }
        }
        .task(id: session.connection.isConnected) {
            guard session.connection.isConnected else { return }
            _ = try? await session.loadTeaching()
            // The host on this Mac: make sure its owner can sign in elsewhere (phones no longer pair with codes).
            if session.endpoint.isLoopback, !accountSetupDismissed, (try? await session.loadPeople()) != nil,
               session.state.people?.people.first(where: { $0.role == .owner })?.canSignIn != true, !showPermissions {
                showAccountSetup = true
            }
        }
        .sheet(isPresented: $showAccountSetup) {
            AccountSetupSheet { showAccountSetup = false; accountSetupDismissed = true }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // The band the traffic lights sit in. Dragging it moves the window.
            Color.clear
                .frame(height: titleBand)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            Button { section = .dashboard } label: {
                UtilityRowLabel(title: "Dashboard", symbol: SidebarSection.dashboard.symbol, selected: section == .dashboard,
                                count: session.state.mainConversation == nil ? session.state.pendingApprovals.count : 0)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("1", modifiers: .command)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            if let chat = session.state.mainConversation {
                // The one place to talk, always right here above the work: Pennant. What needs you lands there.
                PennantChatRow(chat: chat, selected: inMainChat, count: needsYouCount) {
                    openConversation(agentID: chat.agentID, conversationID: chat.id)
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
            // The work: what's going on, earlier threads folded away, closed ones below.
            ThreadListView(selected: section == nil ? conversationID : nil,
                           onOpen: { agentID, conversation in openConversation(agentID: agentID, conversationID: conversation) },
                           onNewThread: { if let lead = session.state.leadAgent?.id { openConversation(agentID: lead, conversationID: nil) } })
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            utilityRows
            identityRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PennantTheme.sidebarBackground)
        .ignoresSafeArea(edges: .top)
        .toolbar(removing: .sidebarToggle)
    }

    /// Compact rows for the sections, like a "Plugins" row: icon, label, nothing else.
    private var utilityRows: some View {
        VStack(spacing: 1) {
            ForEach(SidebarSection.utilities) { s in
                Button {
                    section = s
                } label: {
                    UtilityRowLabel(title: s.title, symbol: s.symbol, selected: section == s)
                }
                .buttonStyle(.plain)
            }
            moreRow
            // Used often enough to have its own row.
            Button { openSettings() } label: {
                UtilityRowLabel(title: "Settings", symbol: "gearshape", selected: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The rest of the sections, in a panel like the model's. The row shows the section it opened.
    private var moreRow: some View {
        let current = section.flatMap { SidebarSection.more.contains($0) ? $0 : nil }
        return Button { showMore.toggle() } label: {
            UtilityRowLabel(title: current?.title ?? "More", symbol: current?.symbol ?? "ellipsis.circle", selected: current != nil || showMore)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMore, arrowEdge: .trailing) {
            MorePanel(current: current) { choice in
                showMore = false
                switch choice {
                case .section(let s): section = s
                case .conversations: openWindow(id: "conversations")
                }
            }
        }
    }

    /// Who we are talking to: the host and the model behind it.
    private var identityRow: some View {
        let host = session.state.host
        let endpoint = session.endpoint
        let title = host?.hostName ?? (endpoint.name.isEmpty ? endpoint.host : endpoint.name)
        let subtitle: String = {
            // The default model: what agents without their own model use. Each conversation's chip shows its agent's.
            if let host, !host.inferenceModel.isEmpty, session.connection.isConnected { return "Default model: \(host.inferenceModel)" }
            return session.connectionLabel
        }()
        let connected = session.connection.isConnected
        return Button { showModels.toggle() } label: {
            HStack(spacing: 10) {
                PennantMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    HStack(spacing: 3) {
                        Text(subtitle).lineLimit(1).truncationMode(.middle)
                        if connected {
                            Image(systemName: "chevron.up.chevron.down").font(.zoomed(size: 8, weight: .semibold))
                        }
                    }
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                }
                Spacer(minLength: 0)
                StatusDot(color: connected ? Color(hex: "#3DB553") : PennantTheme.inkTertiary)
                    .help(session.connectionLabel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!connected)
        .help(connected ? "The default model, for agents without their own. Click to change it." : session.connectionLabel)
        .popover(isPresented: $showModels, arrowEdge: .trailing) {
            ModelPopover(conversationID: nil, agentID: nil)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    // MARK: Teach mode

    private enum TeachingPhase: Equatable { case none, recording, stopped }

    private var teachingPhase: TeachingPhase {
        guard let t = session.state.teaching else { return .none }
        return t.isRecording ? .recording : .stopped
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            ConnectionBanner()
            PermissionNoticeLine { showPermissions = true }
            content
        }
        // The column is as wide as the window leaves it; a pane never widens it. The dashboard's two-column layout or a
        // table would otherwise raise the split view's minimum past the window's (see the main window's scene).
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(PennantTheme.windowBackground)
        .ignoresSafeArea(edges: .top)
    }

    /// Slim header: who we are talking to on the left (the conversation's name opens the switcher), the
    /// pane's actions as round icon buttons on the right.
    private var header: some View {
        HStack(spacing: 10) {
            if let section {
                Text(section.title).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
            } else if let id = selectedAgent, let agent = session.state.agent(id) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(conversationTitle).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    if let c = conversationID.flatMap({ session.state.conversation($0) }), !c.isMain, session.state.mainConversation != nil {
                        Text("A thread \(agent.name) runs").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    }
                    if agent.kind == .worker {
                        Text(agent.name).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    }
                }
            } else {
                Text("pennant").font(.zoomed(.headline).weight(.bold)).foregroundStyle(PennantTheme.ink)
            }
            Spacer(minLength: 8)
            if let chat = session.state.mainConversation {
                // What needs you lands in the Pennant chat.
                if !inMainChat { ApprovalsBubble { openConversation(agentID: chat.agentID, conversationID: chat.id) } }
            } else if section != .dashboard {
                // Waiting approvals are dealt with on the dashboard.
                ApprovalsBubble { section = .dashboard }
            }
            if section == nil {
                // The host's model, switchable in place, on the home view too. Right of the title, ahead of
                // the pane's actions.
                let id = selectedAgent.flatMap { session.state.agent($0) != nil ? $0 : nil }
                ModelChip(conversationID: id == nil ? nil : conversationID, agentID: id)
                    .frame(maxWidth: 240)
                    .padding(.trailing, 2)
            }
            if section == nil, let id = selectedAgent, let agent = session.state.agent(id) {
                if !inMainChat {
                    CloseConversationButton(conversationID: $conversationID, iconOnly: true)
                        .buttonStyle(.pennantIcon)
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                }
                if session.state.mainConversation == nil {
                    Button { conversationID = nil } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.pennantIcon)
                        .help("New thread (⌘N)")
                }
                Menu {
                    ConversationMenuItems(agentID: id, conversationID: $conversationID)
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .menuStyle(.button)
                .buttonStyle(.pennantIcon)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Conversations")
                Menu {
                    Button("Edit \(agent.name)…") { editingAgent = agent }
                    Button("See what \(agent.name) sees…") { inspecting = agent }
                    Divider()
                    if agent.kind == .worker {
                        Button("Retire worker", role: .destructive) { retire(agent) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.button)
                .buttonStyle(.pennantIcon)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Edit \(agent.name)")
            }
            Button { showComputer.toggle() } label: {
                Image(systemName: computerSymbol)
                    .foregroundStyle(showComputer ? PennantTheme.ink : PennantTheme.inkSecondary)
            }
            .buttonStyle(.pennantIcon)
            .help(showComputer ? "Hide the side panel" : "Show what needs you and the computer")
        }
        .padding(.leading, columnVisibility == .detailOnly ? 80 : 16)
        .padding(.trailing, 12)
        .frame(height: 46)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    @ViewBuilder private var content: some View {
        if let section {
            Group {
                switch section {
                case .dashboard:
                    DashboardView(onOpenChat: { agentID, conversationID in openConversation(agentID: agentID, conversationID: conversationID) },
                                  onOpenReports: { self.section = .reports }, onOpenApprovals: { self.section = .approvals }, onOpenGoals: { self.section = .goals },
                                  onOpenGoal: { openGoal = $0; self.section = .goals })
                case .approvals: ApprovalsView { agentID, conversationID in openConversation(agentID: agentID, conversationID: conversationID) }
                case .reports: ReportsView { agentID, conversationID in openConversation(agentID: agentID, conversationID: conversationID) }
                case .memory:
                    MemoryView()
                        // A passage opens the conversation it came from.
                        .environment(\.openChat, { [section = $section, conversation = $conversationID, agent = $selectedAgent] id, conversationID in
                            section.wrappedValue = nil
                            conversation.wrappedValue = conversationID
                            agent.wrappedValue = id
                        })
                case .skills: SkillsView()
                case .library: LibraryView()
                case .vault: VaultView()
                case .usage: UsageView()
                case .schedules: SchedulesView { agentID, conversationID in openConversation(agentID: agentID, conversationID: conversationID) }
                case .goals: GoalsView(open: $openGoal) { agentID, conversationID in openConversation(agentID: agentID, conversationID: conversationID) }
                case .connections: ConnectionsView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .navigationTitle(section.title)
        } else if let agentID = selectedAgent, session.state.agent(agentID) != nil {
            ConversationView(agentID: agentID, conversationID: $conversationID)
                // Coding-run rows link to the run's own thread.
                .environment(\.openChat, { [section = $section, conversation = $conversationID, agent = $selectedAgent] id, conversationID in
                    section.wrappedValue = nil
                    conversation.wrappedValue = conversationID
                    agent.wrappedValue = id
                })
                .navigationTitle(session.state.agent(agentID)?.name ?? "Pennant")
                .navigationSubtitle(conversationTitle)
        } else {
            EmptyState(
                title: "Pennant",
                message: session.connection.isConnected ? "Start a thread: ask for anything, or see what your jobs have done." : "Connecting to the host…"
            ) {
                if session.connection.isConnected, let lead = session.state.leadAgent?.id {
                    Button("New thread") { openConversation(agentID: lead, conversationID: nil) }.buttonStyle(.pennantPrimary)
                }
            }
            .navigationTitle("Pennant")
        }
    }

    private var conversationTitle: String {
        guard let id = conversationID, let c = session.state.conversation(id) else { return "New thread" }
        return c.isMain ? (session.state.agent(c.agentID)?.name ?? "Pennant") : conversationLabel(c)
    }

    /// The Pennant chat is on screen.
    private var inMainChat: Bool {
        section == nil && conversationID != nil && conversationID == session.state.mainConversation?.id
    }

    /// Cards and questions waiting on you, for the Pennant row's badge.
    private var needsYouCount: Int {
        let carded = Set(session.state.pendingApprovals.map(\.conversationID))
        let questions = session.state.tasks.filter { $0.state == .waitingForUser && $0.parentTaskID == nil && !carded.contains($0.conversationID) }.count
        return session.state.pendingApprovals.count + questions
    }

    private var computerSymbol: String {
        switch session.state.desktop.owner {
        case .agent: return "desktopcomputer.and.arrow.down"
        case .human: return "desktopcomputer.trianglebadge.exclamationmark"
        case .nobody: return "desktopcomputer"
        }
    }

    /// Opens a conversation (or a fresh one for `nil`) of any agent. The conversation is set first so the
    /// agent change keeps it.
    private func openConversation(agentID: AgentID, conversationID: ConversationID?) {
        section = nil
        self.conversationID = conversationID
        selectedAgent = agentID
    }

    #if DEBUG
    /// Walks the main screens of the demo host (Pennant and its jobs) and saves each, light and dark (see DemoLaunch),
    /// then quits.
    private func takeDemoShots(into folder: URL) async {
        for _ in 0 ..< 60 where !(session.connection.isConnected && !session.state.agents.isEmpty) { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(2))
        // First-run sheets would dim the window; the demo owner doesn't need them.
        permissionsDismissed = true
        accountSetupDismissed = true
        showPermissions = false
        showAccountSetup = false
        showComputer = false
        DemoLaunch.prepareWindow()
        /// The newest thread that matches (a scheduled job's runs are titled "⏰ <job> · <when>").
        func thread(_ matches: (Conversation) -> Bool) -> Conversation? {
            session.state.conversations.filter(matches).sorted { $0.updatedAt > $1.updatedAt }.first
        }
        func open(_ matches: @escaping (Conversation) -> Bool) {
            guard let c = thread(matches) else { return }
            openConversation(agentID: c.agentID, conversationID: c.id)
        }
        func job(_ name: String) -> (Conversation) -> Bool { { $0.title.hasPrefix("⏰ \(name)") && !$0.isClosed } }
        let steps: [(String, () -> Void)] = [
            ("home", { section = .dashboard }),
            ("lead", { open { $0.isMain } }),
            ("coding", { open { $0.isCodingRun } }),
            ("approval", { open(job("Company post")) }),
            ("inbox", { open(job("Inbox drafts")) }),
            ("helpers", { open(job("Product demo")) }),
            ("approvals", { section = .approvals }),
            ("goals", { section = .goals }),
            ("goal", { openGoal = session.state.goals.first { $0.status == .active }?.id }),
            ("memory", { section = .memory }),
            ("reports", { section = .reports }),
            ("usage", { section = .usage }),
            ("schedules", { section = .schedules }),
            ("skills", { section = .skills }),
        ]
        for look in DemoLaunch.appearances {
            NSApp.appearance = NSAppearance(named: look.appearance)
            for (name, go) in steps {
                go()
                try? await Task.sleep(for: .seconds(2.5))
                DemoLaunch.capture(name + look.suffix, into: folder)
            }
            // Settings panes, each in the Settings window.
            for pane in DemoLaunch.settingsPanes {
                UserDefaults.standard.set(pane, forKey: "pennant.settings.pane")
                openSettings()
                try? await Task.sleep(for: .seconds(2.5))
                DemoLaunch.capture("settings-\(pane)" + look.suffix, into: folder, window: NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true })
            }
            NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }?.close()
        }
        // Last, because it changes the demo: the launch post approved, as the card looks once decided (for films).
        open(job("Company post"))
        if let post = thread(job("Company post")), let pending = session.state.pendingApprovals.first(where: { $0.conversationID == post.id }) {
            try? await session.decideApproval(ApprovalDecision(approvalID: pending.request.id, verdict: .approve))
            try? await Task.sleep(for: .seconds(1.2))
            for look in DemoLaunch.appearances {
                NSApp.appearance = NSAppearance(named: look.appearance)
                try? await Task.sleep(for: .seconds(1))
                DemoLaunch.capture("approved" + look.suffix, into: folder)
            }
        }
        // Straight out: the app would otherwise ask before quitting, or linger in the menu bar.
        exit(0)
    }
    #endif

    private func retire(_ agent: AgentProfile) {
        Task { try? await session.retireAgent(agent.id) }
    }

    private var permissionsPromptNeeded: Bool {
        session.connection.isConnected && session.state.host != nil && !session.state.desktop.permissions.allGranted
    }

    private func restartHost() async {
        await session.disconnect()
        await launcher.restartHost(port: session.endpoint.port)
        session.connect()
    }

    /// At launch: the Pennant chat. On a host from before it, the dashboard over the thread that needs you, else the
    /// newest one.
    private func pickDefaultAgent(force: Bool = false) {
        if let chat = session.state.mainConversation {
            guard force || (selectedAgent == nil && section == nil) else { return }
            placedOnChat = true
            section = nil
            conversationID = chat.id
            selectedAgent = chat.agentID
            return
        }
        guard selectedAgent == nil, let lead = session.state.leadAgent?.id else { return }
        if section == nil { section = .dashboard }
        let open = session.state.conversations.filter { !$0.isClosed && $0.parentID == nil && session.state.agent($0.agentID)?.kind == .persistent }
            .sorted { $0.updatedAt > $1.updatedAt }
        let pick = open.first { session.state.conversationNeedsUser($0.id) } ?? open.first
        conversationID = pick?.id
        selectedAgent = pick?.agentID ?? lead
    }
}

/// The Pennant chat in the sidebar: bigger than anything around it and always in the same place, right above the
/// threads, with what needs you counted on it.
private struct PennantChatRow: View {
    @Environment(\.hostSession) private var session
    var chat: Conversation
    var selected: Bool
    var count: Int
    var action: () -> Void
    @State private var hovering = false

    private var working: Bool {
        session.state.tasks.contains { $0.conversationID == chat.id && !$0.state.isTerminal && $0.state != .waitingForUser }
    }

    private var subtitle: String {
        if working { return "Thinking…" }
        if count > 0 { return count == 1 ? "One thing needs you" : "\(count) things need you" }
        let preview = chat.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "Ask for anything" : preview
    }

    var body: some View {
        let agent = session.state.agent(chat.agentID)
        Button(action: action) {
            HStack(spacing: 11) {
                if let agent { AgentAvatar(agent: agent, size: 36) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent?.name ?? "Pennant")
                        .font(.zoomed(.title3).weight(.semibold))
                        .foregroundStyle(PennantTheme.ink)
                    Text(subtitle)
                        .font(.zoomed(.caption))
                        .foregroundStyle(count > 0 ? PennantTheme.brandInk : PennantTheme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.zoomed(.caption).weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(PennantTheme.attention, in: Capsule())
                } else if working {
                    ProgressView().controlSize(.small)
                } else if !selected, session.state.isUnread(chat) {
                    Circle().fill(PennantTheme.info).frame(width: 8, height: 8).help("New since you last looked")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PennantTheme.brand.opacity(selected ? 0.16 : (hovering ? 0.10 : 0.06)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PennantTheme.brand.opacity(selected ? 0.45 : 0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("The Pennant chat (⌘N)")
        .accessibilityIdentifier("pennant-chat")
        .accessibilityLabel("\(agent?.name ?? "Pennant"), \(subtitle)")
    }
}

/// A compact sidebar utility row: icon and label, rounded highlight on hover and when selected.
private struct UtilityRowLabel: View {
    var title: String
    var symbol: String
    var selected: Bool
    /// A count badge (waiting approvals); hidden at zero.
    var count = 0
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.zoomed(size: 13, weight: .medium))
                .foregroundStyle(selected ? PennantTheme.ink : PennantTheme.inkSecondary)
                .frame(width: 18)
            Text(title)
                .font(.zoomed(.callout))
                .foregroundStyle(PennantTheme.ink)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .font(.zoomed(.caption2).weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(PennantTheme.attention, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? PennantTheme.selection : (hovering ? PennantTheme.hover : .clear), in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// Sidebar › More: the sections used now and then, each with a line on what's there, in a panel like the model's.
private struct MorePanel: View {
    enum Choice { case section(SidebarSection), conversations }
    var current: SidebarSection?
    var choose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More").font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SidebarSection.more) { s in
                    row(s.title, Self.detail(s), symbol: s.symbol, selected: current == s) { choose(.section(s)) }
                }
            }
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            row("Conversations", "Every conversation, in a window of its own", symbol: "bubble.left.and.bubble.right", selected: false) { choose(.conversations) }
        }
        .padding(14)
        .frame(width: 320)
        .background(PennantTheme.windowBackground)
    }

    private func row(_ title: String, _ detail: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        SelectableRow(selected: selected, action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                    Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.brandInk).opacity(selected ? 1 : 0)
            }
        }
    }

    static func detail(_ section: SidebarSection) -> String {
        switch section {
        case .library: return "Images, videos and files kept for the work"
        case .vault: return "Keys and passwords Pennant may use"
        case .usage: return "What each model and job has cost"
        case .connections: return "The services Pennant is connected to"
        case .diagnostics: return "How the host is doing"
        case .approvals: return "Every card you've decided"
        default: return ""
        }
    }
}
