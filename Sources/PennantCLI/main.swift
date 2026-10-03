import PennantCore
import Foundation

// `pennant`: a small terminal client for the Pennant host, for scripting and diagnostics. `pennant help` lists the
// commands.

@MainActor
func run(_ options: CLIOptions) async throws {
    switch options.command {
    case "help", "-h", "--help":
        out(usage)
    case "export":
        try await exportCommand(options)
    case "import":
        try await importCommand(options)
    case "chrome-signins":
        try await chromeSignInsCommand(options)
    case "chrome":
        try await chromeCommand(options)
    case "approval":
        try await approvalCommand(options)
    case "push":
        try await pushCommand(options)
    case "library":
        try await runLibrary(options.args.first ?? "list", args: Array(options.args.dropFirst()), options: options)
    case "mcp":
        try await runMCP(options.args.first ?? "list", args: Array(options.args.dropFirst()), options: options)
    case "chatgpt":
        try await runChatGPT(options.args.first ?? "status", options: options)
    case "status":
        try await statusCommand(options)
    case "health":
        try await healthCommand(options)
    case "coding":
        try await codingCommand(options)
    case "threads":
        try await threadsCommand(options)
    case "heartbeat":
        try await heartbeatCommand(options)
    case "tool":
        try await toolCommand(options)
    case "agent":
        try await agentCommand(options)
    case "tasks":
        try await tasksCommand(options)
    case "send":
        try await sendCommand(options)
    case "answer":
        try await answerCommand(options)
    case "pause", "resume", "cancel":
        try await taskControlCommand(options)
    case "takeover":
        try await takeoverCommand(options)
    case "release":
        try await releaseCommand(options)
    case "watch":
        try await watchCommand(options)
    case "login":
        try await loginCommand(options)
    case "github":
        try await githubCommand(options)
    case "channels" where options.args.first == "approvals":
        try await channelApprovalsCommand(options)
    case "channels" where options.args.first == "imessage" || options.args.isEmpty:
        try await iMessageCommand(options)
    case "channels":
        try await channelsCommand(options)
    case "artifact":
        try await artifactCommand(options)
    case "screenshot":
        try await screenshotCommand(options)
    case "memory":
        try await memoryCommand(options)
    case "context", "compact":
        try await contextCommand(options)
    case "permissions":
        try await permissionsCommand(options)
    case "models":
        try await modelsCommand(options)
    case "goals":
        try await goalsCommand(options)
    case "schedules":
        try await schedulesCommand(options)
    case "teach":
        try await teachCommand(options)
    case "skills":
        if let sub = options.args.first, ["import", "preview", "folders", "delete"].contains(sub) {
            try await runSkills(sub, args: Array(options.args.dropFirst()), options: options)
            break
        }
        fallthrough
    case "skills-list":
        try await skillsListCommand(options)
    case "diag":
        try await diagCommand(options)
    default:
        fail("Unknown command '\(options.command)'.\n\n" + usage)
    }
}

let options = CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
Task { @MainActor in
    do {
        try await run(options)
        exit(0)
    } catch {
        fail("Error: \(error)")
    }
}
dispatchMain()
