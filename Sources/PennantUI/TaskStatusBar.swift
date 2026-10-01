import PennantClientKit
import PennantCore
import SwiftUI

/// One slim line above the composer while a task is active: a pulsing dot, the state, the reason,
/// and pause / resume / cancel on the right.
public struct TaskStatusBar: View {
    @Environment(\.hostSession) private var session
    var task: TaskRecord
    @State private var busy = false
    @State private var error: String?

    public init(task: TaskRecord) { self.task = task }

    private var detail: String {
        if !task.stateReason.isEmpty { return task.stateReason }
        return task.title
    }

    /// A rate-limit pause resumes by itself; the host says after how long, counted from when it paused.
    private var resumesAt: Date? {
        guard task.state == .paused, let m = task.stateReason.firstMatch(of: /Resuming by itself in (\d+) min/), let n = Double(m.1) else { return nil }
        return task.updatedAt.addingTimeInterval(n * 60)
    }

    /// The agent stopped because you took the mouse or paused the computer.
    private var tookOver: Bool {
        task.state == .paused && (task.stateReason.contains("took control of the computer") || task.stateReason.contains("Computer use paused by the user"))
    }

    public var body: some View {
        HStack(spacing: 10) {
            if tookOver {
                Image(systemName: "hand.raised.fill").font(.zoomed(size: 12)).foregroundStyle(PennantTheme.warning)
                Text("You took over · agent paused").font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
            } else if let resumesAt {
                Image(systemName: "pause.circle.fill").font(.zoomed(size: 12)).foregroundStyle(PennantTheme.warning)
                Text("Rate limited").font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                TimelineView(.periodic(from: Clock.anchor, by: 1)) { context in
                    let left = max(0, Int(resumesAt.timeIntervalSince(context.date).rounded()))
                    Text(left > 0 ? "resumes in \(left / 60):\(String(format: "%02d", left % 60))" : "resuming…")
                        .font(.zoomed(.callout).monospacedDigit())
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .contentTransition(.numericText(countsDown: true))
                }
            } else {
                StatusDot(color: PennantTheme.color(for: task.state), pulsing: task.state.isActive)
                Text(PennantTheme.label(for: task.state))
                    .font(.zoomed(.callout).weight(.medium))
                    .foregroundStyle(PennantTheme.ink)
                    .lineLimit(1)
            }
            if !detail.isEmpty, !tookOver, resumesAt == nil {
                Text(detail)
                    .font(.zoomed(.callout))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(ShellPalette.danger).lineLimit(1).layoutPriority(-1)
            }
            // Counts up as the agent works.
            let tokens = task.usage.inputTokens + task.usage.outputTokens
            Text(tokens > 0 ? "\(task.usage.steps) steps · \(WorkersCard.tokens(tokens))" : "\(task.usage.steps) steps")
                .font(.zoomed(.caption))
                .monospacedDigit()
                .foregroundStyle(PennantTheme.inkTertiary)
                .contentTransition(.numericText())
                .animation(.snappy, value: tokens)
                .fixedSize()
            if !task.state.isTerminal {
                // Titles when there is room, icons alone on a phone; never let a label wrap letter by letter.
                ViewThatFits(in: .horizontal) {
                    controls(iconOnly: false)
                    controls(iconOnly: true)
                }
                .fixedSize()
            }
        }
        .disabled(busy)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(PennantTheme.panelBackground, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
    }

    @ViewBuilder private func controls(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            if task.state == .paused {
                Button {
                    run { try await session.resumeTask(task.id) }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.pennantCompact)
                .help("Resume")
            } else {
                Button {
                    run { try await session.pauseTask(task.id) }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.pennantCompact)
                .help("Pause")
            }
            Button {
                run { try await session.cancelTask(task.id) }
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(PennantButtonStyle(.ghost, compact: true))
            .help("Cancel")
        }
        .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        .fixedSize()
    }

    private func run(_ op: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await op() } catch { self.error = String(describing: error) }
        }
    }
}

/// Type-erased label style so a `ViewThatFits` branch can pick titles or icons.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

