import PennantClientKit
import PennantCore
import SwiftUI

/// Questions a coding agent asks with options (Claude Code's AskUserQuestion): each question with its options to
/// tap (one, or several where it allows), an "Other" answer in your own words, and Send. Once answered it shows
/// what was chosen. Typing a reply in the composer instead answers every question with that text.
struct ChoiceCard: View {
    @Environment(\.hostSession) private var session
    var question: ChoiceQuestion
    var task: TaskRecord?
    /// Question text → chosen labels.
    @State private var picked: [String: Set<String>] = [:]
    /// Question text → the person's own answer, when "Other" is open.
    @State private var other: [String: String] = [:]
    @State private var otherOpen: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    private var open: Bool { question.answers == nil && task?.state == .waitingForUser }

    private func answer(for item: ChoiceQuestion.Item) -> String? {
        if otherOpen.contains(item.question) {
            let text = (other[item.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = item.multiSelect ? item.options.map(\.label).filter { picked[item.question]?.contains($0) == true } : []
            let all = labels + (text.isEmpty ? [] : [text])
            return all.isEmpty ? nil : all.joined(separator: ", ")
        }
        let labels = item.options.map(\.label).filter { picked[item.question]?.contains($0) == true }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private var ready: Bool { question.items.allSatisfy { answer(for: $0) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(question.items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().overlay(PennantTheme.border) }
                itemView(item)
            }
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
            footer
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous)
            .strokeBorder(open ? PennantTheme.brand.opacity(0.45) : PennantTheme.border))
        .shadow(color: .black.opacity(open ? 0.10 : 0.05), radius: open ? 18 : 10, y: open ? 8 : 4)
    }

    // MARK: One question

    private func itemView(_ item: ChoiceQuestion.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if !item.header.isEmpty {
                    Text(item.header.uppercased())
                        .font(.zoomed(.caption2).weight(.semibold)).tracking(0.6)
                        .foregroundStyle(PennantTheme.brandInk)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(PennantTheme.brandSoft, in: Capsule())
                }
                if item.multiSelect, open {
                    Text("Pick any").font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
                }
            }
            Text(item.question)
                .font(.zoomed(.callout).weight(.semibold))
                .foregroundStyle(PennantTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if open {
                VStack(spacing: 6) {
                    ForEach(item.options, id: \.label) { option in optionRow(option, in: item) }
                    otherRow(item)
                }
            } else {
                answeredView(item)
            }
        }
    }

    private func optionRow(_ option: ChoiceQuestion.Option, in item: ChoiceQuestion.Item) -> some View {
        let on = picked[item.question]?.contains(option.label) == true
        let (label, recommended) = Self.split(option.label)
        return Button {
            toggle(option.label, in: item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                indicator(on: on, multi: item.multiSelect).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink)
                        if recommended {
                            Text("Recommended").font(.zoomed(.caption2).weight(.semibold)).foregroundStyle(PennantTheme.brandInk)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(PennantTheme.brandSoft, in: Capsule())
                        }
                    }
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? PennantTheme.brandSoft : Color.clear, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous)
                .strokeBorder(on ? PennantTheme.brand.opacity(0.6) : PennantTheme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func otherRow(_ item: ChoiceQuestion.Item) -> some View {
        let on = otherOpen.contains(item.question)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if on { otherOpen.remove(item.question) } else {
                    otherOpen.insert(item.question)
                    if !item.multiSelect { picked[item.question] = [] }
                }
            } label: {
                HStack(spacing: 10) {
                    indicator(on: on, multi: item.multiSelect)
                    Text("Other").font(.zoomed(.callout).weight(.medium)).foregroundStyle(on ? PennantTheme.ink : PennantTheme.inkSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if on {
                TextField("Your answer", text: Binding(get: { other[item.question] ?? "" }, set: { other[item.question] = $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.zoomed(.callout))
                    .lineLimit(1...4)
                    .padding(8)
                    .background(PennantTheme.windowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PennantTheme.border))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func answeredView(_ item: ChoiceQuestion.Item) -> some View {
        let answer = question.answers?[item.question]
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: answer == nil ? "clock" : "checkmark.circle.fill")
                .foregroundStyle(answer == nil ? PennantTheme.inkTertiary : PennantTheme.brand)
            Text(answer.map { Self.split($0).label } ?? "Not answered")
                .font(.zoomed(.callout).weight(answer == nil ? .regular : .medium))
                .foregroundStyle(answer == nil ? PennantTheme.inkTertiary : PennantTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func indicator(on: Bool, multi: Bool) -> some View {
        Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
            .font(.zoomed(size: 15))
            .foregroundStyle(on ? PennantTheme.brand : PennantTheme.inkTertiary)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if open {
            HStack(spacing: 10) {
                Text(ready ? "" : "Answer \(question.items.count == 1 ? "the question" : "each question"), or reply below in your own words.")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    send()
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(question.items.count == 1 ? "Send answer" : "Send answers")
                    }
                }
                .buttonStyle(PennantButtonStyle(.primary, compact: true))
                .disabled(!ready || busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        } else if question.answers != nil {
            if let who = question.answeredBy?.name, !who.isEmpty {
                Text("Answered by \(who)").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            }
        } else {
            Text("No longer waiting for an answer.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    private func toggle(_ label: String, in item: ChoiceQuestion.Item) {
        var set = picked[item.question] ?? []
        if item.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
            otherOpen.remove(item.question)
        }
        picked[item.question] = set
    }

    private func send() {
        guard let task, ready else { return }
        var answers: [String: String] = [:]
        for item in question.items { answers[item.question] = answer(for: item) }
        busy = true
        error = nil
        Task {
            do { try await session.answerChoices(taskID: task.id, questionID: question.id, answers: answers) }
            catch { self.error = String(describing: error) }
            busy = false
        }
    }

    /// "Close #60 (Recommended)" → ("Close #60", true).
    static func split(_ label: String) -> (label: String, recommended: Bool) {
        let marker = "(Recommended)"
        guard label.hasSuffix(marker) else { return (label, false) }
        return (String(label.dropLast(marker.count)).trimmingCharacters(in: .whitespaces), true)
    }
}
