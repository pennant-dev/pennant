import PennantCore
import Foundation

/// What Pennant sends people on a channel: plain words, or a card (an Adaptive Card in Teams) with the same content
/// as text for channels without cards.
enum Outgoing: Sendable {
    case text(String)
    case card(JSONValue, fallback: String)

    var fallbackText: String {
        switch self { case .text(let t): return t; case .card(_, let f): return f }
    }
}

/// Pennant's cards as Adaptive Cards (schema 1.5, what Teams renders), with a text version of each. Buttons submit
/// `{"pennant": kind, …}` back to the bot, which applies them as the person who tapped.
enum ChannelCards {
    static let schema = "http://adaptivecards.io/schemas/adaptive-card.json"

    static func card(_ body: [JSONValue], actions: [JSONValue] = []) -> JSONValue {
        var c: [String: JSONValue] = ["type": "AdaptiveCard", "$schema": .string(schema), "version": "1.5", "body": .array(body)]
        if !actions.isEmpty { c["actions"] = .array(actions) }
        return .object(c)
    }

    static func heading(_ text: String) -> JSONValue {
        ["type": "TextBlock", "text": .string(text), "weight": "Bolder", "size": "Medium", "wrap": true]
    }

    static func text(_ text: String, subtle: Bool = false, small: Bool = false) -> JSONValue {
        var t: [String: JSONValue] = ["type": "TextBlock", "text": .string(text), "wrap": true]
        if subtle { t["isSubtle"] = true }
        if small { t["size"] = "Small" }
        return .object(t)
    }

    static func facts(_ pairs: [(String, String)]) -> JSONValue {
        ["type": "FactSet", "facts": .array(pairs.map { ["title": .string($0.0), "value": .string($0.1)] })]
    }

    static func submit(_ title: String, _ data: [String: JSONValue], style: String? = nil) -> JSONValue {
        var a: [String: JSONValue] = ["type": "Action.Submit", "title": .string(title), "data": .object(data)]
        if let style { a["style"] = .string(style) }
        return .object(a)
    }

    // MARK: Approval

    /// A draft waiting for approval: what, where it goes, the exact text, and Approve / Request changes / Reject
    /// (with an optional note). Once decided, the same card without buttons, saying who decided what.
    static func approval(_ a: ApprovalRequest, agentName: String) -> Outgoing {
        var body: [JSONValue] = [
            text("\(agentName) · needs your approval", subtle: true, small: true),
            heading(a.title),
        ]
        var pairs: [(String, String)] = []
        if !a.destination.isEmpty { pairs.append(("Where", a.destination)) }
        if let h = a.headline, !h.isEmpty { pairs.append(("Title", h)) }
        for d in a.details.prefix(6) { pairs.append((d.label, d.value)) }
        if !pairs.isEmpty { body.append(facts(pairs)) }
        body.append(text(String(a.finalText.prefix(3000))))
        if !a.images.isEmpty || a.video != nil {
            body.append(text("Includes \(a.images.count) image\(a.images.count == 1 ? "" : "s")\(a.video == nil ? "" : " and a video"): open Pennant to see them.", subtle: true, small: true))
        }
        if !a.notes.isEmpty { body.append(text(a.notes, subtle: true, small: true)) }
        guard a.state == .pending else {
            body.append(text(decidedLine(a), subtle: false))
            return .card(card(body), fallback: "\(a.title): \(decidedLine(a))")
        }
        body.append(["type": "Input.Text", "id": "comment", "placeholder": "Note (optional; needed to request changes)", "isMultiline": true])
        let data: (String) -> [String: JSONValue] = { ["pennant": "approval", "approvalID": .string(a.id), "verdict": .string($0)] }
        var actions = [submit(a.approveButtonLabel, data("approve"), style: "positive")]
        if let rest = a.allowRestLabel { actions.append(submit(rest, data("approveRest"))) }
        actions += [submit("Request changes", data("requestChanges")), submit("Reject", data("reject"), style: "destructive")]
        let fallback = "\(agentName) needs your approval: \(a.title)\(a.destination.isEmpty ? "" : " (\(a.destination))")\n\n\(a.finalText.prefix(1500))\n\nApprove it in Pennant."
        return .card(card(body, actions: actions), fallback: fallback)
    }

    static func decidedLine(_ a: ApprovalRequest) -> String {
        let who = a.decidedBy.map { " by \($0.name)" } ?? ""
        switch a.state {
        case .approved: return "✓ Approved\(who)"
        case .changesRequested: return "↺ Changes requested\(who)\(a.comment.map { ": \($0)" } ?? "")"
        case .rejected: return "✕ Rejected\(who)\(a.comment.map { ": \($0)" } ?? "")"
        case .pending: return "Waiting for approval"
        }
    }

    // MARK: Choices

    /// Questions with options: one choice set per question (several where it allows), an "Other" answer, Send.
    static func choices(_ q: ChoiceQuestion, taskID: TaskID, agentName: String) -> Outgoing {
        var body: [JSONValue] = [text("\(agentName) asks", subtle: true, small: true)]
        var lines: [String] = []
        for (i, item) in q.items.enumerated() {
            body.append(heading(item.question))
            body.append(["type": "Input.ChoiceSet", "id": .string("q\(i)"), "style": "expanded", "isMultiSelect": .bool(item.multiSelect),
                         "choices": .array(item.options.map { ["title": .string($0.description.isEmpty ? $0.label : "\($0.label) — \($0.description)"), "value": .string($0.label)] })])
            body.append(["type": "Input.Text", "id": .string("q\(i)_other"), "placeholder": "Or in your own words"])
            lines.append("\(item.question)\n" + item.options.enumerated().map { "  \($0.offset + 1). \($0.element.label)" }.joined(separator: "\n"))
        }
        let data: [String: JSONValue] = ["pennant": "choices", "taskID": .string(taskID.rawValue), "questionID": .string(q.id)]
        return .card(card(body, actions: [submit(q.items.count == 1 ? "Send answer" : "Send answers", data, style: "positive")]),
                     fallback: "\(agentName) asks:\n\n" + lines.joined(separator: "\n\n") + "\n\nReply with your answer.")
    }

    /// The answers a submitted choice card carries, by question text: the picked options, or the words typed.
    static func answers(_ q: ChoiceQuestion, from value: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (i, item) in q.items.enumerated() {
            let other = value["q\(i)_other"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let picked = (value["q\(i)"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let all = picked + (other.isEmpty ? [] : [other])
            if !all.isEmpty { out[item.question] = all.joined(separator: ", ") }
        }
        return out
    }

    // MARK: Report

    static func report(_ r: ReportCard, agentName: String) -> Outgoing {
        var body: [JSONValue] = [text("\(agentName) · report", subtle: true, small: true), heading(r.title)]
        if let s = r.subtitle, !s.isEmpty { body.append(text(s, subtle: true)) }
        body.append(["type": "TextBlock", "text": .string("\(dot(r.status)) \(r.verdict)"), "weight": "Bolder", "wrap": true, "color": .string(color(r.status))])
        for section in r.sections.prefix(8) {
            if let t = section.title, !t.isEmpty { body.append(["type": "TextBlock", "text": .string(t), "weight": "Bolder", "spacing": "Medium", "wrap": true]) }
            if let stats = section.stats, !stats.isEmpty {
                body.append(facts(stats.prefix(10).map { ("\($0.status.map(dot) ?? "")\($0.status == nil ? "" : " ")\($0.label)", $0.value + ($0.detail.map { " · \($0)" } ?? "")) }))
            }
            if let items = section.items, !items.isEmpty {
                body.append(text(items.prefix(12).map { "- \($0.status.map(dot) ?? "")\($0.status == nil ? "" : " ")\($0.text)\($0.detail.map { " — \($0)" } ?? "")" }.joined(separator: "\n")))
            }
            if let table = section.table, !table.rows.isEmpty {
                let lines = table.rows.prefix(10).map { row in row.map(\.text).joined(separator: " · ") }
                body.append(text(([table.columns.joined(separator: " · ")] + lines).joined(separator: "\n"), small: true))
            }
            if let t = section.text, !t.isEmpty { body.append(text(String(t.prefix(1500)))) }
        }
        return .card(card(body), fallback: r.markdown)
    }

    static func dot(_ s: ReportStatus) -> String {
        switch s { case .good: return "🟢"; case .watch: return "🟡"; case .bad: return "🔴"; case .neutral: return "⚪️" }
    }

    static func color(_ s: ReportStatus) -> String {
        switch s { case .good: return "Good"; case .watch: return "Warning"; case .bad: return "Attention"; case .neutral: return "Default" }
    }

    // MARK: An agent's own card

    /// A card an agent composes: a title, words, facts, and buttons whose words come back as the person's reply.
    static func simple(title: String?, text body: String?, facts pairs: [(String, String)], buttons: [String]) -> Outgoing {
        var items: [JSONValue] = []
        if let title, !title.isEmpty { items.append(heading(title)) }
        if let body, !body.isEmpty { items.append(text(body)) }
        if !pairs.isEmpty { items.append(facts(pairs)) }
        let actions = buttons.prefix(6).map { submit($0, ["pennant": "reply", "text": .string($0)]) }
        var fallback = [title, body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !pairs.isEmpty { fallback += "\n\n" + pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n") }
        if !buttons.isEmpty { fallback += "\n\nReply with: " + buttons.joined(separator: " / ") }
        return .card(card(items, actions: actions), fallback: fallback)
    }
}
