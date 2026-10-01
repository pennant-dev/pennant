import PennantClientKit
import PennantCore
import SwiftUI

/// One tool call as a card: a one-line header (family glyph, human title, status, duration, chevron), a
/// one-line summary of the result while collapsed, and the full input and output when expanded.
struct ToolActivityCard: View {
    @Environment(\.hostSession) private var session
    @Environment(\.offscreenStaticLayout) private var staticLayout
    var activity: ToolActivity
    /// A row inside a work group: no card, smaller glyph, the status only when it isn't "Done".
    var compact = false
    @State private var expanded = false
    @State private var showAll = false
    @State private var copied = false

    private static let outputMaxHeight: CGFloat = 260

    init(activity: ToolActivity, compact: Bool = false, initiallyExpanded: Bool = false) {
        self.activity = activity
        self.compact = compact
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let naming = ToolNaming.from(session.state)
        let title = ToolPresentation.title(for: activity, naming: naming)
        // A result that only echoes the title ("Pressed ⌘S" under "Pressed ⌘S") adds nothing.
        let summary = ToolPresentation.summary(for: activity).flatMap { $0.text.caseInsensitiveCompare(title.text) == .orderedSame ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header(title)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if !expanded, let summary, !compact || summary.isError {
                Text(summary.text)
                    .font(.zoomed(.caption))
                    .foregroundStyle(summary.isError ? PennantTheme.danger : PennantTheme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, compact ? 26 : 30)
                    .padding(.top, 1)
                    .padding(.bottom, 2)
            }
            if !expanded, !compact, !activity.images.isEmpty {
                images.padding(.leading, 30).padding(.top, 6).padding(.bottom, 4)
            }
            if expanded {
                details.transition(.opacity)
            }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(compact ? (expanded ? PennantTheme.cardBackground : Color.clear) : PennantTheme.cardElevated,
                    in: RoundedRectangle(cornerRadius: compact ? PennantTheme.radiusSmall : PennantTheme.cornerRadius, style: .continuous))
        .overlay {
            if !compact { RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private func header(_ title: ToolTitle) -> some View {
        let glyph = ToolPresentation.glyph(for: activity.name)
        let status = activity.status
        return HStack(spacing: 8) {
            ZStack {
                Circle().fill(glyph.tint.opacity(0.14))
                Image(systemName: glyph.symbol)
                    .font(.zoomed(size: 11, weight: .medium))
                    .foregroundStyle(glyph.tint)
            }
            .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
            HStack(spacing: 6) {
                Text(title.text)
                    .font(compact ? .zoomed(.callout) : .zoomed(.callout).weight(.medium))
                    .foregroundStyle(PennantTheme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                // A long token without spaces (a message or record id) tells a reader nothing; commands, paths
                // and URLs stay.
                if let code = title.code, !(code.count > 24 && !code.contains(" ") && !code.contains("/") && !code.contains(".")) {
                    Text(code)
                        .font(.zoomed(.caption).monospaced())
                        .foregroundStyle(PennantTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .help(title.codeFull ?? code)
                }
            }
            Spacer(minLength: 8)
            if !compact || status != .done { ToolStatusPill(status: status) }
            if let duration = activity.duration {
                Text(formatDuration(duration))
                    .font(.zoomed(.caption2).monospacedDigit())
                    .foregroundStyle(PennantTheme.inkTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.zoomed(.caption2).weight(.semibold))
                .foregroundStyle(PennantTheme.inkTertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .frame(minHeight: 20)
        .contentShape(Rectangle())
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShellHairline().padding(.top, 6)
            inputSection
            outputSection
            if let note = activity.record?.reconciliationNote {
                Label(note, systemImage: "checkmark.shield")
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Input")
            let rows = activity.argumentRows
            if rows.isEmpty {
                Text(activity.call == nil ? "The call is before the loaded history." : "No arguments")
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkTertiary)
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(rows, id: \.key) { row in
                        GridRow {
                            Text(row.key)
                                .font(.zoomed(.caption))
                                .foregroundStyle(PennantTheme.inkSecondary)
                                .lineLimit(1)
                                .frame(minWidth: 60, alignment: .leading)
                                .gridColumnAlignment(.leading)
                            argumentValue(row.value)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func argumentValue(_ value: JSONValue) -> some View {
        switch value {
        case .string(let s):
            Text(s)
                .font(.zoomed(.callout))
                .foregroundStyle(PennantTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .number, .bool:
            Text(value.compactText)
                .font(.zoomed(.callout).monospacedDigit())
                .foregroundStyle(PennantTheme.ink)
        case .null:
            Text("null").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkTertiary)
        case .array, .object:
            Text(ToolPresentation.pretty(value))
                .font(.zoomed(.caption).monospaced())
                .foregroundStyle(PennantTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        }
    }

    private var outputText: String {
        if let result = activity.result { return result.textContent }
        return activity.record?.resultSummary ?? ""
    }

    private var outputSection: some View {
        let text = outputText
        let status = activity.status
        let images = activity.images
        let tall = text.count > 1500 || text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > 14
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                sectionLabel("Output")
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Button {
                        copyToPasteboard(text)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.zoomed(.caption))
                    }
                    .buttonStyle(.pennantGhostCompact)
                    .help("Copy the output")
                }
            }
            if text.isEmpty, images.isEmpty {
                Text(status == .running ? "Running…" : (status == .pending ? "Not run yet" : "No output"))
                    .font(.zoomed(.caption))
                    .foregroundStyle(PennantTheme.inkTertiary)
            }
            if !text.isEmpty {
                outputBlock(text, tall: tall)
                if tall {
                    Button(showAll ? "Show less" : "Show all") {
                        withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.zoomed(.caption).weight(.medium))
                    .foregroundStyle(PennantTheme.info)
                }
            }
            if !images.isEmpty { self.images }
        }
    }

    /// Monospaced output. Shell-like output keeps its columns and scrolls sideways; prose and error messages
    /// wrap. Long output is cut at 260 pt until "Show all" (a nested vertical scroller inside the timeline
    /// would fight it).
    @ViewBuilder private func outputBlock(_ text: String, tall: Bool) -> some View {
        let isError = activity.status.isFailure
        let scrolls = !ToolPresentation.wrapsOutput(activity.name) && !isError && !staticLayout
        let body = Text(Self.markRedactions(text))
            .font(.zoomed(.caption).monospaced())
            .foregroundStyle(isError ? PennantTheme.danger : PennantTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: scrolls, vertical: true)
            .padding(8)
        Group {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: true) { body }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                body.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: tall && !showAll ? Self.outputMaxHeight : nil, alignment: .top)
        .clipped()
        .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
    }

    /// Secrets the vault scrubbed out read as a marked "🔑 redacted", not as a stray bracket in the output.
    static func markRedactions(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        var searchStart = out.startIndex
        while let range = out[searchStart...].range(of: "[redacted]") {
            var mark = AttributedString("🔑 redacted")
            mark.foregroundColor = Color(hex: "#6A3FD9")
            mark.backgroundColor = Color(hex: "#8B5CF6").opacity(0.12)
            let offset = out.characters.distance(from: out.startIndex, to: range.lowerBound)
            out.replaceSubrange(range, with: mark)
            searchStart = out.characters.index(out.startIndex, offsetBy: offset + mark.characters.count)
        }
        return out
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(activity.images.enumerated()), id: \.offset) { _, ref in
                ArtifactImageView(ref: ref)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.zoomed(.caption2).weight(.semibold))
            .foregroundStyle(PennantTheme.inkTertiary)
    }
}

/// "Running" with a breathing dot; otherwise the status word in its colour.
struct ToolStatusPill: View {
    var status: ToolActivityStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .running {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            }
            Text(status.label).lineLimit(1)
        }
        .font(.zoomed(.caption2).weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.14), in: Capsule())
        .foregroundStyle(status.color)
        .accessibilityLabel(status.label)
    }
}

/// Offscreen renders (`ImageRenderer`, previews) cannot draw a scroll view, so with this set the views that
/// would scroll (a tool's sideways output, the model list) lay out as plain stacks instead. Off in the app.
extension EnvironmentValues {
    @Entry var offscreenStaticLayout: Bool = false
}
