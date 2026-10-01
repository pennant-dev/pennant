import PennantCore
import Foundation

/// Turns a recorded demonstration into a provisional skill: the model reads the steps (apps, named controls,
/// typing, shortcuts, the user's notes) and writes a procedure an agent can follow with its own tools.
/// The raw demonstration is kept in the skill's instructions, so `use_skill` shows the agent exactly what the
/// user clicked.
enum SkillDrafter {
    enum DraftError: Error, CustomStringConvertible {
        case emptyDemonstration
        case unreadable(String)
        var description: String {
            switch self {
            case .emptyDemonstration: return "Nothing was recorded. Start teaching, do the task, then stop."
            case .unreadable(let why): return "The model’s draft could not be read (\(why)). Try drafting again."
            }
        }
    }

    static let toolNames = "open_app, activate_app, list_apps, open_url, click, double_click, right_click, drag, scroll, type_text, press_key, wait, screenshot, ui_tree, ui_action, ui_set_value, browser_read_page, browser_fill, run_applescript, run_jxa, shell, read_file, write_file, list_directory"

    static func messages(goal: String, session: TeachingSession) -> [ModelMessage] {
        let system = """
        You turn a person's demonstration of a task on their Mac into a reusable skill for an AI agent that \
        operates the same Mac with tools (\(toolNames)). The agent sees the screen through screenshots and the \
        Accessibility tree (ui_tree lists controls by role and label; ui_action presses one).

        The demonstration lists what the person did, in order: apps they switched to, the control each click \
        landed on (role and label as Accessibility reports them, or a position inside the window when nothing \
        names it), text they typed, keys and shortcuts, and notes they wrote to explain themselves. Notes are \
        authoritative: they say what matters and why.

        Write the procedure so it works next time, not just this once:
        - Keep the order and the exact control labels, menu paths and shortcuts. Prefer a shortcut or menu path \
        over a click when the person used one.
        - Leave out slips: clicks that led nowhere, text they deleted, repeated attempts, scrolling that only looked around.
        - Values that will change between runs (file names, search words, recipients) become inputs; name them in \
        "inputs" and write {{name}} in the steps.
        - Give every step a check the agent can observe: a window or sheet appears, a label changes, a file exists.
        - Where the person waited (a countdown, a loading page), say what to wait for, not how long.
        - Only add steps that were not demonstrated when the procedure clearly needs them (a wait or a check).
        - "tool" is the tool that fits the step best, or omitted.

        Answer with one JSON object and nothing else:
        {"name": "short title", "purpose": "one sentence", "applicability": "when to use it",
         "prerequisites": ["…"], "inputs": ["…"],
         "steps": [{"instruction": "…", "check": "…", "tool": "…"}],
         "expected_result": "…", "failure_conditions": ["…"]}
        """
        let user = """
        The person said they would show: \(goal.isEmpty ? "(no goal given)" : goal)

        Demonstration (\(session.events.count) steps, seconds since start):
        \(session.transcript)
        """
        return [.system(system), .user(user)]
    }

    /// Parses the model's answer into a skill. Tolerates code fences and prose around the JSON object.
    static func skill(from text: String, goal: String, session: TeachingSession) throws -> Skill {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw DraftError.unreadable("no JSON object")
        }
        let json = String(text[start ... end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DraftError.unreadable("invalid JSON")
        }
        func string(_ key: String) -> String { (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func strings(_ key: String) -> [String] {
            (object[key] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        }
        let steps: [SkillStep] = (object["steps"] as? [Any] ?? []).compactMap { item in
            if let s = item as? String { return s.isEmpty ? nil : SkillStep(instruction: s) }
            guard let o = item as? [String: Any], let instruction = (o["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty else { return nil }
            let tool = (o["tool"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SkillStep(instruction: instruction, tool: tool, check: (o["check"] as? String) ?? "")
        }
        guard !steps.isEmpty else { throw DraftError.unreadable("no steps") }
        var name = string("name")
        if name.isEmpty { name = goal.isEmpty ? "Taught skill" : String(goal.prefix(60)) }
        let purpose = string("purpose").isEmpty ? goal : string("purpose")
        return Skill(
            name: name,
            purpose: purpose,
            applicability: string("applicability"),
            prerequisites: strings("prerequisites"),
            inputs: strings("inputs"),
            steps: steps,
            expectedResult: string("expected_result"),
            failureConditions: strings("failure_conditions"),
            status: .provisional,
            origin: "taught",
            body: reference(goal: goal, session: session)
        )
    }

    /// The instructions section: where the skill came from and the raw demonstration, so the agent can see the
    /// exact labels the person clicked when a step is ambiguous.
    static func reference(goal: String, session: TeachingSession) -> String {
        let date = session.startedAt.formatted(date: .abbreviated, time: .shortened)
        return """
        Taught by demonstration on \(date). The person showed: \(goal.isEmpty ? "(no goal given)" : goal)

        The steps above are the procedure. When one is unclear, the recorded demonstration below shows exactly \
        what the person did (control labels as Accessibility reported them). Positions are fractions of the window.

        ## Recorded demonstration
        \(session.transcript)
        """
    }
}
