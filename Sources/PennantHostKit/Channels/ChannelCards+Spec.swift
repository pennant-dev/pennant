import PennantCore
import Foundation

/// A report's card (a json-render spec) as an Adaptive Card for Teams: metrics as facts, tables as tables, callouts as
/// coloured containers, timelines and charts as lines of text, and its buttons as buttons that reply or open a link.
extension ChannelCards {
    static func body(of spec: CardSpec) -> (body: [JSONValue], actions: [JSONValue]) {
        var body: [JSONValue] = []
        var actions: [JSONValue] = []
        var metrics: [(String, String)] = []
        var tabLabels: [String: String] = [:]
        var first = true

        func flushMetrics() {
            if !metrics.isEmpty { body.append(facts(metrics)); metrics = [] }
        }
        spec.walk { _, element, _ in
            let type = element["type"]?.stringValue ?? ""
            let p = spec.props(of: element)
            func s(_ key: String) -> String? { p[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
            if type != "Metric" { flushMetrics() }
            switch type {
            case "Card":
                // The report's title heads the card already; a first card's title only repeats it.
                if let t = s("title"), !first { body.append(heading(t)) }
                if let d = s("description") { body.append(text(d, subtle: true)) }
            case "Heading":
                if let t = s("text") { body.append(["type": "TextBlock", "text": .string(t), "weight": "Bolder", "spacing": "Medium", "wrap": true]) }
            case "Text":
                if let t = s("content") { body.append(text(t, subtle: p["muted"]?.boolValue == true)) }
            case "Metric":
                if let label = s("label"), let value = s("value") {
                    let trend = ["up": " ↑", "down": " ↓"][s("trend") ?? ""] ?? ""
                    metrics.append((label, value + trend + (s("detail").map { " · \($0)" } ?? "")))
                }
            case "Table":
                if let table = table(p) { body.append(table) }
            case "BarChart", "LineChart", "PieChart":
                let xKey = s("xKey") ?? s("nameKey") ?? "", yKey = s("yKey") ?? s("valueKey") ?? ""
                let points = (p["data"]?.arrayValue ?? []).prefix(24).map { "\(CardSpec.cell($0[xKey])): \(CardSpec.cell($0[yKey]))" }
                if !points.isEmpty { body.append(text((s("title").map { "**\($0)**\n" } ?? "") + points.joined(separator: " · "), small: true)) }
            case "Callout", "Alert":
                let words = s("content") ?? s("message")
                let kind = s("type") ?? "info"
                let style = ["warning": "warning", "important": "attention", "error": "attention", "success": "good"][kind] ?? "emphasis"
                var items: [JSONValue] = []
                if let t = s("title") { items.append(["type": "TextBlock", "text": .string(t), "weight": "Bolder", "wrap": true]) }
                if let words { items.append(text(words)) }
                if !items.isEmpty { body.append(["type": "Container", "style": .string(style), "items": .array(items)]) }
            case "Timeline":
                let lines = (p["items"]?.arrayValue ?? []).compactMap { item -> String? in
                    guard let t = item["title"]?.stringValue else { return nil }
                    let mark = ["completed": "✓ ", "current": "→ "][item["status"]?.stringValue ?? ""] ?? "· "
                    return "\(mark)\(item["date"]?.stringValue.map { "\($0)  " } ?? "")\(t)\(item["description"]?.stringValue.map { " — \($0)" } ?? "")"
                }
                if !lines.isEmpty { body.append(text(lines.joined(separator: "\n"))) }
            case "Accordion":
                for item in p["items"]?.arrayValue ?? [] {
                    if let t = item["title"]?.stringValue { body.append(["type": "TextBlock", "text": .string(t), "weight": "Bolder", "wrap": true]) }
                    if let c = item["content"]?.stringValue { body.append(text(c)) }
                }
            case "Progress":
                if let v = p["value"]?.doubleValue {
                    let max = p["max"]?.doubleValue ?? 100
                    body.append(text("\(s("label") ?? "Progress"): \(Int((v / max * 100).rounded()))%"))
                }
            case "Badge":
                if let t = s("text") { body.append(text(t, subtle: true, small: true)) }
            case "TabContent":
                if let v = s("value") { body.append(["type": "TextBlock", "text": .string(tabLabels[v] ?? v), "weight": "Bolder", "spacing": "Medium", "wrap": true]) }
            case "Tabs":
                for tab in p["tabs"]?.arrayValue ?? [] { if let v = tab["value"]?.stringValue { tabLabels[v] = tab["label"]?.stringValue ?? v } }
            case "Link":
                if let t = s("text"), let h = s("href") { actions.append(["type": "Action.OpenUrl", "title": .string(t), "url": .string(h)]) }
            case "Button":
                guard let label = s("label"), let press = element["on"]?["press"] else { break }
                let binding = press.arrayValue?.first ?? press
                switch binding["action"]?.stringValue {
                case "reply":
                    if let words = binding["params"]?["text"]?.stringValue { actions.append(submit(label, ["pennant": "reply", "text": .string(words)], style: s("variant") == "default" ? "positive" : nil)) }
                case "open":
                    if let url = binding["params"]?["url"]?.stringValue { actions.append(["type": "Action.OpenUrl", "title": .string(label), "url": .string(url)]) }
                default:
                    break
                }
            default:
                break
            }
            first = false
        }
        flushMetrics()
        return (body, Array(actions.prefix(6)))
    }

    /// A json-render Table as an Adaptive Card table (schema 1.5), header row first, at most 20 rows.
    private static func table(_ p: [String: JSONValue]) -> JSONValue? {
        let columns = p["columns"]?.arrayValue?.compactMap { c -> (String, String)? in
            guard let key = c["key"]?.stringValue else { return nil }
            return (key, c["label"]?.stringValue ?? key)
        } ?? []
        guard !columns.isEmpty else { return nil }
        func row(_ cells: [String], header: Bool) -> JSONValue {
            ["type": "TableRow", "cells": .array(cells.map { cell in
                ["type": "TableCell", "items": [["type": "TextBlock", "text": .string(cell), "wrap": true, "weight": header ? "Bolder" : "Default"]]]
            })]
        }
        let rows = (p["data"]?.arrayValue ?? []).prefix(20).map { item in row(columns.map { CardSpec.cell(item[$0.0]) }, header: false) }
        return ["type": "Table", "firstRowAsHeaders": true, "showGridLines": false,
                "columns": .array(columns.map { _ in ["width": 1] }),
                "rows": .array([row(columns.map(\.1), header: true)] + rows)]
    }
}
