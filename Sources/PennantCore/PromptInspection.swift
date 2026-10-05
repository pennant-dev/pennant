import Foundation

/// The "How to work" rules every agent gets in its system prompt. The host uses `HostConfig.houseRules` when set,
/// this text otherwise; Settings edits it and offers a reset to this default.
public enum HouseRules {
    public static let `default` = """
    - Finish the whole task. Work out what "done" means, make a short plan, then carry it out step by step with tools until the objective is met and verified. Do routine steps yourself instead of offering them ("Want me to…?", "Say the word and I'll…"); a reply without tool calls ends the task.
    - When an approach fails twice, change it: read the error, try another tool or route (a connected service, the shell, AppleScript, the browser, the UI) instead of repeating the same call. If every route is blocked, say exactly what blocks you and what you need, using ask_user when the user can unblock it.
    - When what the task needs isn't there (a connection, an account, a credential, access you weren't given), say so and ask; don't go looking for secrets (the Keychain, other apps' stores) or build a substitute for what you were asked to use.
    - For email, calendar, Teams, files, social posts and other online services, use the connected service's tools (load them with find_tools) before driving an app's user interface.
    - You can operate this Mac: run shell commands, read and write files, open and control apps, and see the screen. Prefer structured tools (shell, file, browser_read_page, ui_tree, AppleScript) over pixel clicking; use screenshots and clicks when nothing structured fits.
    - Before clicking or typing on screen, take a screenshot or read the ui_tree so you act on the current state. After a consequential GUI action, take a new screenshot to verify the result. Coordinates for clicks are pixels in the most recent screenshot.
    - Say what you verified, not what you assume. If a tool result is uncertain or missing, read the target state back before retrying anything that could duplicate an effect (sending, submitting, paying, deleting).
    - If the user takes over the computer or pauses you, stop, and when resumed, look at the screen again before continuing.
    - Ask the user (ask_user) only when a decision is genuinely theirs or you are blocked. Otherwise make routine judgment calls.
    - Record explicit standing instructions with remember_instruction and durable facts with memory_remember. Search memory before asking for information the user may have given before.
    - When you finish a multi-step procedure that will likely recur, call learn_skill with the steps and checks that made it work.
    - Delegate (delegate_task) only for independent sub-work worth running separately; you remain responsible for verifying the result.
    - When you produce or find a file the user should have (a report, export, document, image), hand it over with share_file; naming a path is not enough for them to see it.
    - When the work is complete, reply with a concise final message: what was done, what was verified, and anything left open. A reply without tool calls ends the task.
    """
}

/// What an agent's model received on one turn, taken apart for reading: the system prompt by section, the
/// conversation history, and the tool definitions, each with an estimated token count.
public struct PromptInspection: Hashable, Codable, Sendable {
    public struct Section: Hashable, Codable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var text: String
        public var tokens: Int
        public init(title: String, text: String, tokens: Int) { self.title = title; self.text = text; self.tokens = tokens }
    }

    public struct Tool: Hashable, Codable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        /// "Built in", or the connected service's name.
        public var service: String
        public var description: String
        public var tokens: Int
        public init(name: String, service: String, description: String, tokens: Int) {
            self.name = name; self.service = service; self.description = description; self.tokens = tokens
        }
    }

    public var agentID: AgentID
    public var agentName: String
    public var capturedAt: Date
    /// True when no turn has run since the host started, and this was assembled the same way for a new task.
    public var isPreview: Bool
    public var model: String
    public var reasoningEffort: String?
    public var sections: [Section]
    public var historyMessages: Int
    public var historyTokens: Int
    public var tools: [Tool]
    /// Connected services not loaded on this turn (they cost nothing until find_tools loads them).
    public var unloadedServices: [String]

    public var systemTokens: Int { sections.reduce(0) { $0 + $1.tokens } }
    public var toolTokens: Int { tools.reduce(0) { $0 + $1.tokens } }
    public var totalTokens: Int { systemTokens + historyTokens + toolTokens }

    /// The system prompt as the model read it.
    public var systemPrompt: String { sections.map(\.text).joined() }

    public init(agentID: AgentID, agentName: String, capturedAt: Date = Date(), isPreview: Bool, model: String, reasoningEffort: String?, sections: [Section], historyMessages: Int, historyTokens: Int, tools: [Tool], unloadedServices: [String]) {
        self.agentID = agentID
        self.agentName = agentName
        self.capturedAt = capturedAt
        self.isPreview = isPreview
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.sections = sections
        self.historyMessages = historyMessages
        self.historyTokens = historyTokens
        self.tools = tools
        self.unloadedServices = unloadedServices
    }
}
