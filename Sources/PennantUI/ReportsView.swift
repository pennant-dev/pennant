import PennantClientKit
import PennantCore
import SwiftUI

/// Every report, easy to get through: a list grouped by day (search it, or narrow it to what needs attention or to
/// one kind of report: Inbox, Infrastructure, Release…) and the chosen report beside it. On a phone the list opens
/// each report in a sheet.
public struct ReportsView: View {
    @Environment(\.hostSession) private var session
    var onOpen: ((AgentID, ConversationID) -> Void)?
    @State private var query = ""
    @State private var kind: String?
    @State private var attentionOnly = false
    @State private var selectedID: String?
    @State private var sheet: PostedReport?
    /// Side by side when there's room; measured when the width changes.
    @State private var wide = true

    public init(onOpen: ((AgentID, ConversationID) -> Void)? = nil) { self.onOpen = onOpen }

    // MARK: Data

    /// "Inbox · Monday morning" → Inbox; "Release 0.1.15 · 28 Sep" → Release: what kind of report it is.
    static func kind(of report: ReportCard) -> String {
        let head = report.title.components(separatedBy: " · ").first ?? report.title
        let words = head.split(separator: " ").filter { !$0.contains(where: \.isNumber) }
        let k = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? "Report" : k
    }

    private var all: [PostedReport] { session.state.reports.sorted { $0.report.createdAt > $1.report.createdAt } }

    private var kinds: [(name: String, count: Int)] {
        Dictionary(grouping: all, by: { Self.kind(of: $0.report) }).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private var filtered: [PostedReport] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { r in
            (kind == nil || Self.kind(of: r.report) == kind)
                && (!attentionOnly || r.report.status == .watch || r.report.status == .bad)
                && (q.isEmpty || r.report.title.localizedCaseInsensitiveContains(q) || r.report.verdict.localizedCaseInsensitiveContains(q)
                    || (r.report.subtitle ?? "").localizedCaseInsensitiveContains(q))
        }
    }

    /// Today, Yesterday, a weekday this week, then dates.
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -6, to: Date()), date > week { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var days: [(label: String, reports: [PostedReport])] {
        var out: [(label: String, reports: [PostedReport])] = []
        for r in filtered {
            let label = Self.day(r.report.createdAt)
            if out.last?.label == label { out[out.count - 1].reports.append(r) } else { out.append((label, [r])) }
        }
        return out
    }

    private var selected: PostedReport? {
        let list = filtered
        return list.first { $0.id == selectedID } ?? list.first
    }

    // MARK: Body

    public var body: some View {
        Group {
            if wide {
                HStack(spacing: 0) {
                    list.frame(width: 360)
                    Rectangle().fill(PennantTheme.divider).frame(width: 1)
                    detail(selected)
                }
            } else {
                list
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { wide = $0 }
        .overlay {
            if session.state.reports.isEmpty {
                EmptyState(title: "No reports yet", message: "When Pennant finishes a report (a daily status, a run summary), it lands here as well as in its thread.")
            }
        }
        .background(PennantTheme.panelBackground)
        .sheet(item: $sheet) { r in
            NavigationStack { detail(r).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { sheet = nil } } } }
        }
        .task { try? await session.loadReports() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                    TextField("Search reports", text: $query).textFieldStyle(.plain).font(.zoomed(.callout))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip("All", on: kind == nil && !attentionOnly) { kind = nil; attentionOnly = false }
                        let attention = all.filter { $0.report.status == .watch || $0.report.status == .bad }.count
                        if attention > 0 {
                            filterChip("Needs attention · \(attention)", on: attentionOnly, tint: PennantTheme.warning) { attentionOnly.toggle() }
                        }
                        ForEach(kinds.prefix(8), id: \.name) { k in
                            filterChip("\(k.name) · \(k.count)", on: kind == k.name) { kind = kind == k.name ? nil : k.name }
                        }
                    }
                }
            }
            .padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.label) { day in
                        Section {
                            ForEach(day.reports) { r in row(r) }
                        } header: {
                            Text(day.label.uppercased())
                                .font(.zoomed(.caption2).weight(.semibold)).tracking(0.6)
                                .foregroundStyle(PennantTheme.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(PennantTheme.panelBackground)
                        }
                    }
                    if filtered.isEmpty, !all.isEmpty {
                        Text("No reports match.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkTertiary).padding(16)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
    }

    private func filterChip(_ title: String, on: Bool, tint: Color = PennantTheme.brandInk, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.zoomed(.caption).weight(.medium)).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(on ? tint : PennantTheme.inkSecondary)
                .background(on ? tint.opacity(0.14) : PennantTheme.cardElevated, in: Capsule())
                .overlay(Capsule().stroke(on ? tint.opacity(0.4) : PennantTheme.border))
        }
        .buttonStyle(.plain)
    }

    private func row(_ r: PostedReport) -> some View {
        let isSelected = wide && selected?.id == r.id
        return Button { if wide { selectedID = r.id } else { sheet = r } } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(r.report.status.color).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(r.report.title).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(r.report.createdAt.formatted(date: .omitted, time: .shortened)).font(.zoomed(.caption2).monospacedDigit()).foregroundStyle(PennantTheme.inkTertiary)
                    }
                    if !r.report.verdict.isEmpty {
                        Text(r.report.verdict).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? PennantTheme.selection : .clear, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall + 1, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func detail(_ r: PostedReport?) -> some View {
        if let r {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Chip(Self.kind(of: r.report))
                        Text(r.report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                        Spacer(minLength: 8)
                        if let onOpen {
                            Button { sheet = nil; onOpen(r.agentID, r.conversationID) } label: { Label("Open thread", systemImage: "arrow.up.right") }
                                .buttonStyle(.pennantGhostCompact).fixedSize()
                        }
                    }
                    ReportCardView(report: r.report)
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(PennantTheme.panelBackground)
        } else {
            Text("Pick a report.").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Approvals and reports together, for the phone's Inbox tab.
public struct InboxView: View {
    @Environment(\.hostSession) private var session
    public enum Tab: Hashable { case approvals, reports }
    @State private var tab: Tab = .approvals
    public init() {}
    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(session.state.pendingApprovals.isEmpty ? "Approvals" : "Approvals (\(session.state.pendingApprovals.count))").tag(Tab.approvals)
                Text("Reports").tag(Tab.reports)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            switch tab {
            case .approvals: ApprovalsView()
            case .reports: ReportsView()
            }
        }
        .background(PennantTheme.panelBackground)
    }
}
