import PennantCore
import Foundation

/// Posts a report into the conversation as a card: a title and verdict, then either a card drawn with json-render's
/// components (CardCatalog; checked before it's posted) or plain sections of number tiles, tables, lists and short
/// text. For daily status reports, run summaries and anything with a verdict and a few numbers.
public struct PostReportTool: Tool {
    public init() {}

    static let statusDoc = "good | watch | bad | neutral"

    public var spec: ToolSpec {
        let status = JSONSchema.string("Status colour: \(Self.statusDoc).")
        return ToolSpec(
            name: "post_report",
            description: """
            Post a report as a card in the conversation instead of a wall of text. Always give a title and a one-line verdict with a status colour: they head the report and are what people see where a card can't be drawn. Then either a card (for anything with numbers, a chart, a table, a timeline or choices for the owner) or sections (a plain report). After posting, reply with one short line; don't repeat the report.

            A card is {"root": "<key>", "elements": {"<key>": {"type": "<Component>", "props": {…}, "children": ["<key>", …]}}}: a flat map of elements by key, the root usually a Card holding the rest. Put data straight in the props (a chart's or table's data is an array of objects). Lay out with Grid (2 to 4 Metrics a row), Stack, and Tabs whose children are TabContent. A Button takes "on": {"press": {"action": "reply", "params": {"text": "Send Lena the nudge"}}}, beside props, and a tap sends those words as the owner's reply, so word them as the owner would; "open" with params.url opens a link. Colours, fonts and sizes come from Pennant's theme.

            Components:
            \(CardCatalog.componentLines)
            Sections: each may have a short Markdown paragraph (text), number tiles (stats: label, value, optional detail and status), a table (columns and rows; a cell is a string or {text, status}), and a list (items: text, optional detail and status), drawn in that order.
            """,
            inputSchema: JSONSchema.object([
                "title": JSONSchema.string("What this is: \"Infrastructure · Thursday 24 Sep\"."),
                "subtitle": JSONSchema.string("Optional second line (scope, period)."),
                "verdict": JSONSchema.string("The answer in one line: \"Healthy with 2 things to watch\"."),
                "status": status,
                "card": .object(["type": "object", "description": "The card: root and elements (and optionally state), drawn with the components above."]),
                "sections": .object(["type": "array", "description": "Sections in reading order.", "items": .object(["type": "object", "properties": .object([
                    "title": JSONSchema.string("Section heading, e.g. \"Needs a decision\"."),
                    "text": JSONSchema.string("A short Markdown paragraph."),
                    "stats": .object(["type": "array", "items": .object(["type": "object", "properties": .object([
                        "label": JSONSchema.string("What is measured."), "value": JSONSchema.string("The number, with its unit."),
                        "detail": JSONSchema.string("Optional context under the number."), "status": status,
                    ])])]),
                    "table": .object(["type": "object", "properties": .object([
                        "columns": .object(["type": "array", "items": .object(["type": "string"])]),
                        "rows": .object(["type": "array", "items": .object(["type": "array", "items": .object(["description": "A string, or {\"text\": …, \"status\": …}"])])]),
                    ])]),
                    "items": .object(["type": "array", "items": .object(["type": "object", "properties": .object([
                        "text": JSONSchema.string("One line."), "detail": JSONSchema.string("Optional detail under it."), "status": status,
                    ])])]),
                ])])]),
            ], required: ["title", "verdict"]),
            isConsequential: false,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Reports are unavailable in this context") }
        let data = try JSONEncoder().encode(arguments)
        var report: ReportCard
        do { report = try JSONDecoder().decode(ReportCard.self, from: data) } catch {
            throw ToolError.invalidArguments("The report doesn't match the format: \(error)")
        }
        if let card = arguments["card"], card != .null {
            let problems = CardCatalog.problems(in: card)
            guard problems.isEmpty else {
                throw ToolError.invalidArguments("The card can't be drawn yet. Fix these and post it again:\n" + problems.map { "- \($0)" }.joined(separator: "\n"))
            }
            report.spec = card
            // Apps from before cards show sections: the card's words go in one, so they see more than the verdict.
            if report.sections.isEmpty { report.sections = [ReportSection(text: CardSpec(card).plainText)] }
        }
        report.id = UUID().uuidString
        report.createdAt = Date()
        try await hooks.postPart(context.taskID, .report(report))
        return .text(ToolCallID("pending"), name: spec.name, "Posted the report card \"\(report.title)\". Reply with one short line; the card already carries the details.")
    }
}
