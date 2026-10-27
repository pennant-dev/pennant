import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Everything but the chat and its threads, on one page: four short lists, side by side when there's room, with a
/// line on what each place holds and a count where one helps. A row opens its page; the page's back button comes
/// back here.
struct EverythingElseView: View {
    @Environment(\.hostSession) private var session
    var open: (SidebarSection) -> Void
    @State private var wide = true

    var body: some View {
        ScrollView {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 20) {
                        column(SidebarSection.groups.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element))
                        column(SidebarSection.groups.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element))
                    }
                } else {
                    column(SidebarSection.groups)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { wide = $0 }
        .background(PennantTheme.windowBackground)
        .task {
            // The counts on the rows.
            try? await session.loadSchedules()
            try? await session.loadGoals()
            try? await session.loadReports()
        }
    }

    private func column(_ groups: [(title: String, sections: [SidebarSection])]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.zoomed(.caption).weight(.semibold))
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .padding(.leading, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(group.sections.enumerated()), id: \.element) { index, section in
                            if index > 0 {
                                Rectangle().fill(PennantTheme.divider).frame(height: 1).padding(.leading, 46)
                            }
                            PlaceRow(section: section, stat: stat(section)) { open(section) }
                        }
                    }
                    .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A few words on how much is there, when the app already knows; `urgent` when it needs the owner.
    private func stat(_ section: SidebarSection) -> PlaceRow.Stat? {
        let state = session.state
        switch section {
        case .dashboard:
            let waiting = state.pendingApprovals.count
            let going = state.tasks.filter { $0.parentTaskID == nil && !$0.state.isTerminal }.count
            if waiting > 0 { return .init(text: waiting == 1 ? "1 needs you" : "\(waiting) need you", urgent: true) }
            return going > 0 ? .init(text: "\(going) going on") : nil
        case .goals:
            let active = state.goals.filter { $0.status == .active }.count
            return active > 0 ? .init(text: "\(active) going") : nil
        case .reports:
            let week = state.reports.filter { $0.report.createdAt > Date().addingTimeInterval(-7 * 86_400) }.count
            return week > 0 ? .init(text: "\(week) this week") : nil
        case .schedules:
            let on = state.schedules.filter(\.enabled).count
            return on > 0 ? .init(text: on == 1 ? "1 job" : "\(on) jobs") : nil
        case .skills:
            let names = Set(state.skills.filter { $0.status != .disabled }.map(\.name)).count
            return names > 0 ? .init(text: "\(names)") : nil
        case .connections:
            let connected = state.mcpServers.filter { $0.state == .connected }.count
            return connected > 0 ? .init(text: "\(connected) on") : nil
        case .plugins:
            let on = state.plugins.filter(\.enabled).count
            return on > 0 ? .init(text: "\(on) on") : nil
        default:
            return nil
        }
    }
}

/// One place on the Everything else page: its symbol, name and what's there, a count, and a chevron. The row
/// lights up when pointed at.
private struct PlaceRow: View {
    struct Stat { var text: String; var urgent = false }
    var section: SidebarSection
    var stat: Stat?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.zoomed(size: 14, weight: .medium))
                    .foregroundStyle(PennantTheme.brandInk)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.zoomed(.callout).weight(.medium))
                        .foregroundStyle(PennantTheme.ink)
                    Text(section.detail)
                        .font(.zoomed(.caption))
                        .foregroundStyle(PennantTheme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let stat {
                    Text(stat.text)
                        .font(.zoomed(.caption).weight(stat.urgent ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(stat.urgent ? PennantTheme.brandInk : PennantTheme.inkSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.zoomed(size: 10, weight: .semibold))
                    .foregroundStyle(PennantTheme.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? PennantTheme.ink.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(section.title). \(section.detail)\(stat.map { ". \($0.text)" } ?? "")")
    }
}
