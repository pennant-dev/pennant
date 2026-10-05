import PennantClientKit
import PennantCore
import Foundation

struct CLIOptions {
    var access: String?
    var host = "127.0.0.1"
    var port = 7331
    var token: String?
    var command = ""
    var args: [String] = []

    var endpoint: HostEndpoint { HostEndpoint(host: host, port: port, name: host) }

    static func parse(_ argv: [String]) -> CLIOptions {
        var options = CLIOptions()
        var rest: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            func value() -> String? { i += 1; return i < argv.count ? argv[i] : nil }
            switch a {
            case "--host", "-H": options.host = value() ?? options.host
            case "--port", "-p": options.port = Int(value() ?? "") ?? options.port
            case "--token", "-t": options.token = value()
            // Through Cloudflare Access: the hostname; the Access token comes from PENNANT_ACCESS_TOKEN.
            case "--access": options.access = value()
            default:
                if a.hasPrefix("--host=") { options.host = String(a.dropFirst(7)) }
                else if a.hasPrefix("--port=") { options.port = Int(a.dropFirst(7)) ?? options.port }
                else if a.hasPrefix("--token=") { options.token = String(a.dropFirst(8)) }
                else { rest.append(a) }
            }
            i += 1
        }
        options.command = rest.first ?? "help"
        options.args = Array(rest.dropFirst())
        return options
    }
}

let usage = """
Usage: pennant [--host H] [--port P] [--token T] <command> [args]

  status                     Host info, the agent, active tasks
  agent                      The agent: name, status, role
  agent edit [--name N] [--role R] [--style S] [--instructions-stdin]  Rename it, or change its role, manner or instructions
  coding                     How Pennant writes code: the engine and model, the project folders, how it asks, its GitHub identity
  coding folder <dir> [--name N]  Add a project folder and make it the default
  coding folders | folder remove <name>  List the project folders, or remove one
  coding engine claude-code|pennant  Claude Code (the claude program you signed in to), or Pennant's own engine
  coding model <model>|default  The Settings › Models profile the Pennant engine runs on
  coding mode acceptEdits|manual|auto|plan  How coding runs ask: only sign-offs (default), everything, Claude Code's own check, or a plan first
  coding github --app-id N --installation N --vault ENTRY --slug SLUG | --off  The GitHub App coding runs act as
  health enable              Pennant reviews its own runs, skills and jobs daily and proposes fixes as cards
  threads                    Open threads newest first (! = needs you), and how many are closed
  threads close-after <days|never>  How long a quiet thread stays in the list
  heartbeat [on|off|every <minutes>|cap <n>]  Pennant checking in on its own: whether, how often, how many times a day
  tool <name> [json]         Run one of Pennant's tools by hand (owner only); images it returns are saved here
  send <text…>               Send a message and stream the reply until the task finishes
  tasks                      List tasks
  pause <taskID>             Pause a task
  resume <taskID>            Resume a task
  cancel <taskID>            Cancel a task
  takeover | release         Take or give back desktop control
  watch                      Print every host event until Ctrl-C
  login <email>              Sign in to a host on another Mac (with --host) using your password, and store the session
  channels teams --app-id <guid> --tenant <guid> --url <https://…> [--secret-stdin]  Set up the Teams bot (secret read from stdin)
  screenshot <out.jpg>       Save a screenshot of the host desktop
  artifact save <id|prefix> <out-path>  Save a file an agent shared (or any artifact) to disk; a directory keeps the original name
  memory search <text…>      Search memory
  skills                     List skills
  teach start <goal> | note <text> | stop | draft [goal] | cancel | status
                             Teach a skill by demonstration: record what you do, then draft it
  skills import <folder|url> [--only <name>…]  Import SKILL.md folders or a git repository; --only picks skills by name
  skills preview <folder|url>  Show what an import would add, update, or skip, without writing
  skills folders [add|remove <path>]  Known and remembered skill folders, with kind and origin
  skills delete <id>…        Delete skills by id (prefixes work); built-in skills can only be disabled
  library                    Brand collections and files agents use (find_assets)
  approval <id> approve|changes|reject [comment]  Answer an approval card
  export [--to <folder>] [--passphrase P]  Export this host's Pennant (secrets only with a passphrase, sealed)
  import <folder> [--passphrase P]  Import an export on this host (restarts it; keeps the previous data)
  chrome-signins [<site>… --profile P]  List Chrome profiles, or copy sites' sign-ins into Pennant's browser
  chrome [status | setup [--browser <bundle id>] | forget <site>]
                             Pennant's Chrome extension: whether it's connected; add it to Chrome for you; forget a site
  library add <collection> <file>… [--notes N]  Upload files into a collection (created if new)
  library notes <collection> <text>  Set a collection's usage guidance
  schedules [run <id>]       List scheduled jobs, or run one now
  schedules add "<when>" <prompt…> [--skill S] [--name N]  Schedule a recurring job ("daily at 08:00")
  schedules pin <id|name> <skill|none>  The skill a job always follows
  schedules edit <id|name> [--name N] [--prompt P]  Rename a job or change its prompt
  goals [<title|id>]         List goals, or one goal's board
  goals edit <title|id> [--work W] [--review R] [--status S]  Reschedule a goal or move it (proposed, active, paused, achieved, dropped)
  goals delete <title|id>    Delete a goal with its board and jobs (its conversation stays)
  models [baseURL] [apiKey]  List models served by the configured (or given) endpoint
  permissions [request|reset [target]]  Show macOS grants; request or reset one (accessibility, screenRecording, inputMonitoring, automation, or a bundle id)
  context                    The latest conversation: context size vs window, compactions
  compact                    Fold the latest conversation into a checkpoint now
  mcp [list]                 MCP servers: name, connection state, tools, sign-in state, id prefix
  mcp add <name> <url> [--auth none|key|oauth] [--header H] [--prefix P] [--scopes a,b] [--client-id ID] [--client-secret S]
                             Add an HTTP MCP server (key: header defaults to Authorization with prefix "Bearer ")
  mcp connect <id|name>      Sign in with OAuth: opens the browser and waits for the host to finish (5 min)
  mcp key <id|name> <secret> Store an API key or a pasted token ("-" reads the secret from stdin)
  mcp signout <id|name>      Forget the stored credentials and disconnect
  mcp remove <id|name>       Remove a server and its credentials
  mcp catalog                Servers Pennant knows how to connect to
  chatgpt login              Sign a ChatGPT account in for inference: opens the browser (Codex OAuth) and waits for the host (5 min)
  chatgpt import             Reuse the Codex CLI login on this Mac (~/.codex/auth.json)
  chatgpt status             The signed-in ChatGPT account, plan, and session expiry
  chatgpt logout             Forget the ChatGPT tokens
  chatgpt models             Models your ChatGPT account can use; * marks the configured one
  diag                       Diagnostics report (JSON)
"""
