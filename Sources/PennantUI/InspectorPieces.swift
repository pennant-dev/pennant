import PennantCore
import SwiftUI

// Shared pieces for the inspector-side views: computer panel, permissions, connections, diagnostics.
// Internal on purpose. The foundation (Theme, Controls) owns the public tokens; these only compose them.

/// Status hues. Same values `PennantTheme.color(for:)` uses for task and agent state, so status reads the
/// same everywhere. The one place saturated colour appears in these views.
enum InspectorTint {
    static let success = Color(hex: "#3DB553")
    static let warning = Color(hex: "#F0762B")
    static let danger = Color(hex: "#E5484D")
    static let info = Color(hex: "#2F80ED")
    static let paused = Color(hex: "#F0A93B")
}

/// One-pixel rule in the divider colour, for rows inside a card.
struct InspectorHairline: View {
    var inset: CGFloat = 14
    var body: some View {
        Rectangle().fill(PennantTheme.divider).frame(height: 1).padding(.leading, inset)
    }
}

/// A white card whose rows run edge to edge with hairlines between them.
struct InspectorListCard<Item: Identifiable, Row: View>: View {
    var items: [Item]
    var rowPadding: CGFloat
    var emptyText: String?
    var row: (Item) -> Row

    init(_ items: [Item], rowPadding: CGFloat = 10, emptyText: String? = nil, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.rowPadding = rowPadding
        self.emptyText = emptyText
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text(emptyText ?? "Nothing yet")
                    .font(.zoomed(.callout))
                    .foregroundStyle(PennantTheme.inkTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, rowPadding + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                row(item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, rowPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if i < items.count - 1 { InspectorHairline() }
            }
        }
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
    }
}

/// A label/value line for cards: label in secondary ink on the left, value on the right.
/// Monospaced only for identifiers (paths, endpoints, model and tool names).
struct InspectorKeyValue: Identifiable {
    enum Style { case plain, mono, chip(Color) }
    var label: String
    var value: String
    var style: Style = .plain
    var id: String { label }
}

struct InspectorKeyValueRow: View {
    var item: InspectorKeyValue
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.label).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
            Spacer(minLength: 12)
            switch item.style {
            case .plain:
                Text(item.value).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).multilineTextAlignment(.trailing).textSelection(.enabled)
            case .mono:
                Text(item.value).font(.zoomed(.callout).monospaced()).foregroundStyle(PennantTheme.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            case .chip(let color):
                Chip(item.value, color: color)
            }
        }
    }
}

/// An SF Symbol in a softly tinted circle, for row leading icons.
struct InspectorTintedSymbol: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.14))
            Image(systemName: symbol).font(.zoomed(size: size * 0.44, weight: .medium)).foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A section label with optional trailing action, then its content.
struct InspectorSection<Trailing: View, Content: View>: View {
    var title: String
    var trailing: Trailing
    var content: Content

    init(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                SectionLabel(title)
                Spacer(minLength: 0)
                trailing
            }
            content
        }
    }
}

extension InspectorSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

/// Turns a job's schedule expression into the line under its name: "Every day at 8:00 AM",
/// "Weekdays at 6:00 PM", "Paused". Falls back to the next run, then the raw expression.
enum InspectorSchedulePhrase {
    static func line(for job: ScheduledJob, now: Date = Date()) -> String {
        guard job.enabled else { return "Paused" }
        if let phrase = describe(job.schedule, now: now) { return phrase }
        if let next = job.nextRunAt {
            return "Next " + next.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return job.schedule
    }

    /// Grammar: `every 15m`, `every 2h`, `hourly`, `daily at 09:00`, `weekdays at 08:30`,
    /// `weekly on mon,thu at 18:00`, `monthly on 1 at 07:00`, `once at 2026-10-01 09:00`. Cron returns nil.
    static func describe(_ expression: String, now: Date = Date()) -> String? {
        let tokens = expression.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first else { return nil }

        func at(_ index: Int) -> String {
            guard index < tokens.count, tokens[index] == "at", index + 1 < tokens.count, let t = clock(tokens[index + 1], now: now) else { return "" }
            return " at \(t)"
        }

        switch first {
        case "every":
            guard tokens.count >= 2 else { return nil }
            if let interval = interval(tokens[1]) { return interval }
            switch tokens[1] {
            case "day": return "Every day" + at(2)
            case "hour": return "Every hour"
            case "minute": return "Every minute"
            case "week": return "Every week" + at(2)
            case "weekday": return "Weekdays" + at(2)
            default:
                if let day = weekday(tokens[1]) { return "Every \(Calendar.current.weekdaySymbols[day - 1])" + at(2) }
                return nil
            }
        case "hourly": return "Every hour"
        case "daily": return "Every day" + at(1)
        case "weekdays": return "Weekdays" + at(1)
        case "weekends": return "Weekends" + at(1)
        case "weekly":
            var index = 1
            var days: [Int] = []
            if index < tokens.count, tokens[index] == "on", index + 1 < tokens.count {
                days = tokens[index + 1].split(separator: ",").compactMap { weekday(String($0)) }
                index += 2
            }
            return dayPhrase(days) + at(index)
        case "monthly":
            var index = 1
            var day: Int?
            if index < tokens.count, tokens[index] == "on", index + 1 < tokens.count, let d = Int(tokens[index + 1]) {
                day = d
                index += 2
            }
            let when = day.map { "Monthly on the \(ordinal($0))" } ?? "Every month"
            return when + at(index)
        case "once":
            guard tokens.count >= 3, tokens[1] == "at" else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = tokens.count >= 4 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            let text = tokens.dropFirst(2).prefix(2).joined(separator: " ")
            guard let date = formatter.date(from: text) else { return nil }
            let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
            let day = sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
            if tokens.count >= 4 { return "Once on \(day) at \(date.formatted(date: .omitted, time: .shortened))" }
            return "Once on \(day)"
        default:
            return nil
        }
    }

    // "15m" → "Every 15 minutes", "1h" → "Every hour", "2d" → "Every 2 days".
    private static func interval(_ token: String) -> String? {
        guard let unit = token.last, let n = Int(token.dropLast()), n > 0 else { return nil }
        let name: String
        switch unit {
        case "s": name = "second"
        case "m": name = "minute"
        case "h": name = "hour"
        case "d": name = "day"
        case "w": name = "week"
        default: return nil
        }
        return n == 1 ? "Every \(name)" : "Every \(n) \(name)s"
    }

    /// Calendar weekday number (Sunday = 1) for "mon", "monday", and so on.
    private static func weekday(_ token: String) -> Int? {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        guard token.count >= 3, let i = names.firstIndex(where: { token.hasPrefix($0) }) else { return nil }
        return i + 1
    }

    private static func dayPhrase(_ days: [Int]) -> String {
        let set = Set(days)
        if set.isEmpty { return "Every week" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        if set.count == 7 { return "Every day" }
        let cal = Calendar.current
        let ordered = set.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 } // Monday first
        if ordered.count == 1 { return "Every \(cal.weekdaySymbols[ordered[0] - 1])" }
        if ordered.count == 2 { return "\(cal.weekdaySymbols[ordered[0] - 1])s and \(cal.weekdaySymbols[ordered[1] - 1])s" }
        return ordered.map { cal.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }

    /// "09:00" → "9:00 AM" in the user's locale.
    private static func clock(_ token: String, now: Date) -> String? {
        let parts = token.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0 ... 23).contains(parts[0]), (0 ... 59).contains(parts[1]),
              let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}
