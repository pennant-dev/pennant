import PennantCore
import SwiftUI

/// A report an agent posted: a coloured verdict, then each section's paragraph, number tiles, table and list.
struct ReportCardView: View {
    @Environment(\.offscreenStaticLayout) private var staticLayout
    var report: ReportCard
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            verdict
            ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous).strokeBorder(PennantTheme.border))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.zoomed(size: 15, weight: .medium))
                .foregroundStyle(PennantTheme.inkSecondary)
                .frame(width: 30, height: 30)
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(report.title).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink).fixedSize(horizontal: false, vertical: true)
                Text(report.subtitle ?? report.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
            }
            Spacer(minLength: 8)
            Button {
                copyToPasteboard(report.markdown)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.pennantIcon)
            .help("Copy the report as Markdown")
        }
    }

    private var verdict: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: report.status.symbol).foregroundStyle(report.status.color)
            Text(report.verdict)
                .font(.zoomed(.callout).weight(.medium))
                .foregroundStyle(PennantTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VerdictPill(status: report.status)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(report.status.color.opacity(0.1), in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(report.status.color).frame(width: 3).padding(.vertical, 6)
        }
    }

    // MARK: Sections

    @ViewBuilder private func sectionView(_ s: ReportSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = s.title, !title.isEmpty {
                Text(title).font(.zoomed(.subheadline).weight(.semibold)).foregroundStyle(PennantTheme.inkSecondary)
            }
            if let text = s.text, !text.isEmpty {
                // Inline Markdown at the card's text size (bold, links, code), paragraphs kept.
                Text(markdown: text).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let stats = s.stats, !stats.isEmpty { tiles(stats) }
            if let table = s.table, !table.columns.isEmpty { tableView(table) }
            if let items = s.items, !items.isEmpty { list(items) }
        }
    }

    private func tiles(_ stats: [ReportStat]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .topLeading)], alignment: .leading, spacing: 8) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, st in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if let status = st.status, status != .neutral { Circle().fill(status.color).frame(width: 7, height: 7) }
                        Text(st.label).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1)
                    }
                    Text(st.value).font(.zoomed(.title3).weight(.semibold).monospacedDigit()).foregroundStyle(PennantTheme.ink).lineLimit(1).minimumScaleFactor(0.7)
                    if let detail = st.detail { Text(detail).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
            }
        }
    }

    @ViewBuilder private func tableView(_ table: ReportTable) -> some View {
        let grid = Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, c in
                    Text(c).font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkTertiary).padding(.vertical, 6)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(PennantTheme.divider).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let status = cell.status, status != .neutral {
                                Circle().fill(status.color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            }
                            Text(cell.text)
                                .font(index == 0 ? .zoomed(.callout).weight(.medium) : .zoomed(.callout))
                                .foregroundStyle(PennantTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
        if table.columns.count > 3, !staticLayout {
            // Wide tables scroll sideways on a phone instead of squeezing every column.
            ScrollView(.horizontal, showsIndicators: false) { grid.padding(.trailing, 4) }
        } else {
            grid
        }
    }

    private func list(_ items: [ReportItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: (item.status ?? .neutral).itemSymbol)
                        .font(.zoomed(size: (item.status ?? .neutral) == .neutral ? 6 : 11, weight: .semibold))
                        .foregroundStyle((item.status ?? .neutral).color)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail {
                            Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

extension ReportStatus {
    var color: Color {
        switch self {
        case .good: return PennantTheme.success
        case .watch: return PennantTheme.warning
        case .bad: return PennantTheme.danger
        case .neutral: return PennantTheme.inkTertiary
        }
    }
    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .neutral: return "info.circle.fill"
        }
    }
    var itemSymbol: String {
        switch self {
        case .good: return "checkmark"
        case .watch: return "exclamationmark"
        case .bad: return "xmark"
        case .neutral: return "circle.fill"
        }
    }
}

/// A report's verdict as a small worded pill: Good, Watch, Needs action, Info.
struct VerdictPill: View {
    var status: ReportStatus
    var body: some View {
        Text(status.word)
            .font(.zoomed(.caption2).weight(.semibold))
            .foregroundStyle(status == .neutral ? PennantTheme.inkSecondary : status.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((status == .neutral ? PennantTheme.inkTertiary : status.color).opacity(0.14), in: Capsule())
            .fixedSize()
    }
}
