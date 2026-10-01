import PennantCore
import Foundation

/// Posts a structured report into the conversation as a card: a verdict, then sections of number tiles, tables,
/// lists and short text. For daily status reports, run summaries and anything with a verdict and a few numbers.
public struct PostReportTool: Tool {
    public init() {}

    static let statusDoc = "good | watch | bad | neutral"

    public var spec: ToolSpec {
        let status = JSONSchema.string("Status colour: \(Self.statusDoc).")
        return ToolSpec(
            name: "post_report",
            description: """
            Post a report as a card in the conversation instead of a wall of text: a title, a one-line verdict with a status colour, then sections. Each section may have a short Markdown paragraph (text), number tiles (stats: label, value, optional detail and status), a table (columns and rows; a cell is a string or {text, status}), and a list (items: text, optional detail and status), drawn in that order. Keep tiles to the numbers that matter, tables to one row per thing, lists to one line each with the detail underneath. After posting, reply with one short line; don't repeat the report.
            """,
            inputSchema: JSONSchema.object([
                "title": JSONSchema.string("What this is: \"Infrastructure · Thursday 24 Sep\"."),
                "subtitle": JSONSchema.string("Optional second line (scope, period)."),
                "verdict": JSONSchema.string("The answer in one line: \"Healthy with 2 things to watch\"."),
                "status": status,
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
        report.id = UUID().uuidString
        report.createdAt = Date()
        try await hooks.postPart(context.taskID, .report(report))
        return .text(ToolCallID("pending"), name: spec.name, "Posted the report card \"\(report.title)\". Reply with one short line; the card already carries the details.")
    }
}
