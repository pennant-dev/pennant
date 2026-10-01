import PennantClientKit
import PennantCore
import SwiftUI

// Teach mode: the start sheet, the floating panel shown while recording, and the review sheet that turns the
// recording into a skill. The Mac app decides where each appears; these views only talk to the host.

// MARK: - Start

/// "What will you show?" and a Start button. Recording begins on the host; the app then gets out of the way.
public struct TeachStartSheet: View {
    @Environment(\.hostSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var starting = false
    @State private var error: String?

    public init() {}

    private static let examples = [
        "Record a screen demo of our web app in Recordly",
        "Export this week's report from Numbers as a PDF",
        "Post a draft to LinkedIn from Safari",
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SkillIcon(origin: "taught", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teach a skill").font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                    Text("Do the task once while Pennant watches. It turns what you did into a skill it can repeat.")
                        .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            PennantTextField("What will you show?", placeholder: Self.examples[0], text: $goal)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.examples, id: \.self) { example in
                    Button { goal = example } label: {
                        Label(example, systemImage: "arrow.up.left").font(.zoomed(.caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(goal == example ? PennantTheme.ink : PennantTheme.brandInk)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("cursorarrow.click.2", "Records the apps you open, the buttons and menus you click (by name), what you type, and your shortcuts. No video.")
                bullet("text.bubble", "Add notes from the floating panel to explain a choice, like which window matters.")
                bullet("lock", "Password fields are never recorded, and nothing is recorded after you press Stop.")
            }
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantGhost)
                Button {
                    start()
                } label: {
                    if starting { ProgressView().controlSize(.small) } else { Label("Start teaching", systemImage: "record.circle") }
                }
                .buttonStyle(.pennantPrimary)
                .disabled(starting || !session.connection.isConnected)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(PennantTheme.windowBackground)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(PennantTheme.inkTertiary).frame(width: 18)
            Text(text).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() {
        starting = true
        error = nil
        Task {
            defer { starting = false }
            do {
                try await session.startTeaching(goal: goal)
                dismiss()
            } catch {
                self.error = "Couldn’t start: \(error)"
            }
        }
    }
}

// MARK: - Floating panel

/// The small always-on-top panel while recording: what is being taught, the steps so far, a note box, Stop.
public struct TeachingPanelView: View {
    @Environment(\.hostSession) private var session
    @State private var note = ""
    @State private var busy = false
    @State private var pulse = false

    public init() {}

    public var body: some View {
        let t = session.state.teaching
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(PennantTheme.danger)
                    .frame(width: 10, height: 10)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                Text("Teaching").font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
                Spacer()
                // "00:42 · 17 steps": how long you've been showing it, and how much it has caught.
                TimelineView(.periodic(from: Clock.anchor, by: 1)) { context in
                    let secs = max(0, Int(context.date.timeIntervalSince(t?.startedAt ?? context.date)))
                    Text(String(format: "%02d:%02d", secs / 60, secs % 60) + " · \(t?.events.count ?? 0) steps")
                        .font(.zoomed(.caption).monospacedDigit())
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .contentTransition(.numericText())
                }
            }
            if let goal = t?.goal, !goal.isEmpty {
                Text(goal).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2)
            }
            if let warning = t?.warning {
                Text(warning).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                let recent = Array((t?.events ?? []).suffix(3))
                if recent.isEmpty {
                    Text("Go ahead: do the task. Each click, key and app switch shows here.")
                        .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(recent) { event in
                    Text(event.summary)
                        .font(.zoomed(.caption))
                        .foregroundStyle(event.id == recent.last?.id ? PennantTheme.ink : PennantTheme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            .padding(8)
            .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                TextField("Add a note, e.g. “use the second window”", text: $note)
                    .textFieldStyle(.plain)
                    .font(.zoomed(.callout))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(PennantTheme.fieldBackground, in: Capsule())
                    .onSubmit { addNote() }
                Button("Add") { addNote() }
                    .buttonStyle(.pennantCompact)
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Cancel") { cancel() }
                    .buttonStyle(.pennantGhostCompact)
                    .disabled(busy)
                Spacer()
                Button {
                    stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.pennantPrimaryCompact)
                .disabled(busy)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(PennantTheme.windowBackground)
    }

    private func addNote() {
        let text = note.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        note = ""
        Task { try? await session.addTeachingNote(text) }
    }

    private func stop() {
        busy = true
        Task {
            defer { busy = false }
            if !note.trimmingCharacters(in: .whitespaces).isEmpty { addNote() }
            _ = try? await session.stopTeaching()
        }
    }

    private func cancel() {
        busy = true
        Task {
            defer { busy = false }
            try? await session.cancelTeaching()
        }
    }
}

// MARK: - Review

/// After Stop: the recorded steps (remove the stray ones), the goal, and Draft. Once drafted, the skill's steps
/// with Done, or Discard to delete the draft.
public struct TeachingReviewView: View {
    @Environment(\.hostSession) private var session
    var onClose: () -> Void
    @State private var goal = ""
    @State private var drafting = false
    @State private var error: String?
    @State private var skill: Skill?
    @State private var busy = false

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        let t = session.state.teaching
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SkillIcon(origin: "taught", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill == nil ? "Review what you showed" : "Your new skill").font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                    Text(skill == nil
                         ? "Remove anything that was a slip, then draft. The model writes the procedure; the recording stays attached for reference."
                         : "Saved as provisional. Agents use it for similar tasks and it becomes validated after a few successful runs.")
                        .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let skill {
                draftView(skill)
            } else if let t {
                PennantTextField("What this skill does", placeholder: "Record a screen demo of our web app", text: $goal)
                stepList(t)
            } else {
                Text("The teaching session has ended.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            }
            if let error = error ?? t?.draftError {
                Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
            footer(t)
        }
        .padding(22)
        .frame(width: 560)
        .frame(minHeight: 420)
        .background(PennantTheme.windowBackground)
        .onAppear { goal = t?.goal ?? "" }
    }

    private func stepList(_ t: TeachingSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(t.events.count) recorded steps").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(t.events.enumerated()), id: \.element.id) { index, event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).frame(width: 24, alignment: .trailing)
                            Image(systemName: Self.symbol(event.kind)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).frame(width: 16)
                            Text(event.summary).font(.zoomed(.callout)).foregroundStyle(event.isNote ? PennantTheme.info : PennantTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button { remove(event.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .foregroundStyle(PennantTheme.inkTertiary)
                                .help("Leave this step out")
                                .accessibilityLabel("Remove step \(index + 1)")
                                .disabled(drafting || t.isDrafting)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func draftView(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(skill.name).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
                Chip("v\(skill.version)")
                Chip("Provisional", color: PennantTheme.warning)
            }
            if !skill.purpose.isEmpty {
                Text(skill.purpose).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(skill.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").font(.zoomed(.callout).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.instruction).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).fixedSize(horizontal: false, vertical: true)
                                if !step.check.isEmpty {
                                    Label(step.check, systemImage: "checkmark.circle").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if !skill.inputs.isEmpty {
                        Text("Inputs: \(skill.inputs.joined(separator: ", "))").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 340)
            .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Edit the steps any time in Skills.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    @ViewBuilder private func footer(_ t: TeachingSession?) -> some View {
        HStack {
            if skill != nil {
                Button("Discard draft", role: .destructive) { discard() }
                    .buttonStyle(.pennantGhost)
                    .disabled(busy)
                Spacer()
                Button("Done") { finish() }
                    .buttonStyle(.pennantPrimary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Throw away") { throwAway() }
                    .buttonStyle(.pennantGhost)
                    .disabled(drafting || busy)
                Spacer()
                Button("Teach again") { restart() }
                    .buttonStyle(.pennantSecondary)
                    .disabled(drafting || busy)
                Button {
                    draft()
                } label: {
                    if drafting || t?.isDrafting == true {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Drafting…") }
                    } else {
                        Label("Draft skill", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.pennantPrimary)
                .disabled(drafting || t == nil || (t?.events.isEmpty ?? true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func symbol(_ kind: TeachingEventKind) -> String {
        switch kind {
        case .appActivated: return "macwindow"
        case .window: return "rectangle.on.rectangle"
        case .click: return "cursorarrow.click"
        case .typed: return "character.cursor.ibeam"
        case .secureTyped: return "lock"
        case .shortcut: return "command"
        case .key: return "keyboard"
        case .scroll: return "arrow.up.and.down"
        case .note: return "text.bubble"
        }
    }

    // MARK: Actions

    private func remove(_ id: Int) {
        Task { try? await session.removeTeachingEvents([id]) }
    }

    private func draft() {
        drafting = true
        error = nil
        Task {
            defer { drafting = false }
            do {
                skill = try await session.draftSkillFromTeaching(goal: goal)
            } catch {
                if case HostSessionError.hostError(_, let message) = error { self.error = message } else { self.error = String(describing: error) }
            }
        }
    }

    private func finish() {
        Task {
            try? await session.cancelTeaching()   // the skill is saved; the session is done
            onClose()
        }
    }

    private func discard() {
        guard let skill else { return }
        busy = true
        Task {
            defer { busy = false }
            try? await session.deleteSkills([skill.id])
            self.skill = nil
        }
    }

    private func throwAway() {
        busy = true
        Task {
            defer { busy = false }
            try? await session.cancelTeaching()
            onClose()
        }
    }

    private func restart() {
        busy = true
        let g = goal
        Task {
            defer { busy = false }
            _ = try? await session.startTeaching(goal: g)
        }
    }
}
