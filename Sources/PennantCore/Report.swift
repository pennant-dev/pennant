import Foundation

/// A structured report an agent posts into its conversation (a daily status, a run summary): a verdict, then
/// sections of numbers, tables, lists and short text. The apps draw it as a card; the model reads it as Markdown.
public struct ReportCard: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// The one-line answer: "Healthy with 2 things to watch".
    public var verdict: String
    public var status: ReportStatus
    public var sections: [ReportSection]
    public var createdAt: Date

    public init(id: String = UUID().uuidString, title: String, subtitle: String? = nil, verdict: String, status: ReportStatus = .neutral, sections: [ReportSection] = [], createdAt: Date = Date()) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.verdict = verdict; self.status = status; self.sections = sections; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, title, subtitle, verdict, status, sections, createdAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        status = try c.decodeIfPresent(ReportStatus.self, forKey: .status) ?? .neutral
        sections = try c.decodeIfPresent([ReportSection].self, forKey: .sections) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// The report as Markdown: what the model sees in history, what "Copy" puts on the pasteboard.
    public var markdown: String {
        var out = ["**\(title)**\(subtitle.map { " · \($0)" } ?? "")", "\(status.word): \(verdict)"]
        for s in sections {
            var lines: [String] = []
            if let t = s.title, !t.isEmpty { lines.append("\n**\(t)**") }
            if let text = s.text, !text.isEmpty { lines.append(text) }
            for st in s.stats ?? [] { lines.append("- \(st.label): \(st.value)\(st.detail.map { " (\($0))" } ?? "")\(st.status.map { $0 == .neutral ? "" : " [\($0.word)]" } ?? "")") }
            if let table = s.table, !table.columns.isEmpty {
                lines.append("| " + table.columns.joined(separator: " | ") + " |")
                lines.append("|" + table.columns.map { _ in "---" }.joined(separator: "|") + "|")
                for row in table.rows { lines.append("| " + row.map { $0.text + ($0.status.map { $0 == .neutral ? "" : " (\($0.word))" } ?? "") }.joined(separator: " | ") + " |") }
            }
            for item in s.items ?? [] { lines.append("- \(item.status.map { $0 == .neutral ? "" : "[\($0.word)] " } ?? "")\(item.text)\(item.detail.map { ": \($0)" } ?? "")") }
            out.append(lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }
}

public enum ReportStatus: String, Codable, Sendable, CaseIterable {
    case good, watch, bad, neutral

    /// Accepts the words agents reach for ("ok", "healthy", "warning", "critical", "info"…).
    public init(from decoder: Decoder) throws {
        let raw = (try decoder.singleValueContainer().decode(String.self)).lowercased()
        self = ReportStatus.parse(raw)
    }

    public static func parse(_ raw: String) -> ReportStatus {
        switch raw.lowercased() {
        case "good", "ok", "healthy", "green", "success", "pass", "passed", "done", "resolved": return .good
        case "watch", "warning", "warn", "attention", "amber", "yellow", "degraded", "pending": return .watch
        case "bad", "critical", "error", "red", "failed", "fail", "down", "outage": return .bad
        default: return .neutral
        }
    }

    public var word: String {
        switch self { case .good: return "Good"; case .watch: return "Watch"; case .bad: return "Needs action"; case .neutral: return "Info" }
    }
}

/// One section: any of a paragraph, number tiles, a table and a list, drawn in that order.
public struct ReportSection: Hashable, Codable, Sendable {
    public var title: String?
    public var text: String?
    public var stats: [ReportStat]?
    public var table: ReportTable?
    public var items: [ReportItem]?
    public init(title: String? = nil, text: String? = nil, stats: [ReportStat]? = nil, table: ReportTable? = nil, items: [ReportItem]? = nil) {
        self.title = title; self.text = text; self.stats = stats; self.table = table; self.items = items
    }
}

/// A number tile: "Nodes ready · 27/27".
public struct ReportStat: Hashable, Codable, Sendable {
    public var label: String
    public var value: String
    public var detail: String?
    public var status: ReportStatus?
    public init(label: String, value: String, detail: String? = nil, status: ReportStatus? = nil) { self.label = label; self.value = value; self.detail = detail; self.status = status }

    private enum CodingKeys: String, CodingKey { case label, value, detail, status }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        // Numbers arrive as numbers as often as strings.
        if let s = try? c.decode(String.self, forKey: .value) { value = s }
        else if let d = try? c.decode(Double.self, forKey: .value) { value = d.rounded() == d ? String(Int(d)) : String(d) }
        else { value = "" }
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        status = try c.decodeIfPresent(ReportStatus.self, forKey: .status)
    }
}

public struct ReportTable: Hashable, Codable, Sendable {
    public var columns: [String]
    public var rows: [[ReportCell]]
    public init(columns: [String], rows: [[ReportCell]]) { self.columns = columns; self.rows = rows }
}

/// A table cell: plain text, optionally with a status dot. Decodes from a bare string too.
public struct ReportCell: Hashable, Codable, Sendable {
    public var text: String
    public var status: ReportStatus?
    public init(_ text: String, status: ReportStatus? = nil) { self.text = text; self.status = status }

    private enum CodingKeys: String, CodingKey { case text, status }
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { text = s; status = nil; return }
        if let d = try? decoder.singleValueContainer().decode(Double.self) { text = d.rounded() == d ? String(Int(d)) : String(d); status = nil; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        status = try c.decodeIfPresent(ReportStatus.self, forKey: .status)
    }
}

/// A list line with an optional status and a detail line under it.
public struct ReportItem: Hashable, Codable, Sendable {
    public var text: String
    public var detail: String?
    public var status: ReportStatus?
    public init(text: String, detail: String? = nil, status: ReportStatus? = nil) { self.text = text; self.detail = detail; self.status = status }

    private enum CodingKeys: String, CodingKey { case text, detail, status }
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { text = s; detail = nil; status = nil; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        status = try c.decodeIfPresent(ReportStatus.self, forKey: .status)
    }
}

/// A report card as it sits in a conversation (for the app's Reports list).
public struct PostedReport: Hashable, Codable, Sendable, Identifiable {
    public var report: ReportCard
    public var agentID: AgentID
    public var conversationID: ConversationID
    public var messageID: MessageID
    public var id: String { report.id }
    public init(report: ReportCard, agentID: AgentID, conversationID: ConversationID, messageID: MessageID) {
        self.report = report; self.agentID = agentID; self.conversationID = conversationID; self.messageID = messageID
    }
}
