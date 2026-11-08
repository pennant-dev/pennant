import Foundation

/// A card as json-render describes it (root, elements, state): the components Pennant's cards are drawn with
/// (Web/cards). This reads one as words, for the model's history, Copy and the channels that can't draw it.
public struct CardSpec: Sendable {
    public var spec: JSONValue
    public init(_ spec: JSONValue) { self.spec = spec }

    public var root: String? { spec["root"]?.stringValue }
    public var elements: [String: JSONValue] { spec["elements"]?.objectValue ?? [:] }
    public func element(_ key: String) -> JSONValue? { elements[key] }
    public func children(of element: JSONValue) -> [String] { element["children"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// An element's props, with `{"$state": "/path"}` and `{"$template": "…${/path}…"}` read from the card's state.
    public func props(of element: JSONValue) -> [String: JSONValue] {
        (element["props"]?.objectValue ?? [:]).compactMapValues(resolve)
    }

    /// The card's elements from the root down, each once, with how deep it sits.
    public func walk(_ visit: (_ key: String, _ element: JSONValue, _ depth: Int) -> Void) {
        var seen: Set<String> = []
        func go(_ key: String, _ depth: Int) {
            guard depth < 32, seen.insert(key).inserted, let element = element(key) else { return }
            visit(key, element, depth)
            for child in children(of: element) { go(child, depth + 1) }
        }
        if let root { go(root, 0) }
    }

    /// The first card title from the root down.
    public var title: String? {
        var found: String?
        walk { _, element, _ in
            if found == nil, element["type"]?.stringValue == "Card", let t = props(of: element)["title"]?.stringValue, !t.isEmpty { found = t }
        }
        return found
    }

    /// The card in Markdown: its headings, words, numbers, tables and timelines; charts as their numbers; buttons as
    /// what tapping them would say.
    public var plainText: String {
        var lines: [String] = []
        var buttons: [String] = []
        var tabLabels: [String: String] = [:]
        walk { _, element, _ in
            let p = props(of: element)
            func s(_ key: String) -> String? { p[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
            switch element["type"]?.stringValue ?? "" {
            case "Card":
                if let t = s("title") { lines.append("**\(t)**") }
                if let d = s("description") { lines.append(d) }
            case "Heading":
                if let t = s("text") { lines.append("\n**\(t)**") }
            case "Text":
                if let t = s("content") { lines.append(t) }
            case "Metric":
                guard let label = s("label"), let value = s("value") else { break }
                let trend = ["up": " ↑", "down": " ↓"][s("trend") ?? ""] ?? ""
                lines.append("- \(label): \(value)\(trend)\(s("detail").map { " (\($0))" } ?? "")")
            case "Table":
                let columns = p["columns"]?.arrayValue?.compactMap { c -> (String, String)? in
                    guard let key = c["key"]?.stringValue else { return nil }
                    return (key, c["label"]?.stringValue ?? key)
                } ?? []
                let rows = p["data"]?.arrayValue ?? []
                guard !columns.isEmpty else { break }
                lines.append("| " + columns.map(\.1).joined(separator: " | ") + " |")
                lines.append("|" + columns.map { _ in "---" }.joined(separator: "|") + "|")
                for row in rows.prefix(25) { lines.append("| " + columns.map { Self.cell(row[$0.0]) }.joined(separator: " | ") + " |") }
                if rows.count > 25 { lines.append("(and \(rows.count - 25) more rows)") }
            case "BarChart", "LineChart", "PieChart":
                let xKey = s("xKey") ?? s("nameKey") ?? "", yKey = s("yKey") ?? s("valueKey") ?? ""
                let points = (p["data"]?.arrayValue ?? []).prefix(24).map { "\(Self.cell($0[xKey])) \(Self.cell($0[yKey]))" }
                if !points.isEmpty { lines.append("\(s("title").map { "\($0): " } ?? "")\(points.joined(separator: ", "))") }
            case "Callout":
                if let c = s("content") { lines.append(s("title").map { "**\($0)**: \(c)" } ?? c) }
            case "Alert":
                if let t = s("title") { lines.append(s("message").map { "**\(t)**: \($0)" } ?? "**\(t)**") }
            case "Timeline":
                for item in p["items"]?.arrayValue ?? [] {
                    guard let t = item["title"]?.stringValue else { continue }
                    let date = item["date"]?.stringValue.map { "\($0) · " } ?? ""
                    lines.append("- \(date)\(t)\(item["description"]?.stringValue.map { ": \($0)" } ?? "")")
                }
            case "Accordion":
                for item in p["items"]?.arrayValue ?? [] {
                    if let t = item["title"]?.stringValue { lines.append("**\(t)**: \(item["content"]?.stringValue ?? "")") }
                }
            case "Progress":
                if let v = p["value"]?.doubleValue { lines.append("\(s("label") ?? "Progress"): \(Self.number(v))\(p["max"]?.doubleValue.map { " of \(Self.number($0))" } ?? "%")") }
            case "Badge":
                if let t = s("text") { lines.append("[\(t)]") }
            case "Link":
                if let t = s("text"), let h = s("href") { lines.append("[\(t)](\(h))") }
            case "Tabs":
                for tab in p["tabs"]?.arrayValue ?? [] {
                    if let v = tab["value"]?.stringValue { tabLabels[v] = tab["label"]?.stringValue ?? v }
                }
            case "TabContent":
                if let v = s("value") { lines.append("\n**\(tabLabels[v] ?? v)**") }
            case "Button":
                if let label = s("label") { buttons.append(label) }
            default:
                break
            }
        }
        if !buttons.isEmpty { lines.append("\nButtons: " + buttons.joined(separator: " · ")) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: State

    private func resolve(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .object(let o):
            if o.count == 1, let path = o["$state"]?.stringValue { return state(at: path) }
            if o.count == 1, let template = o["$template"]?.stringValue { return .string(fill(template)) }
            if o.keys.contains(where: { $0.hasPrefix("$") }) { return nil }
            return .object(o.compactMapValues(resolve))
        case .array(let a):
            return .array(a.compactMap(resolve))
        default:
            return value
        }
    }

    /// A JSON Pointer ("/rows/0/name") into the card's state.
    public func state(at path: String) -> JSONValue? {
        var node = spec["state"] ?? .object([:])
        for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
            let part = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let index = Int(part), let a = node.arrayValue { guard index >= 0, index < a.count else { return nil }; node = a[index] }
            else if let next = node[part] { node = next }
            else { return nil }
        }
        return node
    }

    private func fill(_ template: String) -> String {
        var out = template
        while let start = out.range(of: "${"), let end = out.range(of: "}", range: start.upperBound..<out.endIndex) {
            let path = String(out[start.upperBound..<end.lowerBound])
            out.replaceSubrange(start.lowerBound..<end.upperBound, with: state(at: path.hasPrefix("/") ? path : "/" + path).map(Self.cell) ?? "")
        }
        return out
    }

    /// A table cell or chart value as words.
    public static func cell(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: return s.replacingOccurrences(of: "|", with: "\\|")
        case .number(let n)?: return number(n)
        case .bool(let b)?: return b ? "yes" : "no"
        case nil, .null?: return ""
        case let v?: return v.description
        }
    }

    public static func number(_ n: Double) -> String { n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n) }
}
