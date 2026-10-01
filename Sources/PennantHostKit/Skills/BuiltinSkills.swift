import PennantCore
import Foundation

/// Skills that ship with Pennant. Seeded once per version; the user can disable but not delete them.
public enum BuiltinSkills {
    public static let version = 1

    public static var all: [Skill] {
        [
            Skill(name: "Schedule a recurring job", purpose: "Run a prompt or a skill on a schedule.", applicability: "When the user says 'every', 'daily', 'each morning', 'remind me', 'check X regularly', or asks for a job to run later.", steps: [
                SkillStep(instruction: "Turn the user's timing into a schedule expression: 'every 15m', 'hourly', 'daily at 09:00', 'weekdays at 08:30', 'weekly on mon,thu at 18:00', 'monthly on 1 at 07:00', 'once at 2026-10-01 09:00', or 5-field cron.", check: "The expression is one of the supported forms."),
                SkillStep(instruction: "If the job should follow an existing procedure, call find_skill to get its id.", tool: "find_skill", check: "A skill id is known, or none is needed."),
                SkillStep(instruction: "Call schedule_job with a clear name, the expression, a self-contained prompt (it runs without this conversation), and the skill id if any.", tool: "schedule_job", check: "The reply shows the next run time."),
                SkillStep(instruction: "Tell the user the job name, its next run, and that runs appear in a conversation named after the job.", check: "The user can find the job in Schedules."),
            ], expectedResult: "A job in Schedules with a next run time; runs create tasks for this agent.", failureConditions: ["An invalid expression: the tool reports the accepted forms; fix and retry.", "A prompt that depends on this conversation: make it self-contained."], status: .validated, origin: "builtin", body: "Jobs run in the host even when no app is open. Missed runs older than six hours are skipped, not caught up."),

            Skill(name: "Fill a web form", purpose: "Fill and submit a form in Safari, Chrome, or Edge using the page's own controls.", applicability: "Sign-ups, contact forms, checkout details, settings pages.", steps: [
                SkillStep(instruction: "Open the page (open_url) and confirm it loaded with browser_read_page.", tool: "browser_read_page", check: "The page title and text match the target."),
                SkillStep(instruction: "Call browser_read_page with include_forms true to list the fields with labels, current values, and selectors.", tool: "browser_read_page", check: "The fields you need are listed with selectors."),
                SkillStep(instruction: "Search memory for the values (name, email, company) before asking the user.", tool: "memory_search", check: "Values are known or a single ask_user gathers the missing ones."),
                SkillStep(instruction: "Call browser_fill once per field; for selects pass the option text; for checkboxes pass checked.", tool: "browser_fill", check: "Each reply says Filled with the intended value."),
                SkillStep(instruction: "Re-read the form with include_forms to confirm values, then submit with browser_fill's submit_selector or a click, and verify the confirmation page.", tool: "browser_read_page", check: "A confirmation message or next step is visible."),
            ], expectedResult: "The form is submitted with the right values and the confirmation is verified.", failureConditions: ["JavaScript from Apple Events is disabled in the browser: enable it once in View › Developer (Chrome) or Develop (Safari), or fall back to ui_tree and clicks.", "Fields inside iframes are not reachable this way; use ui_tree or screenshots."], status: .validated, origin: "builtin", body: "Never submit payment or irreversible forms without the user's explicit confirmation of the values."),

            Skill(name: "Research a topic and write a brief", purpose: "Gather facts from several pages and write a short, sourced brief as a file.", applicability: "When asked to look something up, compare options, or prepare a summary.", steps: [
                SkillStep(instruction: "Write down the question and what a good answer needs.", check: "Three to five concrete sub-questions."),
                SkillStep(instruction: "For each source: open_url, then browser_read_page to extract the relevant text; note the URL.", tool: "browser_read_page", check: "At least two independent sources per key claim."),
                SkillStep(instruction: "Record durable facts with memory_remember (people, products, dates) so later work can reuse them.", tool: "memory_remember", check: "Entities exist with sources."),
                SkillStep(instruction: "Write the brief with write_file: summary, findings with source URLs, open questions.", tool: "write_file", check: "The file exists and read_file shows the content."),
                SkillStep(instruction: "Reply with the path and the three most important findings.", check: "The user can open the file."),
            ], expectedResult: "A Markdown brief on disk with sourced findings.", failureConditions: ["Paywalled or login-only pages: say so instead of guessing."], status: .validated, origin: "builtin", body: ""),

            Skill(name: "Inspect an app's interface", purpose: "Find and operate controls in a Mac app reliably using the accessibility tree instead of guessing pixels.", applicability: "Any native app or browser when a click target is not obvious.", steps: [
                SkillStep(instruction: "activate_app the target, then call ui_tree with a modest max_depth.", tool: "ui_tree", check: "Controls with titles and positions are listed."),
                SkillStep(instruction: "Prefer ui_action (press) or ui_set_value on the listed index over pixel clicks.", tool: "ui_action", check: "The control responds; a screenshot confirms."),
                SkillStep(instruction: "If the tree is empty for a Chromium browser, call ui_tree again after a second; the host enables web accessibility on the first read.", tool: "ui_tree", check: "Web content nodes appear."),
            ], expectedResult: "The intended control was operated and verified.", failureConditions: ["Apps that draw their own UI (games, some Electron apps) expose nothing: fall back to screenshots and clicks."], status: .validated, origin: "builtin", body: ""),

            Skill(name: "Import skills from another harness", purpose: "Bring SKILL.md skills from Claude Code, Codex, or other Agent Skills folders into Pennant.", applicability: "When the user mentions skills they already have elsewhere.", steps: [
                SkillStep(instruction: "Call import_skills with no path to list known locations, or with a folder path to import it.", tool: "import_skills", check: "The reply lists imported skills or the locations found."),
                SkillStep(instruction: "Report what was imported and any warnings; suggest find_skill to use them.", check: "The user knows the new skill names."),
            ], expectedResult: "Imported skills appear in Skills with origin Imported.", failureConditions: ["No SKILL.md under the path: ask the user for the right folder."], status: .validated, origin: "builtin", body: ""),
        ]
    }

    /// Insert missing built-ins (by name) and refresh them when the built-in version changes.
    public static func seed(store: any StoreProtocol, eventBus: EventBus) async {
        let stored = (try? await store.setting("builtinSkillsVersion")).flatMap { Int($0) } ?? 0
        let existing = (try? await store.listSkills(includeDisabled: true)) ?? []
        for template in all {
            if let current = existing.first(where: { $0.origin == "builtin" && $0.name == template.name }) {
                guard stored < version else { continue }
                var updated = template
                updated.id = current.id
                updated.status = current.status == .disabled ? .disabled : template.status
                updated.outcomes = current.outcomes
                updated.evidenceTaskIDs = current.evidenceTaskIDs
                updated.createdAt = current.createdAt
                try? await store.upsertSkill(updated)
                if let e = try? await store.appendEvent(.skillUpserted(updated)) { await eventBus.publish(e) }
            } else if !existing.contains(where: { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }) {
                try? await store.upsertSkill(template)
                if let e = try? await store.appendEvent(.skillUpserted(template)) { await eventBus.publish(e) }
            }
        }
        try? await store.setSetting("builtinSkillsVersion", value: String(version))
    }
}
