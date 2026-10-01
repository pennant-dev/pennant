import Foundation

// A client-side reading of the host's schedule grammar (PennantHostKit/Scheduling/CronSchedule.swift), so the list can say
// "Every day at 8:00 AM" and the editor can turn its choices into an expression the parser accepts:
//   every 15m · every 2h · hourly · daily at 09:00 · weekdays at 08:30 · weekly on mon,thu at 18:00
//   monthly on 1 at 07:00 · once at 2026-10-01 09:00 · 5-field cron such as 0 9 * * 1-5
// The host stays the source of truth: the editor previews every expression through `session.previewSchedule`.

/// The editor's choices. `expression(timeZone:)` composes them; `parse` decomposes a stored expression back into choices.
struct ScheduleRecipe: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case interval, hourly, daily, weekdays, weekly, monthly, once, cron
        var id: String { rawValue }

        var title: String {
            switch self {
            case .interval: return "Every N minutes"
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .once: return "Once"
            case .cron: return "Cron"
            }
        }

        /// Leading word for a suggested job name: "Daily inbox summary".
        var cadenceWord: String {
            switch self {
            case .interval: return "Frequent"
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekdays: return "Weekday"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .once: return "One-off"
            case .cron: return "Scheduled"
            }
        }
    }

    /// Editor order: Monday first. The parser's names are the same three-letter keys.
    static let dayKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let dayTitles = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Interval choices in minutes: 5 … 45 minutes, then 1 … 12 hours.
    static let intervalChoices = [5, 10, 15, 30, 45, 60, 120, 180, 360, 720]

    var preset: Preset = .daily
    var intervalMinutes = 15
    var time: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    /// Indices into `dayKeys` (Monday = 0).
    var days: Set<Int> = [0]
    var dayOfMonth = 1
    var onceDate: Date = Date().addingTimeInterval(3600)
    var cron = "0 9 * * 1-5"

    static let cronExamples: [(title: String, cron: String)] = [
        ("Weekdays at 9:00", "0 9 * * 1-5"),
        ("Every 15 minutes", "*/15 * * * *"),
        ("Every 2 hours", "0 */2 * * *"),
        ("Mondays at 8:00", "0 8 * * 1"),
        ("1st of the month at 7:00", "0 7 1 * *"),
        ("Fridays at 17:30", "30 17 * * 5"),
    ]

    var hhmm: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var cadenceWord: String {
        guard preset == .interval else { return preset.cadenceWord }
        if intervalMinutes == 60 { return "Hourly" }
        if intervalMinutes % 60 == 0 { return "Every \(intervalMinutes / 60) hours" }
        return "Every \(intervalMinutes) min"
    }

    /// The expression exactly as the host's parser accepts it.
    func expression(timeZone: String) -> String {
        switch preset {
        case .interval:
            return intervalMinutes >= 60 && intervalMinutes % 60 == 0 ? "every \(intervalMinutes / 60)h" : "every \(intervalMinutes)m"
        case .hourly:
            return "hourly"
        case .daily:
            return "daily at \(hhmm)"
        case .weekdays:
            return "weekdays at \(hhmm)"
        case .weekly:
            let list = days.sorted().map { Self.dayKeys[$0] }.joined(separator: ",")
            return "weekly on \(list.isEmpty ? "mon" : list) at \(hhmm)"
        case .monthly:
            return "monthly on \(dayOfMonth) at \(hhmm)"
        case .once:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.timeZone = TimeZone(identifier: timeZone) ?? .current
            return "once at \(f.string(from: onceDate))"
        case .cron:
            return cron.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Reads a stored expression back into choices. Anything the presets cannot express lands in the Cron field as typed,
    /// so it can still be previewed and saved unchanged.
    static func parse(_ expression: String, timeZone: String) -> ScheduleRecipe {
        var r = ScheduleRecipe()
        let text = SchedulePhrasing.normalise(expression)
        let words = text.split(separator: " ").map(String.init)
        let cal = Calendar.current

        func setTime(_ hm: (Int, Int)?) -> Bool {
            guard let hm, let d = cal.date(bySettingHour: hm.0, minute: hm.1, second: 0, of: Date()) else { return false }
            r.time = d
            return true
        }
        func fallback() -> ScheduleRecipe {
            var c = ScheduleRecipe()
            c.preset = .cron
            c.cron = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            return c
        }

        if words.first == "every", words.count >= 2 {
            let amount = words.count == 2 ? words[1] : words[1] + words[2]
            guard let seconds = SchedulePhrasing.interval(amount), seconds.truncatingRemainder(dividingBy: 60) == 0 else { return fallback() }
            r.preset = .interval
            r.intervalMinutes = Int(seconds / 60)
            return r
        }
        if text == "hourly" { r.preset = .hourly; return r }
        if text == "daily" { r.preset = .daily; _ = setTime((9, 0)); return r }
        if let range = text.range(of: "daily at ") {
            r.preset = .daily
            return setTime(SchedulePhrasing.time(String(text[range.upperBound...]))) ? r : fallback()
        }
        if let range = text.range(of: "weekdays at ") {
            r.preset = .weekdays
            return setTime(SchedulePhrasing.time(String(text[range.upperBound...]))) ? r : fallback()
        }
        if text.hasPrefix("weekly on "), let at = text.range(of: " at ") {
            let list = text[text.index(text.startIndex, offsetBy: 10) ..< at.lowerBound]
            var days = Set<Int>()
            for name in list.split(separator: ",") {
                guard let i = dayKeys.firstIndex(of: String(name.trimmingCharacters(in: .whitespaces).prefix(3))) else { return fallback() }
                days.insert(i)
            }
            r.preset = .weekly
            r.days = days
            return setTime(SchedulePhrasing.time(String(text[at.upperBound...]))) ? r : fallback()
        }
        if text.hasPrefix("monthly on "), let at = text.range(of: " at ") {
            let dayText = text[text.index(text.startIndex, offsetBy: 11) ..< at.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let day = Int(dayText), (1 ... 31).contains(day) else { return fallback() }
            r.preset = .monthly
            r.dayOfMonth = day
            return setTime(SchedulePhrasing.time(String(text[at.upperBound...]))) ? r : fallback()
        }
        if text.hasPrefix("once at ") {
            guard let d = SchedulePhrasing.onceDate(String(text.dropFirst(8)), timeZone: timeZone) else { return fallback() }
            r.preset = .once
            r.onceDate = d
            return r
        }
        return fallback()
    }
}

/// Friendly one-line summaries of schedule expressions for the list.
enum SchedulePhrasing {
    struct Summary {
        var text: String
        /// True when the expression is raw cron and should carry a "cron" chip.
        var isCron: Bool
    }

    static func normalise(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text
    }

    static func interval(_ s: String) -> TimeInterval? {
        let digits = s.prefix { $0.isNumber }
        let unit = s.dropFirst(digits.count)
        guard let n = Double(digits), n > 0 else { return nil }
        switch unit {
        case "s", "sec", "secs", "second", "seconds": return n
        case "m", "min", "mins", "minute", "minutes": return n * 60
        case "h", "hr", "hrs", "hour", "hours": return n * 3600
        case "d", "day", "days": return n * 86400
        case "w", "week", "weeks": return n * 7 * 86400
        default: return nil
        }
    }

    static func time(_ s: String) -> (Int, Int)? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0 ... 23).contains(h), (0 ... 59).contains(m) else { return nil }
        return (h, m)
    }

    static func onceDate(_ s: String, timeZone: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: timeZone) ?? .current
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }

    /// "8:00 AM" (or "08:00" in 24-hour locales).
    static func clock(_ h: Int, _ m: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }

    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func summary(for expression: String, timeZone: String) -> Summary {
        let text = normalise(expression)
        let words = text.split(separator: " ").map(String.init)
        let raw = Summary(text: expression.trimmingCharacters(in: .whitespacesAndNewlines), isCron: false)

        if words.first == "every", words.count >= 2 {
            let amount = words.count == 2 ? words[1] : words[1] + words[2]
            guard let seconds = interval(amount) else { return raw }
            func unit(_ n: Double, _ one: String, _ many: String) -> String {
                let whole = n.truncatingRemainder(dividingBy: 1) == 0
                if n == 1 { return "Every \(one)" }
                return "Every \(whole ? String(Int(n)) : String(n)) \(many)"
            }
            if seconds < 60 { return Summary(text: unit(seconds, "second", "seconds"), isCron: false) }
            if seconds < 3600 { return Summary(text: unit(seconds / 60, "minute", "minutes"), isCron: false) }
            if seconds < 86400 { return Summary(text: unit(seconds / 3600, "hour", "hours"), isCron: false) }
            if seconds < 7 * 86400 { return Summary(text: unit(seconds / 86400, "day", "days"), isCron: false) }
            return Summary(text: unit(seconds / (7 * 86400), "week", "weeks"), isCron: false)
        }
        if text == "hourly" { return Summary(text: "Every hour", isCron: false) }
        if text == "daily" { return Summary(text: "Every day at \(clock(9, 0))", isCron: false) }
        if let range = text.range(of: "daily at "), let (h, m) = time(String(text[range.upperBound...])) {
            return Summary(text: "Every day at \(clock(h, m))", isCron: false)
        }
        if let range = text.range(of: "weekdays at "), let (h, m) = time(String(text[range.upperBound...])) {
            return Summary(text: "Weekdays at \(clock(h, m))", isCron: false)
        }
        if text.hasPrefix("weekly on "), let at = text.range(of: " at "), let (h, m) = time(String(text[at.upperBound...])) {
            let list = text[text.index(text.startIndex, offsetBy: 10) ..< at.lowerBound]
            var indices = Set<Int>()
            for name in list.split(separator: ",") {
                guard let i = ScheduleRecipe.dayKeys.firstIndex(of: String(name.trimmingCharacters(in: .whitespaces).prefix(3))) else { return raw }
                indices.insert(i)
            }
            let sorted = indices.sorted()
            let when = clock(h, m)
            if sorted.count == 7 { return Summary(text: "Every day at \(when)", isCron: false) }
            if sorted == [0, 1, 2, 3, 4] { return Summary(text: "Weekdays at \(when)", isCron: false) }
            if sorted == [5, 6] { return Summary(text: "Weekends at \(when)", isCron: false) }
            let names = sorted.map { ScheduleRecipe.dayTitles[$0] }.joined(separator: ", ")
            return Summary(text: "Weekly on \(names) at \(when)", isCron: false)
        }
        if text.hasPrefix("monthly on "), let at = text.range(of: " at "), let (h, m) = time(String(text[at.upperBound...])) {
            let dayText = text[text.index(text.startIndex, offsetBy: 11) ..< at.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let day = Int(dayText) else { return raw }
            return Summary(text: "Monthly on the \(ordinal(day)) at \(clock(h, m))", isCron: false)
        }
        if text.hasPrefix("once at "), let d = onceDate(String(text.dropFirst(8)), timeZone: timeZone) {
            let base = Date.FormatStyle(timeZone: TimeZone(identifier: timeZone) ?? .current)
            let day = d.formatted(base.day().month(.abbreviated).year())
            let when = d.formatted(base.hour().minute())
            return Summary(text: "Once on \(day) at \(when)", isCron: false)
        }
        if words.count == 5 { return Summary(text: raw.text, isCron: true) }
        return raw
    }
}
