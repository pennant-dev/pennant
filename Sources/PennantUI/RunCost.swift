import PennantClientKit
import PennantCore
import SwiftUI

/// What a finished run cost, under its last reply: "$0.012 · 41k tokens · 82% cached". Read from the host's
/// usage ledger once per run and kept for the session.
struct RunCostChip: View {
    @Environment(\.hostSession) private var session
    var task: TaskRecord
    @State private var summary: RunCost.Summary?

    var body: some View {
        Group {
            if let s = summary, s.tokens > 0 {
                HStack(spacing: 4) {
                    Text("·")
                    if let cost = s.cost { Text(RunCost.money(cost)) ; Text("·") }
                    Text(WorkersCard.tokens(s.tokens))
                    if s.cachedFraction >= 0.05 { Text("· \(Int((s.cachedFraction * 100).rounded()))% cached") }
                }
                .help(s.help)
                .transition(.opacity)
            }
        }
        .task(id: task.id) { summary = await RunCost.summary(for: task, session: session) }
    }
}

@MainActor
enum RunCost {
    struct Summary: Equatable {
        var tokens: Int
        var cached: Int
        var input: Int
        var cost: Double?
        var models: [String]
        var cachedFraction: Double { input > 0 ? Double(cached) / Double(input) : 0 }
        var help: String {
            var lines = ["\(input.formatted()) in (\(cached.formatted()) cached), \(max(0, tokens - input).formatted()) out"]
            if !models.isEmpty { lines.append(models.joined(separator: ", ")) }
            if cost == nil { lines.append("No price set for this model") }
            return lines.joined(separator: "\n")
        }
    }

    private static var cache: [TaskID: Summary] = [:]

    static func summary(for task: TaskRecord, session: HostSession) async -> Summary? {
        if let hit = cache[task.id] { return hit }
        guard task.state.isTerminal else { return nil }
        let from = (task.usage.startedAt ?? task.createdAt).addingTimeInterval(-60)
        let to = (task.finishedAt ?? task.updatedAt).addingTimeInterval(60)
        guard let rows = try? await session.usageReport(from: from, to: to) else { return nil }
        let mine = rows.filter { $0.taskID == task.id }
        guard !mine.isEmpty else { return nil }
        let input = mine.reduce(0) { $0 + $1.inputTokens }
        let s = Summary(tokens: input + mine.reduce(0) { $0 + $1.outputTokens },
                        cached: mine.reduce(0) { $0 + $1.cachedInputTokens },
                        input: input,
                        cost: mine.allSatisfy { $0.unpricedCalls == $0.calls } ? nil : mine.reduce(0) { $0 + $1.cost },
                        models: Array(Set(mine.map(\.modelLabel))).sorted())
        cache[task.id] = s
        return s
    }

    static func money(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        return v < 1 ? String(format: "$%.3f", v) : String(format: "$%.2f", v)
    }
}
