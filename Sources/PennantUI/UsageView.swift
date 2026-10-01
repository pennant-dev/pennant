import PennantClientKit
import PennantCore
import SwiftUI

/// Where the tokens (and the money) went: totals for a period, spend by job and by model, and every run ranked
/// by cost, so a large bill can be traced to the job, the run and the model that ran it up. A job is a scheduled
/// job, the coding runs, or a thread; helpers count under the run that started them.
public struct UsageView: View {
    @Environment(\.hostSession) private var session
    @State private var period: Period = .week
    @State private var rows: [UsageRow] = []
    @State private var loading = false
    @State private var error: String?
    /// The job picked in the breakdown: the totals and the runs narrow to it.
    @State private var filter: String?

    public init() {}

    public enum Period: String, CaseIterable, Hashable {
        case today, week, month, thisMonth
        var title: String {
            switch self { case .today: return "Today"; case .week: return "7 days"; case .month: return "30 days"; case .thisMonth: return "This month" }
        }
        var range: (Date, Date) {
            let now = Date(), cal = Calendar.current
            switch self {
            case .today: return (cal.startOfDay(for: now), now.addingTimeInterval(60))
            case .week: return (now.addingTimeInterval(-7 * 86_400), now.addingTimeInterval(60))
            case .month: return (now.addingTimeInterval(-30 * 86_400), now.addingTimeInterval(60))
            case .thisMonth: return (cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now, now.addingTimeInterval(60))
            }
        }
    }

    /// A run this expensive (or this large) gets flagged.
    static let runawayCost = 5.0
    static let runawayTokens = 3_000_000

    private var shown: [UsageRow] { filter.map { name in rows.filter { job($0) == name } } ?? rows }

    /// A row's job; hosts from before jobs send none, so the run's own title stands in.
    private func job(_ r: UsageRow) -> String { r.job ?? r.taskTitle }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ChipRow(selection: $period, options: Period.allCases.map { ChoiceOption($0, title: $0.title) })
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.pennantIcon).help("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            if rows.isEmpty && !loading {
                EmptyState(title: "No model calls in this period", message: "Every model call is recorded here: which job, which run, which model, how many tokens, and what it cost at the model's prices.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        totals
                        unpricedBanner
                        HStack(alignment: .top, spacing: 16) {
                            breakdown("By job", groups: byJob)
                            breakdown("By model", groups: byModel)
                        }
                        runs
                    }
                    .padding(16)
                    .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).padding(.horizontal, 16).padding(.bottom, 8) }
        }
        .background(PennantTheme.panelBackground)
        .task(id: period) { await load() }
    }

    // MARK: Sections

    private var totals: some View {
        let r = shown
        let cost = r.reduce(0) { $0 + $1.cost }
        let input = r.reduce(0) { $0 + $1.inputTokens }, cached = r.reduce(0) { $0 + $1.cachedInputTokens }, output = r.reduce(0) { $0 + $1.outputTokens }
        let calls = r.reduce(0) { $0 + $1.calls }
        return HStack(spacing: 12) {
            tile("Cost", Self.money(cost), sub: r.contains { $0.unpricedCalls > 0 } ? "priced calls only" : filter)
            tile("Model calls", calls.formatted(), sub: "\(Set(r.map(\.taskID)).count) runs")
            tile("Input tokens", formatTokens(input), sub: input > 0 ? "\(Int((Double(cached) / Double(input) * 100).rounded()))% from cache" : nil)
            tile("Output tokens", formatTokens(output), sub: nil)
        }
    }

    private func tile(_ title: String, _ value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            Text(value).font(.zoomed(.title2).weight(.semibold).monospacedDigit()).foregroundStyle(PennantTheme.ink)
            if let sub { Text(sub).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(elevated: true)
    }

    @ViewBuilder private var unpricedBanner: some View {
        let unpriced = shown.filter { $0.unpricedCalls > 0 }
        if !unpriced.isEmpty {
            let models = Set(unpriced.map(\.modelLabel)).sorted().joined(separator: ", ")
            let calls = unpriced.reduce(0) { $0 + $1.unpricedCalls }
            Label("\(calls) call\(calls == 1 ? "" : "s") ran on models without prices (\(models)), so their cost isn't in these totals. Set prices in Settings › Models.", systemImage: "exclamationmark.triangle.fill")
                .font(.zoomed(.callout)).foregroundStyle(PennantTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }


    private struct Group: Identifiable {
        var id: String; var title: String; var cost: Double; var tokens: Int; var filter: String?
        var runs = 0; var input = 0; var cached = 0
        var cachedPercent: Int? { input > 0 ? Int((Double(cached) / Double(input) * 100).rounded()) : nil }
    }

    /// Runs (distinct tasks), tokens and cached input for a set of rows.
    private static func group(_ id: String, _ title: String, _ rs: [UsageRow], filter: String? = nil) -> Group {
        Group(id: id, title: title, cost: rs.reduce(0) { $0 + $1.cost }, tokens: rs.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, filter: filter,
              runs: Set(rs.map(\.taskID)).count, input: rs.reduce(0) { $0 + $1.inputTokens }, cached: rs.reduce(0) { $0 + $1.cachedInputTokens })
    }

    /// "7 runs · 79% cached"
    private static func detail(_ g: Group) -> String {
        var parts = ["\(g.runs) run\(g.runs == 1 ? "" : "s")"]
        if let p = g.cachedPercent { parts.append("\(p)% cached") }
        return parts.joined(separator: " · ")
    }

    /// The costliest jobs, then the rest in one line so a month of one-off threads doesn't bury them.
    private var byJob: [Group] {
        let all = Dictionary(grouping: rows, by: job).map { name, rs in Self.group("job:" + name, name, rs, filter: name) }.sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
        guard all.count > Self.jobsShown + 1 else { return all }
        let rest = Set(all.dropFirst(Self.jobsShown).map(\.title))
        let others = Self.group("job:*", "Everything else (\(rest.count))", rows.filter { rest.contains(job($0)) })
        return Array(all.prefix(Self.jobsShown)) + [others]
    }
    static let jobsShown = 8

    private var byModel: [Group] {
        Dictionary(grouping: shown, by: \.modelLabel).map { label, rs in Self.group(label, label, rs) }.sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
    }

    private func breakdown(_ title: String, groups: [Group]) -> some View {
        let maxCost = groups.map(\.cost).max() ?? 0, maxTokens = groups.map(\.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title)
                Spacer()
                if filter != nil, groups.contains(where: { $0.filter == filter }) { Button("Show all") { filter = nil }.buttonStyle(.pennantGhostCompact) }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { g in
                    let fraction = maxCost > 0 ? g.cost / maxCost : (maxTokens > 0 ? Double(g.tokens) / Double(maxTokens) : 0)
                    Button {
                        if let f = g.filter { filter = filter == f ? nil : f }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(g.title).font(.zoomed(.callout).weight(g.filter != nil && filter == g.filter ? .semibold : .regular)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                                Text(Self.detail(g)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                                Spacer()
                                Text(Self.money(g.cost)).font(.zoomed(.callout).monospacedDigit()).foregroundStyle(PennantTheme.ink)
                                Text(formatTokens(g.tokens)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).frame(width: 64, alignment: .trailing)
                            }
                            GeometryReader { geo in
                                Capsule().fill(PennantTheme.brand.opacity(0.8)).frame(width: max(3, geo.size.width * fraction), height: 5)
                            }
                            .frame(height: 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(g.filter == nil)
                }
                if groups.count > 1 {
                    let total = Group(id: "total", title: "Total", cost: groups.reduce(0) { $0 + $1.cost }, tokens: groups.reduce(0) { $0 + $1.tokens },
                                      runs: groups.reduce(0) { $0 + $1.runs }, input: groups.reduce(0) { $0 + $1.input }, cached: groups.reduce(0) { $0 + $1.cached })
                    Rectangle().fill(PennantTheme.divider).frame(height: 1)
                    HStack {
                        Text("Total").font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                        Text(Self.detail(total)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
                        Spacer()
                        Text(Self.money(total.cost)).font(.zoomed(.callout).weight(.semibold).monospacedDigit()).foregroundStyle(PennantTheme.ink)
                        Text(formatTokens(total.tokens)).font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary).frame(width: 64, alignment: .trailing)
                    }
                }
            }
            .card(elevated: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var runs: some View {
        let sorted = shown.sorted { ($0.cost, $0.inputTokens + $0.outputTokens) > ($1.cost, $1.inputTokens + $1.outputTokens) }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Runs, most expensive first")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Run").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Job").frame(width: 130, alignment: .leading)
                    Text("Model").frame(width: 150, alignment: .leading)
                    Text("Calls").frame(width: 44, alignment: .trailing)
                    Text("In / out").frame(width: 110, alignment: .trailing)
                    Text("Cached").frame(width: 56, alignment: .trailing)
                    Text("Cost").frame(width: 76, alignment: .trailing)
                }
                .font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
                .padding(.vertical, 6)
                ForEach(sorted.prefix(200)) { r in
                    Rectangle().fill(PennantTheme.divider).frame(height: 1)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(r.taskTitle).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                                if r.cost >= Self.runawayCost || r.inputTokens + r.outputTokens >= Self.runawayTokens { Chip("large", color: PennantTheme.warning) }
                            }
                            Text(r.last.formatted(date: .abbreviated, time: .shortened)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(job(r)).font(.zoomed(.caption)).frame(width: 130, alignment: .leading).lineLimit(1)
                        Text(r.modelLabel).font(.zoomed(.caption)).frame(width: 150, alignment: .leading).lineLimit(1).truncationMode(.middle)
                        Text("\(r.calls)").font(.zoomed(.caption).monospacedDigit()).frame(width: 44, alignment: .trailing)
                        Text("\(formatTokens(r.inputTokens)) / \(formatTokens(r.outputTokens))").font(.zoomed(.caption).monospacedDigit()).frame(width: 110, alignment: .trailing)
                        Text(r.inputTokens > 0 ? "\(Int((Double(r.cachedInputTokens) / Double(r.inputTokens) * 100).rounded()))%" : "—")
                            .font(.zoomed(.caption).monospacedDigit()).foregroundStyle(PennantTheme.inkSecondary).frame(width: 56, alignment: .trailing)
                        Text(r.unpricedCalls == r.calls ? "—" : Self.money(r.cost) + (r.unpricedCalls > 0 ? "+" : ""))
                            .font(.zoomed(.caption).monospacedDigit()).frame(width: 76, alignment: .trailing)
                            .help(r.unpricedCalls > 0 ? "\(r.unpricedCalls) call(s) on a model without prices aren't counted" : "")
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
        }
    }

    // MARK: Data


    static func money(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        return v.formatted(.currency(code: "USD"))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let (from, to) = period.range
        do { rows = try await session.usageReport(from: from, to: to); error = nil } catch { self.error = HostSessionError.message(error) }
    }
}
