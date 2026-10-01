import PennantCore
import Foundation

/// Schedule expressions: intervals, friendly phrases, one-off dates, and 5-field cron.
public struct CronSchedule: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case interval(TimeInterval)
        case once(Date)
        case cron(minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>) // weekdays 0 = Sunday
    }
    public let kind: Kind
    public let timeZone: TimeZone

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case unrecognized(String)
        case badTime(String)
        case badField(String)
        case badDate(String)
        public var description: String {
            switch self {
            case .empty: return "Schedule is empty"
            case .unrecognized(let s): return "Unrecognised schedule '\(s)'. Try 'every 15m', 'daily at 09:00', 'weekdays at 08:30', 'weekly on mon,thu at 18:00', 'monthly on 1 at 07:00', 'once at 2026-10-01 09:00', or cron like '0 9 * * 1-5'."
            case .badTime(let s): return "Bad time '\(s)'; use HH:mm"
            case .badField(let s): return "Bad cron field '\(s)'"
            case .badDate(let s): return "Bad date '\(s)'; use yyyy-MM-dd HH:mm"
            }
        }
    }

    static let weekdayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
    static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    public static func parse(_ raw: String, timeZone: TimeZone = .current) throws -> CronSchedule {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "  ", with: " ")
        guard !text.isEmpty else { throw ParseError.empty }
        let words = text.split(separator: " ").map(String.init)

        // every 15m / every 2 hours
        if words.first == "every", words.count >= 2 {
            let amountText = words.count == 2 ? words[1] : words[1] + words[2]
            if let seconds = parseInterval(amountText) { return CronSchedule(kind: .interval(max(60, seconds)), timeZone: timeZone) }
            throw ParseError.unrecognized(raw)
        }
        if text == "hourly" { return CronSchedule(kind: .cron(minutes: [0], hours: Set(0..<24), days: Set(1...31), months: Set(1...12), weekdays: Set(0...6)), timeZone: timeZone) }
        if text == "daily" { return try parse("daily at 09:00", timeZone: timeZone) }
        if let range = text.range(of: "daily at ") {
            let (h, m) = try parseTime(String(text[range.upperBound...]))
            return CronSchedule(kind: .cron(minutes: [m], hours: [h], days: Set(1...31), months: Set(1...12), weekdays: Set(0...6)), timeZone: timeZone)
        }
        if let range = text.range(of: "weekdays at ") {
            let (h, m) = try parseTime(String(text[range.upperBound...]))
            return CronSchedule(kind: .cron(minutes: [m], hours: [h], days: Set(1...31), months: Set(1...12), weekdays: [1, 2, 3, 4, 5]), timeZone: timeZone)
        }
        if text.hasPrefix("weekly on "), let at = text.range(of: " at ") {
            let dayList = String(text[text.index(text.startIndex, offsetBy: 10)..<at.lowerBound])
            let (h, m) = try parseTime(String(text[at.upperBound...]))
            var days = Set<Int>()
            for name in dayList.split(separator: ",") {
                guard let d = weekdayNames[String(name.trimmingCharacters(in: .whitespaces).prefix(3))] else { throw ParseError.unrecognized(raw) }
                days.insert(d)
            }
            return CronSchedule(kind: .cron(minutes: [m], hours: [h], days: Set(1...31), months: Set(1...12), weekdays: days), timeZone: timeZone)
        }
        if text.hasPrefix("monthly on "), let at = text.range(of: " at ") {
            let dayText = String(text[text.index(text.startIndex, offsetBy: 11)..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard let day = Int(dayText), (1...31).contains(day) else { throw ParseError.unrecognized(raw) }
            let (h, m) = try parseTime(String(text[at.upperBound...]))
            return CronSchedule(kind: .cron(minutes: [m], hours: [h], days: [day], months: Set(1...12), weekdays: Set(0...6)), timeZone: timeZone)
        }
        if text.hasPrefix("once at ") {
            let dateText = String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                f.dateFormat = format
                if let d = f.date(from: dateText) { return CronSchedule(kind: .once(d), timeZone: timeZone) }
            }
            throw ParseError.badDate(dateText)
        }
        if words.count == 5 {
            let minutes = try parseField(words[0], range: 0...59, names: [:])
            let hours = try parseField(words[1], range: 0...23, names: [:])
            let days = try parseField(words[2], range: 1...31, names: [:])
            let months = try parseField(words[3], range: 1...12, names: monthNames)
            var weekdays = try parseField(words[4], range: 0...7, names: weekdayNames)
            if weekdays.contains(7) { weekdays.remove(7); weekdays.insert(0) }
            return CronSchedule(kind: .cron(minutes: minutes, hours: hours, days: days, months: months, weekdays: weekdays), timeZone: timeZone)
        }
        throw ParseError.unrecognized(raw)
    }

    static func parseInterval(_ s: String) -> TimeInterval? {
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

    static func parseTime(_ s: String) throws -> (Int, Int) {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ":").map(String.init)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { throw ParseError.badTime(t) }
        return (h, m)
    }

    static func parseField(_ field: String, range: ClosedRange<Int>, names: [String: Int]) throws -> Set<Int> {
        var out = Set<Int>()
        for part in field.split(separator: ",") {
            var spec = String(part)
            var step = 1
            if let slash = spec.firstIndex(of: "/") {
                guard let st = Int(spec[spec.index(after: slash)...]), st > 0 else { throw ParseError.badField(field) }
                step = st
                spec = String(spec[..<slash])
            }
            func value(_ s: String) throws -> Int {
                if let n = Int(s) { return n }
                if let n = names[String(s.prefix(3))] { return n }
                throw ParseError.badField(field)
            }
            var lo: Int, hi: Int
            if spec == "*" { lo = range.lowerBound; hi = range.upperBound }
            else if let dash = spec.firstIndex(of: "-") { lo = try value(String(spec[..<dash])); hi = try value(String(spec[spec.index(after: dash)...])) }
            else { lo = try value(spec); hi = step > 1 ? range.upperBound : lo }
            guard range.contains(lo), range.contains(hi), lo <= hi else { throw ParseError.badField(field) }
            var v = lo
            while v <= hi { out.insert(v); v += step }
        }
        return out
    }

    /// The first run strictly after `date`, or nil for a one-off that already passed.
    public func next(after date: Date) -> Date? {
        switch kind {
        case .interval(let seconds):
            return date.addingTimeInterval(seconds)
        case .once(let when):
            return when > date ? when : nil
        case .cron(let minutes, let hours, let days, let months, let weekdays):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let sortedHours = hours.sorted(), sortedMinutes = minutes.sorted()
            var dayStart = calendar.startOfDay(for: date)
            for _ in 0 ..< 400 {
                let comps = calendar.dateComponents([.day, .month, .weekday], from: dayStart)
                if months.contains(comps.month!), days.contains(comps.day!), weekdays.contains(comps.weekday! - 1) {
                    for h in sortedHours {
                        for m in sortedMinutes {
                            if let candidate = calendar.date(bySettingHour: h, minute: m, second: 0, of: dayStart), candidate > date { return candidate }
                        }
                    }
                }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
                dayStart = nextDay
            }
            return nil
        }
    }

    public func preview(after date: Date, count: Int) -> [Date] {
        var out: [Date] = []
        var cursor = date
        for _ in 0 ..< max(1, min(count, 20)) {
            guard let n = next(after: cursor) else { break }
            out.append(n)
            cursor = n
        }
        return out
    }
}
