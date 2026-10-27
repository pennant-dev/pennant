import PennantClientKit
import PennantCore
import SwiftUI

/// One quiet line above the composer while work goes on: what Pennant is working on, and Stop. Paused work offers
/// Resume; pausing is in the line's menu. Steps and tokens are in its tooltip.
public struct TaskStatusBar: View {
    @Environment(\.hostSession) private var session
    var task: TaskRecord
    @State private var busy = false
    @State private var error: String?

    public init(task: TaskRecord) { self.task = task }

    /// What the work is: the task's title, without the marks older hosts put on scheduled runs.
    private var title: String { TitleMarks.strip(task.title) }

    /// Where it stands, when that says more than the title.
    private var detail: String? {
        let reason = task.stateReason.trimmingCharacters(in: .whitespaces)
        // A bare state ("Working") says nothing the line doesn't.
        let states = Set(TaskState.allCases.map { PennantTheme.label(for: $0).lowercased() } + ["working", "running", "started", "resumed"])
        guard !reason.isEmpty, reason != task.title, !states.contains(reason.lowercased()), !reason.hasPrefix("Waiting for your approval") else { return nil }
        return reason
    }

    /// The step it's on, in plain words, and since when.
    private var step: (phrase: String, since: Date)? {
        WorkStep.current(task, records: session.state.toolRecords[task.id] ?? [], naming: .from(session.state))
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

    /// The line's words: "Working on Inbox drafts", "Paused · Inbox drafts".
    private var headline: String {
        switch task.state {
        case .queued: return "Up next: \(title)"
        case .paused: return tookOver ? "You took over" : "Paused · \(title)"
        case .waitingForUser: return "Waiting for you · \(title)"
        case .waitingForDesktop: return "Waiting for the computer · \(title)"
        case .failed: return "Didn't finish · \(title)"
        default: return "Working on \(title)"
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Group {
                if tookOver {
                    Image(systemName: "hand.raised.fill").foregroundStyle(PennantTheme.warning)
                } else if task.state == .paused {
                    Image(systemName: "pause.circle.fill").foregroundStyle(PennantTheme.warning)
                } else if task.state == .failed {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PennantTheme.danger)
                } else if task.state == .waitingForUser {
                    StatusDot(color: PennantTheme.attention, pulsing: false)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                }
            }
            .font(.zoomed(size: 12))
            .frame(width: 16, height: 16)
            Text(headline)
                .font(.zoomed(.callout).weight(.semibold))
                .foregroundStyle(PennantTheme.ink)
                .lineLimit(1)
                .layoutPriority(1)
            if let resumesAt {
                TimelineView(.periodic(from: Clock.anchor, by: 1)) { context in
                    let left = max(0, Int(resumesAt.timeIntervalSince(context.date).rounded()))
                    Text(left > 0 ? "· resumes in \(left / 60):\(String(format: "%02d", left % 60))" : "· resuming…")
                        .font(.zoomed(.callout).monospacedDigit())
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .contentTransition(.numericText(countsDown: true))
                }
            } else if let step {
                WorkStepLabel(phrase: step.phrase, since: step.since)
            } else if let detail, !tookOver {
                Text("· \(detail)")
                    .font(.zoomed(.callout))
                    .foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(ShellPalette.danger).lineLimit(1).layoutPriority(-1)
            }
            if !task.state.isTerminal {
                if task.state == .paused {
                    Button("Resume") { run { try await session.resumeTask(task.id) } }
                        .buttonStyle(.pennantCompact)
                }
                Button {
                    run { try await session.cancelTask(task.id) }
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.pennantCompact)
                .help("Stop this work")
            }
        }
        .disabled(busy)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(PennantTheme.panelBackground, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).strokeBorder(PennantTheme.border))
        .help(stepsAndTokens)
        .contextMenu {
            if task.state.isActive, task.state != .paused {
                Button("Pause") { run { try await session.pauseTask(task.id) } }
            }
            if task.state == .paused { Button("Resume") { run { try await session.resumeTask(task.id) } } }
            if !task.state.isTerminal { Button("Stop", role: .destructive) { run { try await session.cancelTask(task.id) } } }
        }
        .animation(.easeOut(duration: 0.2), value: task.state)
    }

    /// "12 steps · 48k tokens", for the curious.
    private var stepsAndTokens: String {
        let tokens = task.usage.inputTokens + task.usage.outputTokens
        return tokens > 0 ? "\(task.usage.steps) steps · \(WorkersCard.tokens(tokens)) tokens" : "\(task.usage.steps) steps"
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
