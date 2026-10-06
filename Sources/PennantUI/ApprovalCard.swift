import AVKit
import PennantClientKit
import PennantCore
import SwiftUI

/// Something an agent wants to publish, waiting for the user: the images as a carousel, the exact text (editable
/// before approving), the reviewer notes, and Approve / Request changes / Reject. Once decided it shows the outcome,
/// and the live link after publishing.
public struct ApprovalCard: View {
    @Environment(\.hostSession) private var session
    @Environment(\.approvalDecided) private var approvalDecided
    var request: ApprovalRequest
    /// The agent asking; found from the card's task when not given.
    var agentID: AgentID?
    /// Shown as "Open chat" in the header (the Approvals list); nil inside the chat itself.
    var onOpenChat: (() -> Void)?
    public init(request: ApprovalRequest, agentID: AgentID? = nil, onOpenChat: (() -> Void)? = nil) {
        self.request = request
        self.agentID = agentID
        self.onOpenChat = onOpenChat
    }
    @State private var editing = false
    @State private var draft = ""
    @State private var mode: Mode = .idle
    @State private var comment = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showNotes = false
    @State private var showPlain = false
    @State private var zoomed: ImageRef?

    /// How wide a card grows, here and in the chat column.
    static let maxWidth: CGFloat = 740
    /// The card's text size at 100%, for the Markdown it renders.
    #if os(macOS)
    private static let textSize: CGFloat? = Font.TextStyle.callout.macSize
    #else
    private static let textSize: CGFloat? = nil
    #endif

    enum Mode { case idle, requestingChanges, rejecting }

    private var pending: Bool { request.state == .pending }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            titleBlock
            if let video = request.video { ApprovalVideoView(video: video, cover: request.images.first) }
            if let headline = request.headline {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Title").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    Text(headline).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).textSelection(.enabled)
                }
            }
            if !request.images.isEmpty { if request.video != nil { cover } else { carousel } }
            textBlock
            if !request.tags.isEmpty { tagList }
            if !request.details.isEmpty { detailList }
            if !request.notes.isEmpty { notes }
            if let action = request.action, pending { actionLine(action) }
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
            if pending { actions } else { outcome }
        }
        .padding(16)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.border))
        .shadow(color: .black.opacity(pending ? 0.11 : 0.06), radius: pending ? 20 : 12, y: pending ? 10 : 5)
        .sheet(item: $zoomed) { ref in
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Done") { zoomed = nil }.buttonStyle(.pennantCompact) }.padding(10)
                ScrollView { ArtifactImageView(ref: ref).padding() }
            }
            .frame(minWidth: 700, minHeight: 760)
        }
    }

    // MARK: Pieces

    private var agent: AgentProfile? {
        let id = agentID ?? session.state.task(request.taskID)?.agentID
        return id.flatMap { session.state.agent($0) }
    }

    /// Who is asking and when, and where the card stands: the agent's flag and name, the time, a status pill.
    private var header: some View {
        HStack(spacing: 8) {
            if let agent {
                AgentAvatar(agent: agent, size: 24)
                Text(agent.name).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).lineLimit(1)
            }
            Text((agent == nil ? "" : "· ") + relativeTime(request.createdAt))
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
            Spacer(minLength: 6)
            if let onOpenChat {
                Button(action: onOpenChat) { Label("Open chat", systemImage: "arrow.up.right") }
                    .buttonStyle(.pennantGhostCompact)
                    .fixedSize()
            }
            statusPill
        }
    }

    private var statusPill: some View {
        let color = pending ? PennantTheme.color(for: AgentStatus.waitingForUser) : stateColor
        return Text(pending ? "Needs you" : stateTitle)
            .font(.zoomed(.caption).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.title).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink).fixedSize(horizontal: false, vertical: true)
            if !request.destination.isEmpty {
                Label(request.destination, systemImage: "arrow.up.forward")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 10) {
                ForEach(Array(request.images.enumerated()), id: \.offset) { index, ref in
                    ZStack(alignment: .bottomTrailing) {
                        ArtifactThumb(ref: ref)
                            .frame(width: 216, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PennantTheme.border))
                            .onTapGesture { zoomed = ref }
                        Text("\(index + 1)/\(request.images.count)")
                            .font(.zoomed(.caption2).weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// With a video, the images are its cover (a thumbnail), shown at the video's shape.
    private var cover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(request.images.count == 1 ? "Cover" : "Covers").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            HStack(spacing: 10) {
                ForEach(Array(request.images.enumerated()), id: \.offset) { _, ref in
                    ArtifactThumb(ref: ref)
                        .frame(width: 256, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PennantTheme.border))
                        .onTapGesture { zoomed = ref }
                }
            }
        }
    }

    private var tagList: some View {
        FlowLayout(spacing: 6) {
            ForEach(request.tags, id: \.self) { tag in
                Text(tag)
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PennantTheme.cardBackground, in: Capsule())
            }
        }
    }

    private var detailList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Array(request.details.enumerated()), id: \.offset) { _, d in
                    GridRow {
                        Text(d.label).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        Text(d.value).font(.zoomed(.caption)).foregroundStyle(PennantTheme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var textBlock: some View {
        let shown = request.finalText
        let markdown = MarkdownDetector.looksLikeMarkdown(shown)
        if editing {
            TextEditor(text: $draft)
                .font(.zoomed(.callout))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 180)
                .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Group {
                if markdown, !showPlain {
                    PennantMarkdown(shown, size: Self.textSize)
                } else {
                    Text(shown)
                        .font(.zoomed(.callout))
                        .foregroundStyle(PennantTheme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        HStack(spacing: 8) {
            Text("\((editing ? draft : shown).count) characters").font(.zoomed(.caption2).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
            if request.approvedText != nil, !pending { Chip("edited by you") }
            Spacer()
            // Formatted for reading; the plain text is what goes out.
            if markdown, !editing {
                Button(showPlain ? "Show formatted" : "Show plain text") { showPlain.toggle() }
                    .buttonStyle(.pennantGhostCompact)
            }
            if pending {
                Button(editing ? "Done editing" : "Edit text") {
                    if !editing { draft = request.text }
                    editing.toggle()
                }
                .buttonStyle(.pennantGhostCompact)
            }
        }
    }

    /// What approving does, in plain words: the tool and its arguments (the approved text goes in one of them).
    private func actionLine(_ action: ApprovalAction) -> some View {
        // "microsoft_365__mail_reply" → "mail reply"; opaque ids (long values) are left out.
        let raw = action.tool.split(separator: ":").last.map(String.init) ?? action.tool
        let tool = (raw.components(separatedBy: "__").last ?? raw).replacingOccurrences(of: "_", with: " ")
        let args = (action.arguments.objectValue ?? [:]).filter { $0.key != action.textField }
            .sorted { $0.key < $1.key }
            .map { ($0.key.replacingOccurrences(of: "_", with: " "), $0.value.stringValue ?? $0.value.compactText) }
            .filter { $0.1.count <= 40 && UUID(uuidString: $0.1) == nil }
            .map { "\($0.0): \($0.1)" }
        return Label("On approval: \(tool)\(args.isEmpty ? "" : " · " + args.joined(separator: " · ")), with the text above as \(action.textField)", systemImage: "bolt.horizontal.circle")
            .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { showNotes.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.zoomed(.caption).weight(.semibold)).rotationEffect(.degrees(showNotes ? 90 : 0))
                    Text("Why this, and sources").font(.zoomed(.caption).weight(.medium))
                }
                .foregroundStyle(PennantTheme.inkSecondary)
            }
            .buttonStyle(.plain)
            if showNotes {
                PennantMarkdown(request.notes, size: Self.textSize)
            }
        }
    }

    private var approveButton: some View {
        Button {
            decide(.approve)
        } label: {
            let label = request.approveButtonLabel
            Label(editing && draft != request.text ? label.replacingOccurrences(of: "Approve", with: "Approve my edit") : label, systemImage: "checkmark")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pennantPrimary)
        .disabled(busy)
    }

    /// "Allow for the rest of this task": approves this and what comes next of the same kind.
    @ViewBuilder private var allowRestButton: some View {
        if let label = request.allowRestLabel {
            Button { decide(.approveRest) } label: {
                Label(label, systemImage: "checkmark.circle").lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .buttonStyle(.pennantSecondary)
            .disabled(busy)
        }
    }

    private var changesButton: some View {
        Button { mode = .requestingChanges } label: { Text("Request changes").lineLimit(1).frame(maxWidth: .infinity) }
            .buttonStyle(.pennantSecondary).disabled(busy)
    }

    private var rejectButton: some View {
        Button(role: .destructive) { mode = .rejecting } label: {
            Text("Reject").lineLimit(1).frame(maxWidth: .infinity).foregroundStyle(PennantTheme.danger)
        }
        .buttonStyle(.pennantSecondary).disabled(busy)
    }

    /// One tap for the usual notes; the field is for anything else. Choices before typing.
    private var quickNotes: [String] {
        mode == .rejecting
            ? ["Off-topic", "Wrong timing", "Not our voice", "Already handled"]
            : ["Shorter", "Warmer", "More formal", "Add the numbers", "Different angle", "Check the facts"]
    }

    private func toggleNote(_ note: String) {
        var parts = comment.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare(note) == .orderedSame }) { parts.remove(at: i) } else { parts.append(note) }
        comment = parts.joined(separator: "; ")
    }

    @ViewBuilder private var actions: some View {
        switch mode {
        case .idle:
            // One row when it fits (the Mac), stacked full-width buttons on a phone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    approveButton.fixedSize()
                    allowRestButton.fixedSize()
                    changesButton.fixedSize()
                    rejectButton.fixedSize()
                    Spacer(minLength: 0)
                }
                VStack(spacing: 8) {
                    approveButton.frame(maxWidth: .infinity)
                    allowRestButton.frame(maxWidth: .infinity)
                    changesButton.frame(maxWidth: .infinity)
                    rejectButton.frame(maxWidth: .infinity)
                }
            }
        case .requestingChanges, .rejecting:
            VStack(alignment: .leading, spacing: 8) {
                Text(mode == .rejecting ? "Why not? (optional)" : "What should change?").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                FlowLayout(spacing: 6) {
                    ForEach(quickNotes, id: \.self) { note in
                        let on = comment.localizedCaseInsensitiveContains(note)
                        Button { toggleNote(note) } label: {
                            Text(note)
                                .font(.zoomed(.caption).weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(on ? PennantTheme.ink : PennantTheme.fieldBackground, in: Capsule())
                                .foregroundStyle(on ? PennantTheme.windowBackground : PennantTheme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
                PennantTextField("Anything else", placeholder: mode == .rejecting ? "Off-topic for us this week" : "Shorter, and lead with the incident, not the stat", text: $comment, lines: 1 ... 4)
                HStack(spacing: 8) {
                    Button(mode == .rejecting ? "Reject" : "Send back") { decide(mode == .rejecting ? .reject : .requestChanges) }
                        .buttonStyle(mode == .rejecting ? .pennantDestructive : .pennantPrimary)
                        .disabled(busy || (mode == .requestingChanges && comment.trimmingCharacters(in: .whitespaces).isEmpty))
                    Button("Cancel") { mode = .idle; comment = "" }.buttonStyle(.pennantGhost)
                }
            }
        }
    }

    private var outcome: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: stateSymbol).foregroundStyle(stateColor)
                Text(stateTitle).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(stateColor)
                // On a shared host, who decided it.
                if let by = request.decidedBy, by.id != (session.state.me?.id ?? PersonID("owner")) {
                    Text("by \(by.name)").font(.zoomed(.caption).weight(.medium)).foregroundStyle(PennantTheme.inkSecondary)
                }
                if let at = request.decidedAt { Text(at.formatted(date: .abbreviated, time: .shortened)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary) }
            }
            if let comment = request.comment, !comment.isEmpty {
                Text(comment).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            }
            if let live = request.publishedURL, let url = URL(string: live) {
                Link(destination: url) { Label("View the live post", systemImage: "arrow.up.right.square") }.font(.zoomed(.callout))
            } else if request.action != nil, request.state == .approved {
                if let result = request.actionResult {
                    Label(result, systemImage: request.actionFailed == true ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.zoomed(.caption)).foregroundStyle(request.actionFailed == true ? PennantTheme.danger : PennantTheme.success)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Sending…").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                }
            } else if request.state == .approved {
                Text("Publishing…").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stateColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var stateTitle: String {
        switch request.state {
        case .pending: return "Pending"
        case .approved:
            if request.action != nil, let failed = request.actionFailed { return failed ? "Approved · not sent" : "Sent" }
            return request.publishedURL == nil ? "Approved" : "Published"
        case .changesRequested: return "Changes requested"
        case .rejected: return request.replacedBy == nil ? "Rejected" : "Replaced"
        }
    }

    private var stateColor: Color {
        switch request.state {
        case .approved: return request.actionFailed == true ? PennantTheme.danger : PennantTheme.success
        case .changesRequested: return PennantTheme.warning
        case .rejected: return request.replacedBy == nil ? PennantTheme.danger : PennantTheme.inkSecondary
        case .pending: return PennantTheme.brandInk
        }
    }

    private var stateSymbol: String {
        switch request.state {
        case .approved: return request.publishedURL == nil ? "checkmark.seal.fill" : "paperplane.fill"
        case .changesRequested: return "arrow.uturn.backward.circle"
        case .rejected: return request.replacedBy == nil ? "xmark.seal" : "arrow.triangle.2.circlepath"
        case .pending: return "checkmark.seal"
        }
    }

    private func decide(_ verdict: ApprovalDecision.Verdict) {
        busy = true
        error = nil
        let edited = editing && draft != request.text ? draft : nil
        let decision = ApprovalDecision(approvalID: request.id, verdict: verdict, editedText: verdict == .approve || verdict == .approveRest ? edited : nil, comment: comment.nilIfEmpty)
        Task {
            defer { busy = false }
            do {
                try await session.decideApproval(decision)
                approvalDecided?(request, verdict)
                mode = .idle
                editing = false
            } catch {
                if case HostSessionError.hostError(_, let message) = error { self.error = message } else { self.error = String(describing: error) }
            }
        }
    }
}

/// The video on an approval card: the poster until the preview has arrived, then a player.
struct ApprovalVideoView: View {
    @Environment(\.hostSession) private var session
    var video: ApprovalVideo
    /// The video's cover (thumbnail), shown before playing instead of the extracted frame.
    var cover: ImageRef? = nil
    @State private var player: AVPlayer?
    @State private var failed: String?
    /// The player replaces the poster once the user presses play (a paused player shows only its first frame,
    /// which for most videos is a dark fade-in).
    @State private var started = false

    var body: some View {
        // A fixed-shape frame the content fills and is clipped to, whatever the poster's own shape.
        Color.black
            .aspectRatio(CGFloat(max(video.width, 1)) / CGFloat(max(video.height, 1)), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Text(Self.duration(video.durationSeconds) + " · \(video.width)×\(video.height)")
                    .font(.zoomed(.caption2).weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
                    .allowsHitTesting(false)
            }
            .onAppear { ArtifactCache.shared.loadFile(video.preview.artifactID, using: session) }
            .onChange(of: stateKey) { prepare() }
            .task { prepare() }
            .onDisappear { player?.pause() }
    }

    @ViewBuilder private var content: some View {
        ZStack {
            if let player, started {
                PlatformVideoPlayer(player: player)
            } else if player != nil {
                if let still = cover ?? video.poster { ArtifactThumb(ref: still) } else { PennantTheme.cardBackground }
                Button {
                    started = true
                    player?.play()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.zoomed(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play video")
            } else {
                if let poster = video.poster { ArtifactThumb(ref: poster) } else { PennantTheme.cardBackground }
                VStack(spacing: 6) {
                    if let failed {
                        Text(failed).font(.zoomed(.caption)).foregroundStyle(.white)
                        Button("Retry") { self.failed = nil; ArtifactCache.shared.reloadFile(video.preview.artifactID, using: session) }.buttonStyle(.pennantCompact)
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Loading preview…").font(.zoomed(.caption)).foregroundStyle(.white)
                    }
                }
                .padding(10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var stateKey: String {
        switch ArtifactCache.shared.file(for: video.preview.artifactID) {
        case .loaded: return "loaded"
        case .failed(let m): return "failed:" + m
        case .loading: return "loading"
        case nil: return "none"
        }
    }

    private func prepare() {
        guard player == nil else { return }
        switch ArtifactCache.shared.file(for: video.preview.artifactID) {
        case .loaded(let data):
            // AVPlayer plays files, so the preview goes to the caches folder once.
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PennantVideos", isDirectory: true)
            let file = folder.appendingPathComponent("\(video.preview.artifactID.rawValue).mp4")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
                player = AVPlayer(url: file)
            } catch {
                failed = "Couldn’t open the preview."
            }
        case .failed:
            failed = "Couldn’t load the preview."
        default:
            break
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The system player: AppKit's AVPlayerView on the Mac (controls inline), AVKit's SwiftUI player on iOS.
struct PlatformVideoPlayer: View {
    var player: AVPlayer
    var body: some View {
        #if os(macOS)
        MacPlayerView(player: player)
        #else
        VideoPlayer(player: player)
        #endif
    }
}

#if os(macOS)
struct MacPlayerView: NSViewRepresentable {
    var player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif

/// An artifact image cropped to fill its frame (a carousel slide).
struct ArtifactThumb: View {
    @Environment(\.hostSession) private var session
    var ref: ImageRef
    var body: some View {
        Group {
            if let img = ArtifactCache.shared.image(for: ref.artifactID) {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack { PennantTheme.cardBackground; ProgressView().controlSize(.small) }
            }
        }
        .onAppear { ArtifactCache.shared.load(ref.artifactID, using: session) }
    }
}

extension ImageRef: Identifiable {
    public var id: ArtifactID { artifactID }
}
