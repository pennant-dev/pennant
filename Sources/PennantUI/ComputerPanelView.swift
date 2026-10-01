import PennantClientKit
import PennantCore
import SwiftUI

/// Live view of the host desktop with pause, takeover, and remote input, then the routines the host runs
/// and what the agent on the desktop is doing. Subscribes to the screen stream while visible and
/// unsubscribes when it disappears.
public struct ComputerPanelView: View {
    @Environment(\.hostSession) private var session
    var compact: Bool
    @State private var actionError: String?
    @State private var keyboardVisible = false
    @State private var keyboardBuffer = ""
    @State private var streamOptions = ScreenStreamOptions()
    @State private var quality: StreamQuality = .standard

    public init(compact: Bool = false) { self.compact = compact }

    private var desktop: DesktopStatus { session.state.desktop }
    private var humanHasControl: Bool { if case .human = desktop.owner { return true }; return false }

    public var body: some View {
        #if os(macOS)
        ScrollView { content }
            .background(PennantTheme.panelBackground)
        #else
        // The iPhone tab already scrolls; nesting a second scroll view would fight it.
        content
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                screenCard
                caption
            }
            .frame(maxWidth: .infinity)
            controls
            if humanHasControl { remoteKeyboard }
            if let actionError {
                Text(actionError).font(.zoomed(.caption)).foregroundStyle(InspectorTint.danger).lineLimit(2)
            }
            routines
            activity
        }
        .padding(compact ? 10 : 16)
        // New frames redraw only the screen (LiveScreen), not the rest of the panel. Nobody on the computer: this
        // Mac's own screen needs no live copy (the last frame stays), another Mac's gets one frame a second; an agent
        // or you at the controls gets the chosen quality.
        .onChange(of: quality) { _, _ in resubscribe() }
        .task(id: streamPaused) {
            if streamPaused {
                await session.stopWatchingScreen()
            } else {
                streamOptions = effectiveOptions
                await session.watchScreen(streamOptions)
            }
        }
        .task(id: desktopIdle) { if !streamPaused { resubscribe() } }
        .task {
            if session.state.schedules.isEmpty { try? await session.loadSchedules() }
        }
        .onDisappear {
            Task { await session.stopWatchingScreen() }
        }
    }

    // MARK: Screen

    private var desktopIdle: Bool { if case .nobody = desktop.owner { return true }; return false }

    /// The host is this Mac and nobody is on it: you're looking at the real screen, so no stream.
    private var streamPaused: Bool {
        #if os(macOS)
        return desktopIdle && session.endpoint.isLoopback
        #else
        return false
        #endif
    }

    private var effectiveOptions: ScreenStreamOptions {
        guard desktopIdle else { return quality.options }
        var idle = StreamQuality.low.options
        idle.framesPerSecond = 1
        return idle
    }

    private func resubscribe() {
        streamOptions = effectiveOptions
        let options = streamOptions
        Task { try? await session.subscribeScreen(options) }
    }

    private var placeholderText: String {
        if !session.connection.isConnected { return "Not connected" }
        if streamPaused { return "The live view starts when Pennant uses the computer." }
        if !desktop.permissions.screenRecording { return "Screen Recording permission is not granted on the host" }
        return "Waiting for the first frame…"
    }

    private var waitingForFrame: Bool { session.connection.isConnected && desktop.permissions.screenRecording && !streamPaused }

    /// The live frame on a grey mat inside a rounded card with a thin border and a soft shadow.
    private var screenCard: some View {
        LiveScreen(interactive: humanHasControl, live: !streamPaused,
                   fallbackRatio: desktop.displayHeight > 0 ? CGFloat(desktop.displayWidth) / CGFloat(desktop.displayHeight) : 16.0 / 10.0,
                   placeholder: { placeholder }) { input in Task { await sendInput(input) } }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous)
                .fill(PennantTheme.cardBackground)
                .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).stroke(PennantTheme.border))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "display").font(.zoomed(size: 26, weight: .light)).foregroundStyle(PennantTheme.inkTertiary)
            Text(placeholderText).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).multilineTextAlignment(.center)
            if waitingForFrame { ProgressView().controlSize(.small) }
        }
        .padding(16)
    }

    /// "Chief of Staff's screen" under the card, with status chips only when there is status to show.
    private var caption: some View {
        VStack(spacing: 6) {
            Text(captionText).font(.zoomed(.subheadline)).foregroundStyle(PennantTheme.inkSecondary)
            if desktop.pausedByHuman || !desktop.queue.isEmpty || frontmostApp != nil {
                HStack(spacing: 6) {
                    if desktop.pausedByHuman { Chip("Paused", color: InspectorTint.paused) }
                    if !desktop.queue.isEmpty { Chip("\(desktop.queue.count) waiting", color: InspectorTint.warning) }
                    if let frontmostApp { Chip(frontmostApp) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var frontmostApp: String? {
        guard let app = desktop.frontmostApp?.trimmingCharacters(in: .whitespaces), !app.isEmpty else { return nil }
        return app
    }

    private var captionText: String {
        switch desktop.owner {
        case .agent(let agentID, _):
            let name = session.state.agent(agentID)?.name ?? "An agent"
            return "\(name)’s screen"
        case .human:
            return "Your screen"
        case .nobody:
            return "Nobody is using the screen"
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if desktop.pausedByHuman {
                Button { run { try await session.resumeDesktop() } } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(.pennantCompact)
            } else {
                Button { run { try await session.pauseDesktop() } } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(.pennantCompact)
            }
            if humanHasControl {
                Button { run { try await session.releaseDesktop() } } label: { Label("Release", systemImage: "hand.raised.slash") }
                    .buttonStyle(.pennantCompact)
            } else {
                Button { run { try await session.takeoverDesktop() } } label: { Label("Take over", systemImage: "hand.raised.fill") }
                    .buttonStyle(.pennantPrimaryCompact)
            }
            Spacer(minLength: 0)
            #if !os(macOS)
            if humanHasControl {
                Button { keyboardVisible.toggle() } label: { Image(systemName: "keyboard") }
                    .buttonStyle(IconButtonStyle(filled: keyboardVisible))
                    .help("Keyboard")
                    .accessibilityLabel("Keyboard")
            }
            #endif
            Button { run { try await session.setPauseOnHumanInput(!desktop.pauseOnHumanInput) } } label: { Image(systemName: "hand.tap") }
                .buttonStyle(IconButtonStyle(filled: desktop.pauseOnHumanInput))
                .help("Pause the agent when you use the mouse or keyboard")
                .accessibilityLabel("Pause on input")
                .accessibilityValue(desktop.pauseOnHumanInput ? "On" : "Off")
            Menu {
                ForEach(StreamQuality.allCases) { q in
                    Button {
                        quality = q
                    } label: {
                        if q == quality { Label(q.title, systemImage: "checkmark") } else { Text(q.title) }
                        Text(q.detail)
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.button)
            .buttonStyle(.pennantIcon)
            .menuIndicator(.hidden)
            .help("Stream quality")
            .accessibilityLabel("Stream quality")
        }
    }

    @ViewBuilder private var remoteKeyboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            Text("Click the screen, then type. Keys and shortcuts are sent to the host.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            #else
            if keyboardVisible {
                TextField("Type to send keystrokes", text: $keyboardBuffer)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .pennantField()
                    .onChange(of: keyboardBuffer) { old, new in
                        if new.count > old.count, new.hasPrefix(old) {
                            let added = String(new.dropFirst(old.count))
                            Task { await sendInput(.typeText(added)) }
                        } else if new.count < old.count {
                            for _ in 0 ..< (old.count - new.count) { Task { await sendInput(.key(KeyChord(key: "delete"))) } }
                        }
                    }
                    .onSubmit {
                        Task { await sendInput(.key(KeyChord(key: "return"))) }
                        keyboardBuffer = ""
                    }
            }
            #endif
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(specialKeys, id: \.0) { label, chord in
                        Button(label) { Task { await sendInput(.key(KeyChord(parsing: chord))) } }
                            .buttonStyle(.pennantCompact)
                    }
                }
            }
        }
    }

    private var specialKeys: [(String, String)] {
        [("⎋", "escape"), ("⇥", "tab"), ("⏎", "return"), ("⌫", "delete"), ("↑", "up"), ("↓", "down"), ("←", "left"), ("→", "right"),
         ("⌘Z", "cmd+z"), ("⌘C", "cmd+c"), ("⌘V", "cmd+v"), ("⌘S", "cmd+s"), ("⌘W", "cmd+w"), ("⌘Tab", "cmd+tab"), ("⌘Space", "cmd+space"), ("Page↑", "pageup"), ("Page↓", "pagedown")]
    }

    // MARK: Routines and activity

    /// Enabled jobs first, soonest next run first, then by name.
    private var routineJobs: [ScheduledJob] {
        session.state.schedules.sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            let na = a.nextRunAt ?? .distantFuture, nb = b.nextRunAt ?? .distantFuture
            if na != nb { return na < nb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var routines: some View {
        InspectorSection("Routines") {
            if routineJobs.isEmpty {
                Text("No routines yet.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkTertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(routineJobs) { job in RoutineRow(job: job) }
                }
            }
        }
    }

    @ViewBuilder private var activity: some View {
        if case .agent(let agentID, let taskID) = desktop.owner {
            let task = session.state.task(taskID)
            InspectorSection("Activity") {
                HStack(alignment: .top, spacing: 10) {
                    if let agent = session.state.agent(agentID) { AgentAvatar(agent: agent, size: 28) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activityTitle(task)).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                        if let task {
                            Chip(PennantTheme.label(for: task.state), color: PennantTheme.color(for: task.state))
                            if !task.stateReason.isEmpty {
                                Text(task.stateReason).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(3)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .card(elevated: true)
            }
        }
    }

    private func activityTitle(_ task: TaskRecord?) -> String {
        if let task, !task.title.isEmpty { return task.title }
        return "Using the computer"
    }

    // MARK: Plumbing

    private func run(_ op: @escaping () async throws -> Void) {
        actionError = nil
        Task { do { try await op() } catch { actionError = String(describing: error) } }
    }

    private func sendInput(_ input: RemoteInput) async {
        do { try await session.sendRemoteInput(input) } catch { actionError = String(describing: error) }
    }
}

/// One routine: a status glyph, the name, and a friendly schedule line. Hover shows the prompt.
private struct RoutineRow: View {
    var job: ScheduledJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph.symbol)
                .font(.zoomed(size: 13, weight: .medium))
                .foregroundStyle(glyph.tint)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(scheduleLabel(job.name)).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                Text(InspectorSchedulePhrase.line(for: job)).font(.zoomed(.subheadline)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(job.prompt.isEmpty ? job.name : job.prompt)
    }

    // Pause when disabled; otherwise the last outcome decides, and a plain clock means "scheduled".
    private var glyph: (symbol: String, tint: Color) {
        guard job.enabled else { return ("pause.circle", PennantTheme.inkTertiary) }
        let outcome = (job.lastOutcome ?? "").lowercased()
        if outcome.contains("fail") { return ("exclamationmark.circle", InspectorTint.danger) }
        if outcome.hasPrefix("ok") || outcome.hasPrefix("completed") { return ("checkmark.circle", InspectorTint.success) }
        return ("clock", PennantTheme.inkSecondary)
    }
}

/// Stream presets. Standard is the host default; the others trade frame rate and size for bandwidth.
private enum StreamQuality: String, CaseIterable, Identifiable {
    case low, standard, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .standard: return "Standard"
        case .high: return "High"
        }
    }

    var detail: String {
        switch self {
        case .low: return "3 fps, 960 px"
        case .standard: return "6 fps, 1440 px"
        case .high: return "10 fps, 1920 px"
        }
    }

    var options: ScreenStreamOptions {
        switch self {
        case .low: return ScreenStreamOptions(framesPerSecond: 3, maxWidth: 960, jpegQuality: 0.45)
        case .standard: return ScreenStreamOptions()
        case .high: return ScreenStreamOptions(framesPerSecond: 10, maxWidth: 1920, jpegQuality: 0.75)
        }
    }
}

/// The frame image with pointer mapping. Coordinates sent to the host are normalised 0...1.
public struct ScreenImageView: View {
    var image: PlatformImage
    var interactive: Bool
    var onInput: (RemoteInput) -> Void

    public init(image: PlatformImage, interactive: Bool, onInput: @escaping (RemoteInput) -> Void) {
        self.image = image
        self.interactive = interactive
        self.onInput = onInput
    }

    @State private var dragging = false
    @State private var dragStart: CGPoint?
    @State private var lastClickAt: Date = .distantPast
    @State private var lastClickPoint: CGPoint = .zero
    @FocusState private var focused: Bool

    public var body: some View {
        #if os(iOS)
        RemoteScreenUIView(image: image, interactive: interactive, onInput: onInput)
            .overlay(alignment: .top) {
                if interactive {
                    Text("Live control")
                        .font(.zoomed(.caption2).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.72), in: Capsule())
                        .padding(8)
                }
            }
        #else
        GeometryReader { geo in
            let rect = fittedRect(in: geo.size)
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay {
                    if interactive {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(pointerGesture(rect: rect))
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).sequenced(before: DragGesture(minimumDistance: 0)).onEnded { value in
                                if case .second(true, let drag?) = value, let p = normalise(drag.location, in: rect) {
                                    onInput(.click(x: p.x, y: p.y, button: .right, count: 1))
                                }
                            })
                            #if os(macOS)
                            .focusable()
                            .focused($focused)
                            .onKeyPress(phases: .down) { press in handleKey(press) }
                            .onTapGesture { focused = true }
                            #endif
                    }
                }
                .overlay(alignment: .top) {
                    if interactive {
                        Text(focused || !isMac ? "Live control" : "Click to focus for keyboard input")
                            .font(.zoomed(.caption2).weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.72), in: Capsule())
                            .padding(8)
                    }
                }
        }
        #endif
    }

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / imgSize.width, size.height / imgSize.height)
        let w = imgSize.width * scale, h = imgSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func normalise(_ p: CGPoint, in rect: CGRect) -> (x: Double, y: Double)? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (p.x - rect.minX) / rect.width
        let y = (p.y - rect.minY) / rect.height
        guard (0 ... 1).contains(x), (0 ... 1).contains(y) else { return nil }
        return (Double(x), Double(y))
    }

    private func pointerGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
                let moved = hypot(value.translation.width, value.translation.height)
                if !dragging, moved > 4, let s = dragStart, let p = normalise(s, in: rect) {
                    dragging = true
                    onInput(.pointerDown(x: p.x, y: p.y, button: .left))
                }
                if dragging, let p = normalise(value.location, in: rect) {
                    onInput(.pointerMove(x: p.x, y: p.y))
                }
            }
            .onEnded { value in
                defer { dragging = false; dragStart = nil }
                guard let p = normalise(value.location, in: rect) else { return }
                if dragging {
                    onInput(.pointerUp(x: p.x, y: p.y, button: .left))
                } else {
                    let now = Date()
                    let near = hypot(value.location.x - lastClickPoint.x, value.location.y - lastClickPoint.y) < 6
                    let count = (now.timeIntervalSince(lastClickAt) < 0.35 && near) ? 2 : 1
                    lastClickAt = now
                    lastClickPoint = value.location
                    onInput(.click(x: p.x, y: p.y, button: .left, count: count))
                }
            }
    }

    #if os(macOS)
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        var chord = KeyChord(key: "")
        chord.command = press.modifiers.contains(.command)
        chord.shift = press.modifiers.contains(.shift)
        chord.option = press.modifiers.contains(.option)
        chord.control = press.modifiers.contains(.control)
        let special: [KeyEquivalent: String] = [
            .return: "return", .escape: "escape", .tab: "tab", .space: "space", .delete: "delete", .deleteForward: "forwarddelete",
            .upArrow: "up", .downArrow: "down", .leftArrow: "left", .rightArrow: "right", .home: "home", .end: "end", .pageUp: "pageup", .pageDown: "pagedown",
        ]
        if let name = special[press.key] {
            chord.key = name
            onInput(.key(chord))
            return .handled
        }
        let chars = press.characters
        guard !chars.isEmpty else { return .ignored }
        if chord.command || chord.control || (chord.option && chars.unicodeScalars.allSatisfy { $0.isASCII }) {
            chord.key = chars.lowercased()
            onInput(.key(chord))
        } else {
            onInput(.typeText(chars))
        }
        return .handled
    }
    #endif
}

/// The live frame on its grey mat. It alone watches the stream, so a new frame redraws this and nothing else.
private struct LiveScreen<Placeholder: View>: View {
    @Environment(\.hostSession) private var session
    var interactive: Bool
    /// False while the stream is paused: the last frame stays, dimmed, without a "stale" badge.
    var live: Bool = true
    var fallbackRatio: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder
    var onInput: (RemoteInput) -> Void
    @State private var decoded: (seq: Int64, image: PlatformImage)?

    var body: some View {
        let frame = session.state.screenFrame
        ZStack {
            RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous).fill(PennantTheme.fieldBackground)
            if let decoded {
                ScreenImageView(image: decoded.image, interactive: interactive, onInput: onInput)
                    .opacity(live ? 1 : 0.55)
                    .overlay(alignment: .bottomTrailing) {
                        if live { StaleBadge(timestamp: frame?.header.timestamp) } else { Chip("Paused while nobody's on the computer").padding(6) }
                    }
            } else {
                placeholder()
            }
        }
        .aspectRatio(frame.map { $0.header.height > 0 ? CGFloat($0.header.width) / CGFloat($0.header.height) : fallbackRatio } ?? fallbackRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        .onChange(of: frame?.header.sequence, initial: true) { _, _ in decode() }
    }

    private func decode() {
        guard let frame = session.state.screenFrame else { decoded = nil; return }
        if decoded?.seq == frame.header.sequence { return }
        if let img = PlatformImage(data: frame.jpeg) { decoded = (frame.header.sequence, img) }
    }
}

/// "Stale 12s" when the last frame is more than three seconds old.
private struct StaleBadge: View {
    var timestamp: Date?
    var body: some View {
        TimelineView(.periodic(from: Clock.anchor, by: 1)) { ctx in
            if let t = timestamp, ctx.date.timeIntervalSince(t) > 3 {
                Chip("Stale \(Int(ctx.date.timeIntervalSince(t)))s", color: InspectorTint.warning).padding(6)
            }
        }
    }
}
