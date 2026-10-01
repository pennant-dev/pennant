import PennantClientKit
import PennantCore
import SwiftUI

/// A passage of what was said, with the searched words highlighted and a link to the conversation it came from.
struct PassageCard: View {
    @Environment(\.openChat) private var openChat
    var passage: MemoryPassage
    var highlight: String = ""
    var note: String = ""

    var body: some View {
        MemoryHitCard(symbol: "text.quote", note: note) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(passage.title.isEmpty ? "Conversation" : passage.title)
                        .font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(passage.at.formatted(date: .abbreviated, time: .omitted)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                }
                Text(Self.highlighted(passage.text, words: highlight))
                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                if let openChat, let agentID = passage.agentID, let conversationID = passage.conversationID {
                    Button { openChat(agentID, conversationID) } label: {
                        Label("Open conversation", systemImage: "arrow.up.right").font(.zoomed(.caption).weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PennantTheme.brandInk)
                }
            }
        }
    }

    /// The searched words (three letters or more) in bold on a soft violet, like search snippets.
    static func highlighted(_ text: String, words query: String) -> AttributedString {
        var out = AttributedString(text)
        let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        guard !terms.isEmpty else { return out }
        let lower = text.lowercased()
        for term in Set(terms) {
            var search = lower.startIndex
            while let r = lower.range(of: term, range: search ..< lower.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: out), let hi = AttributedString.Index(r.upperBound, within: out) {
                    out[lo ..< hi].inlinePresentationIntent = .stronglyEmphasized
                    out[lo ..< hi].backgroundColor = PennantTheme.brandSoft
                    out[lo ..< hi].foregroundColor = PennantTheme.ink
                }
                search = r.upperBound
            }
        }
        return out
    }
}

/// Names removed from memory, which agents won't remember again, each with Restore.
struct RemovedNamesSection: View {
    @Environment(\.hostSession) private var session
    @State private var removed: [IgnoredMemoryName] = []
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !removed.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(spacing: 6) {
                        ForEach(removed) { item in
                            HStack(spacing: 8) {
                                Text(item.name).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                                Text(item.kind.rawValue).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                                Spacer()
                                Text(relativeTime(item.ignoredAt)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                                Button("Restore") { Task { removed = (try? await session.restoreRemovedMemory(item)) ?? removed } }
                                    .buttonStyle(PennantButtonStyle(.ghost, compact: true))
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    SectionLabel("Removed (\(removed.count))")
                }
                Text("Agents won't remember these again. Restore one to let them.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            }
        }
        .task { removed = (try? await session.removedMemory()) ?? [] }
    }
}
