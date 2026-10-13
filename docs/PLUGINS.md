# Plugins: a design (draft)

Plugins for Pennant, with a marketplace from the start. A plugin is a small signed program that runs beside Pennant,
talks to it both ways, and can use as much of Pennant as its owner grants: secrets, the chat, approval cards, tasks,
memory, the screen, events, and screens of its own.

Status: phase 1 is under way. Built: the plugin kit (`Sources/PennantPluginKit`: manifests, the channel, processes,
the sandbox), the SDK (`Sources/PennantPluginSDK`), Pennant's side for tools, secrets, credential helpers, settings,
storage and chat posts (`Sources/PennantHostKit/Plugins`), `asksFirst`, `pennant plugin …`, the Plugins page in the apps, and the Azure plugin (`Plugins/Azure`). Not
yet: threads, tasks, memory and events for plugins, panels drawn by plugins, the marketplace.
How to build and install one: docs/RUNBOOK.md › Plugins.

## Goals

- **Full, two-way access.** A plugin calls into the host (read a secret, post in the chat, put up a card, start a
  thread, search memory) and the host calls into the plugin (run its tool, draw its panel, deliver an event).
- **A marketplace.** Anyone can publish; anyone can install from inside the app, on a Mac that came with the downloaded
  app. Nothing needs a rebuild.
- **A core kept apart.** The plugin machinery (running plugins, the channel, grants, the UI renderer, the
  marketplace) is its own module, separate from Pennant's APIs. Pennant is the only host; the separation keeps the core
  small and testable, and leaves the door open to other apps later without designing for them now.
- **Safe by construction.** A plugin can't do more than it was granted, every use is logged, and Pennant's sign-off
  rules (publishing or sending, deleting, spending) apply to plugins exactly as to everything else.
- **Native everywhere.** Plugin screens look like the host's own on the Mac and the iPhone, and the iPhone runs no
  plugin code.

Not goals, for now: other host apps, paid plugins, other platforms (Windows, Linux), plugin-to-plugin calls.

## Why plugins run beside the app, not inside it

The obvious design is a Swift library loaded into the app. For a marketplace it can't work:

- **macOS** loads code into a notarized, hardened app only when the same developer signed it. Loading someone
  else's plugin means switching that protection off for the whole app.
- **iPhone** apps may not download and run new code at all.
- **Trust.** Code in the host's process can read every Keychain item and file the host can, and can skip the gates
  that make Pennant safe to leave running. A stranger's plugin would have all of that, silently.
- **Crashes.** A plugin's bug would take the host down with it.

So each plugin is its own process, sandboxed, and everything privileged goes through the host. To its author it doesn't
feel remote: the SDK makes every host call an ordinary `async` Swift call. VS Code works the same way, and so does
Raycast.

## The pieces

```
  Pennant host (pennant-host)
  ┌──────────────────────────────────────────┐
  │ Pennant's plugin API                     │
  │  chat, threads, cards, tasks, memory,    │
  │  tools, model, desktop, browser          │
  ├──────────────────────────────────────────┤
  │ PluginHost (its own module)              │
  │  manifests · processes · channel ·       │
  │  grants · audit · UI · marketplace       │
  └───────────┬──────────────────┬───────────┘
              │ JSON-RPC over stdio, both ways
       ┌──────┴──────┐    ┌──────┴──────┐
       │ plugin A    │ …  │ plugin B    │   sandboxed processes
       │ (PluginSDK) │    │ (PluginSDK) │
       └─────────────┘    └─────────────┘
```

- **PluginHost**: the plugin machinery, a module of its own. It reads manifests, launches and supervises plugin
  processes, runs the channel, enforces grants, keeps the audit log, renders plugin UI, and talks to the marketplace.
  It knows nothing about chats or tasks.
- **Pennant's plugin API**: what plugins can ask Pennant for, and where their UI can go, registered with PluginHost.
  It lives in the host process (`pennant-host`) and wraps what already exists there.
- **PluginSDK**: the Swift package plugin authors use: typed host calls, tool and UI builders, a test harness.
- **The marketplace**: a signed index of plugins, their versions and what they ask for.

## A plugin, on disk

A plugin is a signed bundle:

```
GitHubDashboard.plugin/
  Contents/
    Info.plist                 bundle id = the plugin's id
    MacOS/GitHubDashboard      universal executable, Developer ID, notarized, App Sandbox
    Resources/
      plugin.json              the manifest
      icon.png
      web/                     optional: web panels (later phase)
```

The manifest says what the plugin is, where it runs, what it needs, and what it adds:

```json
{
  "id": "dev.example.github-dashboard",
  "name": "GitHub Dashboard",
  "version": "1.2.0",
  "publisher": "Example",
  "description": "Your open pull requests and failing checks, at a glance and on request.",
  "api": "1",
  "pennant": ">=0.5",
  "capabilities": [
    { "secret": "github-token", "why": "Reads your pull requests and checks." },
    "network",
    "chat.post",
    "ui.panels"
  ],
  "contributes": {
    "tools": [
      { "name": "open_pull_requests", "description": "List my open pull requests and their checks.",
        "inputSchema": { "type": "object", "properties": { "repo": { "type": "string" } } },
        "readOnly": true }
    ],
    "panels": [ { "id": "summary", "title": "Pull requests", "places": ["home.tile", "sidebar"] } ],
    "settings": { "type": "object", "properties": { "repos": { "type": "array", "items": { "type": "string" } } } }
  },
  "activation": ["onTool", "onPanel"]
}
```

`pennant` is the range of Pennant versions it works with; the marketplace only offers it to those.

## Running a plugin

- **Start.** The host launches the executable with pipes for stdin and stdout, the same way Pennant runs its voice
  helper and MCP servers today. No ports, nothing to authenticate (only the host holds the pipes), and the process
  ends when the host does.
- **Handshake.** `initialize` carries the API version, the host's name and version, the capabilities granted (which
  can be fewer than asked), and the plugin's settings. The plugin answers with what it's ready to do.
- **On demand.** `activation` says when the plugin needs to be running: when one of its tools is called, when one of its panels
  is shown, on an event it subscribed to, or always (a background watcher). It's stopped again after a quiet spell.
- **Supervision.** A crashed plugin restarts with backoff. After repeated crashes it's turned off, with a notice to the
  owner. Calls time out. Each plugin's stderr goes to the host log under its id.

## The channel

JSON-RPC 2.0 over the pipes. Both sides send requests, replies and notifications, and either can have many in flight.
It's an open protocol, so plugins can be written in any language, but the SDK is Swift-first.

**The host calls the plugin:**

| Method | What for |
| --- | --- |
| `tool/call` | Run one of its tools with the model's arguments. Returns text, or Pennant's own message parts (a report, a file). |
| `panel/render`, `panel/action` | Draw a panel; a button was pressed or a field changed. |
| `event` | Something it subscribed to happened. |
| `settings/changed`, `shutdown` | Housekeeping. |

**The plugin calls Pennant.** The basics:

| Namespace | Calls | Capability |
| --- | --- | --- |
| `secrets` | `get(slot)` returns the vault item the owner mapped to that slot (its username, password, secret) | `secret: <slot>` |
| `credentials` | `get(name)` runs the command the owner approved for that helper (say `az account get-access-token`) and returns its output, cached until it expires | `credential: <name>` |
| `storage` | Its own key-value store and a private folder | always |
| `settings` | Read its settings (the owner edits them in the host's UI, from the manifest's schema) | always |
| `ui` | `update(panel)`, `toast(text)` | `ui.panels` |
| `notify` | A notice in Pennant, or a push to the owner's iPhone | `notify` |
| `events` | `subscribe(topics)` | per topic |
| `log` | Write to the host log | always |

And Pennant's own:

| Namespace | Calls | Builds on |
| --- | --- | --- |
| `chat` | Post a message or a card into the Pennant chat or a thread | `postPart`, `ContentPart` |
| `threads` | Start a thread, message it, read it | `ThreadHooks` |
| `cards` | Ask the owner on an approval card; the decision comes back as an event | `ApprovalRequest`, `postApproval` |
| `tasks`, `jobs`, `goals` | Start work, schedule a job, read and update goals | `RuntimeHooks`, scheduler, goals |
| `memory` | Search, remember | memory service |
| `model` | Ask the owner's model, within a budget | the inference provider |
| `desktop` | Look at the screen, click, type: only while holding the desktop lease | `DesktopLease` |
| `browser` | Work in Pennant's own Chrome tabs | the browser link |
| `files` | Read or write paths the owner granted | sandbox plus host |

Most of Pennant's side already exists: the apps, the iPhone app and the CLI drive the host through the same kinds of
command today (`docs/PROTOCOL.md`). The plugin channel is a narrower, grant-checked door to it.

## Signing in to other services

A plugin that works with another service (Azure, AWS, Google Cloud, Kubernetes) can sign in two ways, and the owner
picks at install:

- **Stored credentials.** A secret slot ("azure-service-principal") filled from the Vault: a client id and secret, a
  token, a key. Portable, and as narrow as the credential (a read-only role, say).
- **A credential helper.** The manifest suggests a command that prints a token (`az account get-access-token
  --resource https://management.azure.com/ -o json`). The owner sees it, can change it, and approves it. Pennant runs
  it outside the plugin's sandbox, as the owner, with the sign-ins already on the Mac (behind WARP or a VPN too), and
  hands the plugin only the output. The plugin can't change the command or run anything else. One helper per audience.

## Tools for the model

A plugin's tools join the tool broker with the source `plugin:<id>`, next to the built-in tools and the connections'
(`mcp:<server>`) tools. The model learns them like any other: they're found with `find_tools` or loaded with the plugin.

- **The sign-off rules still apply.** Pennant's classifier (`SignOff`) looks at every call. A plugin tool that publishes,
  sends, deletes or spends goes through a card, whatever its manifest says. A manifest can declare `readOnly`; it can't
  declare itself exempt.
- **Always ask.** A tool can declare `asksFirst`: it changes something the classifier wouldn't catch (scale a node
  pool, restart an app), so every call waits on a card that says "Changes something". Built-in tools can use the flag
  too.
- **The plugin's own calls are checked too.** A plugin that sends a message through `chat` or a connection, or acts on
  the desktop, meets the same gates as the agent would.
- **Desktop tools** need the lease, and the owner's mouse takes it back, as for built-in tools.

## Permissions and trust

- **Asked at install.** The install sheet lists each capability in plain words, with the plugin's `why`. A secret is a
  named slot ("github-token"); the owner picks which vault item fills it, or creates one. Nothing is granted by default.
- **Re-asked on change.** An update that asks for more waits for the owner. One that asks for less installs itself.
- **Logged.** Every host call is recorded with its plugin, capability and time, its arguments redacted. Settings ›
  Plugins shows the log, and a plugin's grants can be withdrawn there at any time.
- **Contained.** The executable must be signed with the App Sandbox entitlement and only the entitlements its
  capabilities justify (`network.client` for `network`, nothing else). The host checks the signature, notarization and
  entitlements before every launch. A plugin reaches the owner's files, Keychain and screen only through the host.
- **Owners only.** In Pennant, only an owner installs plugins or grants capabilities. Members see what owners installed.
- **Secrets stay put.** A secret's value goes only to the plugin granted its slot, is redacted from the host's logs,
  and never reaches the Mac or iPhone apps.

## Plugin UI

A plugin's screens are **data**: a tree of components that the host draws with its own design system. Plugins look
native in every host, on the Mac and the iPhone, and the iPhone never runs plugin code.

- **Components.** Section, text and Markdown, stat (the `ReportStat` the reports already use), table, list, line and
  bar chart, image, progress, status badge, and buttons and form fields (text, toggle, choice). Pennant's report
  cards (`ReportCard`) are a subset already, so the renderer starts from them.
- **Places.** A tile on Home, a page in the sidebar, a card in the chat, a pane in Settings.
- **Live.** A plugin pushes a new tree with `ui.update` when its data changes. A button or a field sends
  `panel/action` back to the plugin, which answers with the next tree.
- **Settings for free.** The manifest's settings schema becomes a form in the host's Settings, with no UI code.
- **Web panels, later.** For screens the components can't express, a sandboxed web view with the plugin's own HTML,
  compatible with MCP Apps, on the Mac and the iPhone (web content is allowed there).

## The marketplace

- **Index.** A signed list of plugins, their versions, the Pennant versions they need, capabilities, download address
  and checksum, served from pennant.dev and mirrored in a public git repository. Pennant fetches it, checks the
  marketplace's signature, and shows it in an in-app browser.
- **Packages.** Each version is a zip of the bundle, hosted where the publisher likes (a GitHub release, say),
  signed with the publisher's key, and notarized by Apple under the publisher's Developer ID.
- **Install.** Listing → install sheet (capabilities, secret slots) → download → verify (checksum, publisher's signature,
  Apple's notarization, sandbox entitlements) → install under `<data>/plugins/<id>/<version>/` → activate.
- **Updates.** Checked daily, alongside the app's own. Same capabilities or fewer: installed quietly. More: the owner
  decides.
- **Revocation.** A signed revocation list is fetched with the index. A revoked plugin is stopped and turned off at
  once, and the owner is told why.
- **Review.** Publishing is a pull request to the index. Automated checks run first: manifest, signature,
  notarization, entitlements and capabilities that match what the code links. A person reviews plugins that ask for
  secrets, the desktop, sending or spending before they're listed.
- **Unlisted and private.** `plugin install <folder or URL>` installs one that isn't listed, with a warning. A company
  can run its own index.

## Writing a plugin

```swift
import PluginSDK

@main
struct GitHubDashboard: Plugin {
    @Secret("github-token") var token
    @Setting var repos: [String] = []

    /// List my open pull requests and their checks.
    @Tool(readOnly: true)
    func openPullRequests(repo: String?) async throws -> Report {
        let prs = try await GitHub(token: token).openPullRequests(in: repo.map { [$0] } ?? repos)
        return Report("Open pull requests") { Table(prs) { [$0.title, $0.checks] } }
    }

    func panel(_ id: PanelID, context: PanelContext) async throws -> Panel {
        let prs = try await GitHub(token: token).openPullRequests(in: repos)
        return Panel {
            Stat("Open", prs.count)
            Stat("Failing", prs.filter(\.failing).count, status: prs.contains(where: \.failing) ? .bad : .good)
            Button("Ask Pennant to look") { try await context.chat.post("Look at my failing pull requests.") }
        }
    }
}
```

- **`@Tool`** turns a method and its doc comment into a tool with a JSON schema, from the Swift types.
- **The panel builder** reads like SwiftUI and produces the component tree.
- **The command line:** `plugin new` (a template), `plugin dev` (build, run against your own host, reload on save,
  logs in the terminal), `plugin test` (a fake host for unit tests), `plugin pack` (sign, notarize, zip),
  `plugin publish` (open the pull request to the index).

## Versions

The API has a version per namespace. A manifest names the API it was built against and the Pennant versions it
supports. Pennant keeps the previous major version working for a release cycle, and the SDK warns on anything
deprecated.

## Pennant's own tools

Built-in tools move to plugins where that proves the API without risk: the Reddit and LinkedIn connectors first. The
core (the shell, files, the desktop, the chat itself) stays in the host.

## Phases

1. **The core, proved by an Azure plugin.** The plugin module (manifests, processes, the two-way channel), grants and
   the audit log; Pennant's side for tools, secrets, credential helpers, settings, storage and chat posts; the
   `asksFirst` flag; `pennant plugin install|list|grant|enable|disable|remove`; the SDK. The Azure plugin works across
   subscriptions with both sign-ins: find resources, costs, AKS clusters, log queries and firing alerts, plus scaling a
   node pool and restarting an app behind a card. Threads, tasks, memory and events follow in the same phase.
2. **Screens.** The component renderer on the Mac and the iPhone; Home tiles, sidebar pages, chat cards and settings
   forms.
3. **The marketplace.** Signed index, publisher keys, notarization and entitlement checks, the in-app browser,
   updates, revocation, the review flow.
4. **The rest.** Web panels; the desktop and browser capabilities; background plugins.

## Open questions

- **Names** for the SDK and the marketplace, and where the index lives (pennant.dev, or a subdomain).
- **Review:** who reviews, and how fast.
- **Paid plugins:** later, if ever, and how.
- **Budgets:** how much of the owner's model a plugin may use, and how that shows on the usage ledger.
