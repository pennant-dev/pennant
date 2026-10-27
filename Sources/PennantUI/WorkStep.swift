import PennantClientKit
import PennantCore
import SwiftUI

/// What a piece of work is doing this moment, in plain words ("Browsing the web", "Running a few commands"), and
/// since when: the step that's running, or the model thinking between steps. So the running line is never just
/// "Working on…" while the owner waits.
enum WorkStep {
    /// Past this long on one step, the line says it's taking longer than usual.
    static let longAfter: TimeInterval = 45

    /// The step a task is on: its running tool, else thinking since its last step ended. Nil when it isn't working.
    static func current(_ task: TaskRecord, records: [ToolRecord], naming: ToolNaming) -> (phrase: String, since: Date)? {
        guard task.state == .running || task.state == .waitingForTool else { return nil }
        if let running = records.last(where: { $0.status == .running || $0.status == .intended }) {
            return (phrase(for: running.call.name, naming: naming), running.startedAt)
        }
        let lastEnd = records.compactMap(\.finishedAt).max()
        return ("Thinking it through", max(lastEnd ?? task.updatedAt, task.usage.startedAt ?? task.updatedAt))
    }

    /// A tool's work in a few everyday words. Connected services (`<service>__<tool>`) go by the service's name.
    static func phrase(for name: String, naming: ToolNaming = ToolNaming()) -> String {
        if let cut = name.range(of: "__") {
            let prefix = String(name[..<cut.lowerBound]), tool = name[cut.upperBound...].lowercased()
            if tool.contains("mail") { return "Checking mail" }
            if tool.contains("calendar") || tool.contains("event") { return "Looking at the calendar" }
            return "Working in \(naming.mcpServerNames[prefix] ?? ToolPresentation.humanised(prefix))"
        }
        switch name {
        case "shell", "Bash": return "Running a few commands"
        case "read_file", "list_directory", "Read", "Grep", "Glob": return "Reading files"
        case "write_file", "edit_file", "Write", "Edit", "MultiEdit": return "Writing files"
        case "code", "propose_code_change": return "Writing code"
        case "start_thread": return "Getting it started"
        case "message_thread": return "Passing it on"
        case "read_thread": return "Checking how it's going"
        case "delegate_task": return "Handing a piece off"
        case "await_task": return "Waiting for a piece to finish"
        case "request_approval": return "Putting it up for your OK"
        case "send_message": return "Sending a message"
        case "share_file": return "Sending you a file"
        case "find_tools": return "Getting the right tools ready"
        case "memory_search": return "Checking what I know"
        case "memory_remember", "remember_instruction": return "Making a note"
        case "use_skill", "find_skill": return "Looking up how it's done"
        case "ask_user": return "Asking you"
        case "wait": return "Waiting a moment"
        case "WebFetch", "WebSearch", "open_url", "render_html": return "Browsing the web"
        default:
            if name.hasPrefix("web_") || name.hasPrefix("browser_") { return "Browsing the web" }
            if name.hasPrefix("app_") || name.hasPrefix("ui_") || ["screenshot", "click", "double_click", "right_click", "move_mouse", "drag", "scroll", "type_text", "press_key", "open_app", "activate_app", "list_apps", "run_applescript", "run_jxa"].contains(name) {
                return "Working on your Mac"
            }
            if name.hasPrefix("schedule_") || name.hasPrefix("goal_") || name.hasSuffix("_schedule") || name.hasSuffix("_goal") { return "Sorting out the plan" }
            return "Working on it"
        }
    }

    /// "0:12", "3:05", "1:02:40".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// "· Browsing the web · 0:12", ticking, with "taking longer than usual" once the step runs long.
struct WorkStepLabel: View {
    var phrase: String
    var since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(since)
            Text("· \(phrase) · \(WorkStep.clock(elapsed))\(elapsed > WorkStep.longAfter ? " · taking longer than usual" : "")")
                .font(.zoomed(.callout).monospacedDigit())
                .foregroundStyle(PennantTheme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText())
        }
    }
}
