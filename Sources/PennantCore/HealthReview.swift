import Foundation

/// Pennant's health review: a daily job on the agent you talk to that reads how its runs, skills and jobs are doing
/// and proposes fixes; the owner approves each one on a card before anything changes. Only the owner turns it on
/// (`pennant health enable`), because it grants the review tools, which nothing has otherwise.
public enum HealthReview {
    /// The review tools, granted by the owner.
    public static let grantedTools = ["health_report", "recent_failures", "skill_stats", "agent_details", "propose_agent_change", "propose_skill_change", "propose_code_change"]

    public static let jobName = "Pennant health · daily"
    public static let jobSchedule = "daily at 08:00"
    /// The job carries the whole review, so it works without a skill installed.
    public static let jobPrompt = "The daily health review.\n\n" + instructions

    public static let instructions = """
    Review how this Pennant is working: its runs, the helpers it brings in, its coding runs, its skills and the jobs it runs on a schedule. You change nothing yourself here. Every change is a proposal the owner approves on a card.

    1. Call health_report for the last day. On Mondays, or when asked for the week, use 7 days.
    2. Look into whatever stands out: failed or cancelled tasks, tool calls that keep failing or are refused, slow replies (a median over a minute, or a slowest 10% over three minutes), model warnings, a skill that works less than 60% of the time, a scheduled job whose runs keep failing or keep ending in a question. Use recent_failures, agent_details, skill_stats and list_schedules to find out why. Tell one-off trouble (a service was down once) from a pattern (the same failure three or more times).
    3. For each pattern Pennant itself can fix, propose the fix:
       - propose_skill_change: a clearer new version of a skill, or disabling one that keeps failing. When a kind of work keeps going wrong, a clearer skill is usually the fix.
       - propose_agent_change with change "instructions": the complete new instructions, the current ones with your change worked in, never a fragment. Or the role or style.
       In "why", say what you saw, how often, one or two examples, and what the change should fix. At most three proposals a day. Don't propose again what the owner rejected unless there's new evidence; memory_search for earlier decisions and memory_remember the ones you get.
    4. Hand-offs matter as much as failures: a result from a helper or a coding run that came back unusable (it pointed at a report card or "above"), or the same work handed over again, means it got lost on the way. When it happens more than once it's usually Pennant's own code (how results travel back), so propose the code fix; if the instructions cause it, propose that change.
    5. For a bug or limit in Pennant's own code (an error that comes from Pennant rather than from the instructions, a skill or a service), propose_code_change: the problem with examples, the numbers, and the fix you'd suggest. If approved, a coding run makes it on a branch for the owner to review. At most one code change a day, and only for a pattern, not a one-off.
    6. For problems no proposal can fix (a service down, a model's quota, an expired sign-in), say so in the report with what the owner should do.
    7. Post the review with post_report: title "Pennant health", a one-line verdict, status good, watch or bad, stat tiles (tasks, failed, median reply, cost), a short table of the skills used (uses, how often they worked) and the scheduled jobs that ran (last outcome), and items for what you proposed and what needs the owner.

    Claim only what your tools showed, and say which (health_report, recent_failures, a memory with its date). Never say someone confirmed or checked something unless you saw it, and don't count a memory about something else as evidence. Keep the report short: the owner reads it on a phone.
    """
}
