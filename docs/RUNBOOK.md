# Runbook

## Data and configuration

Everything the host owns lives in `~/Library/Application Support/Pennant`:

| File | Purpose |
| --- | --- |
| `pennant.sqlite` (+ `-wal`, `-shm`) | The database: events, agents, conversations, messages, tasks, tool records, checkpoints, memory graph, preferences, skills, MCP servers, settings. |
| `artifacts/` | Screenshots and files referenced by messages and memory. |
| `config.json` | `HostConfig`. Created on first run; edited by the Mac app's Settings. |
| `client-token` | 0600 file with the loopback token the Mac app and CLI use. |
| `logs/host.log` | Text log (rotated at 20 MB). |
| `keychain-fallback.json`, `mcp-credentials.json`, `chatgpt-credentials.json` | Only used when the Keychain is unavailable (tests). |

Backup: `SQLiteStore.backup(to:)` uses the SQLite online backup API and copies `artifacts/` alongside, so a copy taken while the host runs is consistent. Restore by stopping the host and replacing the directory.

## Command line

```
pennant-host [--root <dir>] [--port <n>] [--endpoint <url>] [--model <name>] [--mode everyday|dedicated] [--no-api]
pennant [--host H] [--port P] [--token T] status|agent|threads|send|tasks|pause|resume|cancel|takeover|release|watch|login|coding|health|screenshot|artifact|memory|skills|schedules|mcp|chatgpt|…
```

`pennant help` lists every command. `pennant` reads the token from `client-token` for loopback hosts, or from its Keychain entry after `pennant login <email>` against a host on another Mac.

## Inference endpoint

The adapter speaks the OpenAI chat-completions protocol with streaming. It sends `tools` in function format, images as `data:` URLs inside user messages, and expects tool calls back as `tool_calls` deltas. Reasoning arrives as `delta.reasoning_content` (DeepSeek) or `delta.reasoning` (Ollama) and is shown collapsed in the UI.

DeepSeek V4 Flash Vision on vLLM needs native tool parsing enabled, for example:

```
vllm serve deepseek-ai/DeepSeek-V4-Flash-Vision-Exp \
  --enable-auto-tool-choice --tool-call-parser deepseek_v3 \
  --reasoning-parser deepseek_r1 --max-model-len 131072
```

On SGLang use `--tool-call-parser deepseekv3`. If the server cannot parse tool calls natively, set `"supportsTools": false` in `config.json`: the adapter then describes the tools in the system prompt and parses `<tool_call>{...}</tool_call>` blocks from the text.

Settings › Host settings lists the models the endpoint serves (`GET {baseURL}/models`, also `pennant models`), so the model id is picked rather than typed. Changing the endpoint or model applies immediately to new turns; only API port, mode, and embedding changes need a host restart.

Confirm during integration, against the real server:

1. `curl $BASE/models` returns the model id you configured.
2. A streamed request with an image returns a sensible description (run `LiveInferenceTests` against it with `PENNANT_LIVE_INFERENCE=1`, `PENNANT_LIVE_BASE_URL` and `PENNANT_LIVE_MODEL`).
3. A request with one tool returns a `tool_calls` delta rather than text.
4. Set `contextWindowTokens` to the served `--max-model-len` so compaction triggers at the right point.
5. Measure time to first token and tokens per second with a 1440 px screenshot in context; that number decides how many screenshots to keep live (`ContextBuilder.maxLiveImages`).

Thinking models spend output tokens on reasoning first. Keep `maxOutputTokens` at 2048 or more for tool-calling turns.

## Using a ChatGPT account for inference

Set `inference.provider` to `"chatgpt"` (Settings › Host, or `config.json`) and the host talks to the ChatGPT backend the Codex CLI uses instead of an OpenAI-compatible endpoint: `POST https://chatgpt.com/backend-api/codex/responses` (the Responses API, streamed) with the account's OAuth access token. `baseURL` and `apiKey` are ignored; `model` is one of the ids below or any id typed in, which is sent as is. Switching the provider applies to new turns without a restart.

**Signing in.** `pennant chatgpt login` (or "Sign in with ChatGPT" in Settings) runs OpenAI's Codex OAuth flow on the host: authorization code with PKCE S256 at `https://auth.openai.com/oauth/authorize`, the Codex CLI's public client id (`app_EMoamEEZ73f0CkXaXp7hrann`), scopes `openid profile email offline_access`, `id_token_add_organizations=true`, `codex_cli_simplified_flow=true`, and the redirect URI registered for that client, `http://localhost:1455/auth/callback`. The host listens on 127.0.0.1:1455 for that one path (the port is fixed by the registration, so a Codex CLI sign-in running at the same time makes the start fail with "port 1455 is busy"); the CLI opens the URL with `open`, the Mac app in the default browser. When the browser lands on the loopback page ("You are signed in to ChatGPT"), the host checks `state`, exchanges the code at `https://auth.openai.com/oauth/token` (`code_verifier`, `redirect_uri`, `client_id`; no secret, the client is public), reads the email, `chatgpt_account_id`, and `chatgpt_plan_type` from the id token's `https://api.openai.com/auth` claim, stores the set, and publishes `hostStatus`. One flow at a time: a new sign-in replaces the old one, and after five minutes without a redirect the account's `detail` says it timed out. `pennant chatgpt status` shows the account, plan, session expiry, and any detail.

**Reusing the Codex CLI login.** `pennant chatgpt import` (or "Use Codex CLI login") reads `~/.codex/auth.json`, the file `codex login` writes (`{"tokens": {"id_token", "access_token", "refresh_token", "account_id"}, "last_refresh": …}`; `"tokens": null` for an API-key login, which is refused), and copies the tokens into the host's store with source `codex-cli`. The file is never written. Caveat: OpenAI's refresh tokens are single-use, so after an import Pennant and the Codex CLI hold one token family; whichever refreshes first invalidates the other's copy and the loser has to sign in again. A sign-in from Pennant gives it a session of its own; prefer it unless the browser flow is unavailable.

**Sessions and refresh.** Access tokens are short-lived (the token endpoint says how long; the JWT's `exp` is what the host trusts). The host refreshes when under five minutes remain (`grant_type=refresh_token`, `refresh_token`, `client_id`, `scope=openid profile email`), one refresh however many turns ask at once, and once more on a 401 from the backend before failing the turn; rotated refresh tokens replace the old ones. A refused refresh keeps the account (the email still shows) with `detail` "Session could not be refreshed (…). Sign in again."; `inferenceReachable` turns false and tasks wait, as for an unreachable endpoint, until a new sign-in. `healthCheck` for this provider is local: signed in with a live token, or a refresh token that has not been refused.

**Where tokens live.** In the login Keychain under service `dev.pennant.host.chatgpt`, account `chatgpt.tokens`, as JSON: `access_token`, `refresh_token`, `id_token`, `expires_at`, `account_id`, `email`, `plan`, `source` (`pennant` or `codex-cli`), and `refresh_failure` after a refused refresh. When the Keychain is unavailable (headless session, tests, `PENNANT_KEYCHAIN_FALLBACK=1`) the item goes to `~/Library/Application Support/Pennant/chatgpt-credentials.json` (mode 0600). `pennant chatgpt logout` deletes it. `ChatGPTAccount` on the wire never carries tokens.

**Requests.** Headers: `Authorization: Bearer <access token>`, `chatgpt-account-id`, `OpenAI-Beta: responses=experimental`, `originator: pennant`, `session_id` (one id per provider instance), `User-Agent: pennant-host/<version>`, and `x-openai-internal-codex-residency` when the token names a data-residency region. Body: `model`, `instructions` (the system prompt), `input` items (`message` with typed `input_text`/`input_image` parts for user turns — the backend rejects plain-string content — `output_text` for assistant text, `function_call`, `function_call_output`; images in tool results ride in a following user turn, as `input_image` is only accepted there), `tools` in the flat Responses shape with `strict: false`, `tool_choice: auto`, `parallel_tool_calls: true`, `reasoning: {effort: medium, summary: auto}`, `include: ["reasoning.encrypted_content"]`, `store: false`, `stream: true`, and a `prompt_cache_key` hashed from the session, instructions, and tools. No `temperature` or `max_output_tokens`: the backend sets those. JSON-mode requests (summaries, checkpoints) add an instruction line rather than `text.format`. The encrypted reasoning items of a tool-calling turn are kept in memory, keyed by the call ids they produced, and re-sent in front of that turn's `function_call` items on the next request, as the Codex CLI and Hermes do; if the backend answers 400 mentioning `encrypted_content`, the host drops them and retries once without. SSE events map to the same chunks as the OpenAI adapter: `response.output_text.delta` → text, `response.reasoning_summary_text.delta` (and commentary-phase messages) → reasoning, `function_call` items → tool calls once their arguments are done (settled at completion when a `done` event is missing), `response.completed`/`incomplete` → usage and the finish reason (`max_output_tokens` → length), `response.failed` and `error` events → errors. A 429 is the subscription's usage limit for the window; there is nothing to refresh, wait it out.

**Models.** `pennant chatgpt models`: `gpt-5.6-sol` (default), `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` (272k context each on this backend, lower than the public API's for the same ids), and `gpt-5.3-codex-spark` (128k; a research preview for ChatGPT Pro). The list was taken from the Hermes Agent's Codex catalogue on 2026-09-22; the retired `gpt-5.x-codex` ids are refused by this backend ("not supported when using Codex with a ChatGPT account"). The backend's own list (`GET /backend-api/codex/models?client_version=0.0.0` with the account headers) is not fetched yet. Any other id typed in is sent verbatim with the config's `contextWindowTokens`.

**Caveat.** This uses the same backend, client id, and sign-in as the Codex CLI, under your ChatGPT subscription and its usage limits; it is not an API key and has no API pricing. OpenAI's terms of use for ChatGPT and Codex govern it, and OpenAI can change the endpoint or which clients it accepts without notice; Pennant identifies itself as `pennant` the way third-party harnesses are asked to. Keep the tokens to yourself.

## Apple on-device model

`AppleOnDeviceProvider` runs Apple's on-device foundation model through the FoundationModels framework: no server, no key, nothing leaves the Mac. It needs macOS 26 or later with Apple Intelligence switched on (System Settings > Apple Intelligence & Siri). `AppleOnDeviceProvider.availability` reports `available`, `not supported on this Mac`, `Apple Intelligence is off`, `model downloading`, or `requires macOS 26`; `healthCheck` is true only for the first. The package still builds and runs on macOS 15, where the provider fails with `unreachable`.

How a turn is mapped: leading system messages become the session instructions; earlier user and assistant turns, tool calls, and tool outputs are replayed as native transcript entries; the trailing user text is the prompt (after tool results with no new user text the prompt is "Continue the task using the tool results above."). Each `ToolSpec` becomes a framework tool whose schema is built from its JSON Schema (objects with required/optional properties, strings, integers, numbers, booleans, arrays, enums, const); other constructs degrade to a string. The framework wants to run tools itself, so the bridge tool only records the call and aborts the session; the provider then yields the calls with `finished(.toolCalls)` and the runtime executes them as usual.

Limits to know:

- No vision. Image parts are replaced by `[screenshot omitted: the on-device model cannot see images]`, so desktop-control tasks that need a screenshot must use another model.
- Small window: 4096 tokens on macOS 26, 8192 on macOS 27 (`contextWindowTokens` follows the OS, so compaction triggers at the right point). Long system prompts and many tool schemas eat into it; replies are capped at 1024 tokens.
- One tool batch per turn. Once the model calls a tool the session ends; calls made in parallel in that batch are all reported, but the model cannot chain a second batch until the runtime feeds the results back in the next turn. Letting the tool return a placeholder instead was tried and makes the model answer with nonsense ("the time is not yet determined").
- Token usage is real on macOS 27 (`session.usage`) and estimated on macOS 26. There is no reasoning stream. `jsonMode` is an instruction, not a grammar. A reply cut by the output cap finishes with `stop`, not `length`.
- Guardrail refusals arrive as `malformedResponse` with the framework's explanation, context overflow as `contextTooLarge`, missing model assets as `unreachable`.

Verify with `swift test --filter AppleOnDeviceProviderTests`: the four live tests (plain prompt, tool call, transcript replay, cancellation) take about 2.5 s when Apple Intelligence is on and skip otherwise.

## macOS permissions

The host needs, attributed to the `pennant-host` code signature:

| Permission | Used for | Detected by |
| --- | --- | --- |
| Accessibility | Synthesised mouse and keyboard input, the accessibility tree | `AXIsProcessTrusted()`; prompt via `requestPermissions` |
| Screen Recording | Screenshots and the live screen stream | `CGPreflightScreenCaptureAccess()` |
| Input Monitoring | Keyboard part of the pause-on-human-input tap (mouse works without it) | Tap creation succeeds |
| Automation | AppleScript and JXA against other apps | Error -1743 surfaces as a permission error |

Grants are attributed to the *responsible* process. The host is always its own: the Mac app spawns it with the responsibility disclaimed (the same mechanism Chromium and VS Code use for helpers), and launchd starts it as its own process. The host ships as a helper bundle, `Pennant.app/Contents/Helpers/Pennant Host.app` (bundle id `dev.pennant.host`), because macOS keys a bare executable's grants by file path: every rebuild or copy at a new path became a new "pennant-host" entry, and enabling an old one did nothing for the running host. With the bundle, System Settings shows one entry, **Pennant Host**, keyed by identity, and it survives rebuilds. System Settings labels the helper with the enclosing app's name, so the rows read "Pennant"; Automation (Apple Events) consent for an embedded helper is attributed to the outer app itself (`dev.pennant.mac`). Older rows named "pennant-host" belong to copies at other paths and do nothing for the tools; remove them with the minus button. The Permissions screen names the grantee, and each row has Reset & ask again, which runs `tccutil reset <service> dev.pennant.host` and prompts again; use it when a row is stuck or was denied. Screen Recording takes effect only after the host process restarts; the Permissions screen offers Restart host for that.

macOS caches Screen Recording (and sometimes Accessibility) per process, so a grant made in System Settings is invisible to the running host. The host therefore re-evaluates permissions in a fresh helper process (`pennant-host --check-permissions`) every few seconds while anything is missing, publishes the change to the apps, and when a grant needs a restart it restarts itself once no task is running; the app (or launchd) starts it again within seconds and reconnects. The Permissions screen also has a Re-check button.

The app asks for everything up front: Settings › Permissions, or the sheet that appears on first launch while anything is missing. If a tool still hits a missing grant, the host shows the system prompt at that moment and posts a notice with a Fix button. Automation consent is checked per target app with `AEDeterminePermissionToAutomateTarget`; the target has to be running for macOS to show its dialog, so Request launches it hidden if needed.

Permissions stick to a stable signature, so run the host from the app bundle (`Pennant.app/Contents/MacOS/pennant-host`) rather than from `.build/` once you want them to persist.

## Building the app

`Scripts/build-release.sh` builds `pennant-host` in release mode, generates the Xcode project, builds `Pennant.app` in Release, signs the embedded host with identifier `dev.pennant.host` and the bundle with `dev.pennant.mac`, verifies the seal, and copies the result to `dist/Pennant.app`. Pass `--identity "Developer ID Application: …"` to choose a certificate and `--open` to launch it. On first launch the app spawns the embedded host, which writes `client-token`, and connects.

## Installing the host as a LaunchAgent

The Mac app embeds the host and a LaunchAgent plist (`dev.pennant.host.plist`, `KeepAlive`, `LimitLoadToSessionType Aqua`). Settings › Host › Register uses `SMAppService.agent(plistName:)`; launchd then keeps the host running in the graphical session whether or not the app is open. Unregister from the same place. While developing, the app instead spawns `pennant-host` from the package build directory if nothing is listening on the port.

## Deployment modes

- **everyday**: same desktop as the user. Pause-on-human-input is on by default: the moment you move the mouse while an agent holds the desktop, its lease is paused and its task is paused with an explicit reason. Resume from the computer panel, or set `autoResumeAfterSeconds`.
- **dedicated**: a separate Mac. Turn pause-on-human-input off, use the iPhone or another Mac for live view and takeover. `listenOnNetwork` must be true; people sign in from their devices (Settings › People invites them).

Sleeping the host or losing the graphical session interrupts desktop work; the runtime records the tool as uncertain if it was mid-flight and reconciles on resume.

## Connecting an iPhone

1. Mac app: Settings › People. The owner sets up their own sign-in (a password, or Microsoft, Google or GitHub) and invites anyone else by email; an invite carries a one-time code.
2. iPhone: find the Mac on the network (or scan its connect code), then sign in. The host replies `signedIn` with a token for that device, kept in the phone's Keychain.
3. Later connections send `hello` with the token; the host replies with a snapshot and replays missed events.

Removing a person in Settings › People signs out every device they signed in on.

## Diagnostics

The Mac app's Diagnostics view (and `pennant diag`) shows the endpoint reachability, database and log paths, event count, tool specs, and recent tool records. `pennant watch` prints every event as it happens.

## Scheduled jobs

Schedules live in the host and run whether or not an app is open. Create them in the Schedules screen, by asking an agent ("every weekday at 8, summarise my inbox"), or with `pennant schedules`. Each run is a task in the job's own conversation, so its history compacts like any other. Missed runs older than six hours are skipped.

## Coding runs

Pennant's `code` tool hands a change to a coding run: a thread of its own under the one that asked, with its steps, cards and approvals there, whose final reply goes back to the asking task (`await_task`). Settings › Pennant › Coding, or `pennant coding`, sets it up; it is `coding` in `config.json` (an older config's single `workingDirectory` is read as one project).

- **Engine.** Claude Code runs the `claude` program you installed and signed in to; its permission requests come back to Pennant through `pennant-host coder-permission`. The Pennant engine runs the task on Pennant's own loop with five tools (`read_file`, `list_directory`, `edit_file`, `write_file`, `shell`): commands start in the project folder, and files are written only inside it. It runs on the thread's model (the model pill above the composer), else the one chosen under Coding (`pennant coding model <name>`), else the default model, and its calls go into the usage ledger like any task's.
- **Project folders.** As many as you like, each with a name; `code` takes a name or a path, and the first folder is the default. `pennant coding folder <dir> [--name N]` adds one as the default, `pennant coding folders` lists them, `pennant coding folder remove <name>` takes one off the list.
- **Asks.** Both engines follow the same rules: publishing or sending, deleting and spending stop at a card; Ask for everything asks before every edit and command; Plan first has the run put its plan on a card before it changes anything (the Pennant engine gets its write tools once the plan is approved).
- **GitHub identity.** The GitHub App runs commit, push and open pull requests as. Set up… asks for the App ID, slug, installation ID and the App's private key (.pem), which goes into the Vault; Check mints a token the way a run does. Without an identity, runs don't push. `pennant coding github --app-id N --installation N --vault ENTRY --slug SLUG` does the same from the terminal.

## Importing skills

Pennant reads the `SKILL.md` folder format used by Claude Code, Codex, and the Agent Skills standard. Skills › Import… scans `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, and their project-level equivalents, or takes any folder or git URL; `pennant skills import <folder|url>` does the same from the terminal, and an agent can call `import_skills`. The Markdown body becomes the skill's instructions, numbered lines become steps, and text files in the folder come along as scripts. Instructions-only files such as `CLAUDE.md`, `AGENTS.md`, or `.cursorrules` are not skills; paste the relevant lines as standing instructions instead. Tool code from Python frameworks cannot be imported; expose it as an MCP server and Pennant will use it as tools.

- **Preview first.** `pennant skills preview <folder|url>` (the Import sheet in the app) lists every skill found with its purpose, step count, and whether the library already has it: new, an update of the existing version, or unchanged. Nothing is written.
- **Pick some.** `pennant skills import <folder|url> --only <name> [<name>…]` imports only the named skills, using the names the preview shows. Without `--only` everything found is imported; unchanged skills are skipped and changed ones become a new version of the same skill.
- **Git sources.** A source that looks like a repository (`https://…`, `git@…`, `ssh://…`, or a path ending in `.git`) is cloned shallowly under `~/Library/Application Support/Pennant/skills/repos/<name>` with the `git` on the host's PATH, and pulled (`--ff-only`) on every later preview or import of the same URL. Private repositories need credentials git can use without a prompt (SSH keys or a credential helper); the host never asks.
- **Remembered folders.** Folders you add (`pennant skills folders add <path>`, or the folder list in the app) and cloned repositories are kept in the database and listed by `pennant skills folders` with their kind (`known`, `custom`, `git`) and, for repositories, the origin URL. `pennant skills folders remove <path>` forgets one and leaves any checkout on disk. Known harness folders are detected fresh on every scan.
- **Deleting skills.** `pennant skills delete <id>…` removes learned or imported skills (id prefixes work). Built-in skills can be disabled but not deleted.

## Signing in to MCP servers

Providers without dynamic client registration (GitHub and HubSpot, for example) need a client you create in their developer console. Register the redirect URL `http://127.0.0.1:47831/callback` there, then add the server with that client id (and secret if they issue one) under "I have a registered client". Sign-ins for hand-registered clients always use that port. Catalog entries whose provider works this way (`needsRegisteredClient`) ask for the client id and secret in a sheet before opening the browser, and an entry can carry a second sign-in (`alternateAuth`) that the card offers as a link under the chips.

**GitHub.** Connect asks for a personal access token: GitHub's authorization server (`github.com/login/oauth`) advertises no registration endpoint, so a host cannot sign in with OAuth until it has an app of its own. "Sign in with OAuth instead" takes the client id and secret of an OAuth App you create at github.com/settings/developers with the callback URL above, then runs the flow below with it.

**HubSpot.** Two routes. Connect runs HubSpot's local server on the Mac (`npx -y @hubspot/mcp-server`) with a private-app access token in `PRIVATE_APP_ACCESS_TOKEN` (HubSpot now files private apps under Development › Legacy apps; they are still supported). "Sign in with OAuth instead" uses the remote server at `mcp.hubspot.com`, which has no dynamic registration: create an MCP connector in HubSpot's developer console with the redirect URL above and paste its client id and secret.

Remote (HTTP) MCP servers carry a sign-in method on their config (`auth`): none, an API key, or OAuth. Local (stdio) servers take their secrets as environment variables and never sign in. `pennant mcp list` shows every server with its connection state, tool count, and sign-in state (`notRequired`, `signedOut`, `authorizing`, `signedIn`, `expired`, `failed`) plus a one-line detail such as "Signed in · expires in 58 min" or "Sign in again". The same fields are on every `mcpServerStatus` event, so the apps show them live.

**API keys.** `--auth key` sends a static secret on every request as `<header>: <prefix><secret>`: `Authorization: Bearer …` by default, or a custom header (`pennant mcp add Notion https://… --auth key --header X-API-Key --prefix ""`). Store the secret with `pennant mcp key <id|name> <secret>` (`-` reads it from stdin so it stays out of the shell history) or the key field in the app; the host stores it and reconnects. Pasting a token into an OAuth server works the same way (a token set with no refresh: when it expires the state becomes `expired` and you sign in again).

**OAuth.** `pennant mcp connect <id|name>` (or Connect in the app) runs the MCP authorization spec (2025-06-18 revision; OAuth 2.1 with PKCE S256) on the host:

1. *Discovery.* The host fetches the server's protected-resource metadata (`/.well-known/oauth-protected-resource`, path-suffixed first for servers under a path), and if that is missing sends an unauthenticated `initialize` and reads `resource_metadata` from the 401's `WWW-Authenticate` header; failing both, the server's origin is taken to be the authorization server. Authorization-server metadata comes from `/.well-known/oauth-authorization-server` (path-aware per RFC 8414), then `/.well-known/openid-configuration`; without either the endpoints default to `/authorize`, `/token`, and `/register` under the server's origin. A server that lists `code_challenge_methods_supported` without `S256` is refused.
2. *Client.* A client id and secret set on the config are used as is. Otherwise the host registers dynamically (RFC 7591) as "Pennant", a public client with `token_endpoint_auth_method: none` and the loopback redirect URI, and remembers the registration under `<credentialKey>.client` so later sign-ins reuse it (and its redirect port); a registration the server no longer accepts is replaced.
3. *Browser.* The host starts a listener on `http://127.0.0.1:<ephemeral port>/callback`, builds the authorization URL (`code_challenge`, `state`, the configured scopes or the ones the resource advertises, and `resource=<canonical server URL>` per RFC 8707) and hands it back; the CLI opens it with `open`, the Mac app in the default browser. One flow per server: a new Connect replaces the old one, Cancel drops it, and after five minutes without a redirect the state becomes `failed`.
4. *Tokens.* When the browser lands on the loopback page ("You are signed in to <name>. You can close this tab and go back to Pennant."), the host checks `state`, exchanges the code (`code_verifier`, `redirect_uri`, `resource`; HTTP Basic when the client has a secret), stores the token set, marks the server signed in, and reconnects.

**Refresh.** Before every connection the host refreshes a token that expires within 60 seconds; during a session a 401 triggers one refresh and a retry, and rotated refresh tokens replace the old ones. When the refresh is refused the state becomes `expired` ("Sign in again") and the server stays disconnected until you connect again.

**Where credentials live.** In the login Keychain under service `dev.pennant.host.mcp`, one item per server whose account is the config's `credentialKey` (`mcp-<server id>`): the API key as is, or the OAuth token set as JSON (`access_token`, `refresh_token`, `token_type`, `scope`, `expires_at` in ISO 8601, `token_endpoint`). The registered OAuth client sits next to it under `<credentialKey>.client`. When the Keychain is unavailable (headless session, tests, `PENNANT_KEYCHAIN_FALLBACK=1`) the same items go to `~/Library/Application Support/Pennant/mcp-credentials.json` (mode 0600). The credential key stays on the config; secrets never travel over the API.

**Signing out.** `pennant mcp signout <id|name>` (or Sign out in the app) deletes the token set and the registered client, disconnects, and leaves the server `signedOut`; `pennant mcp remove` deletes the credentials with the server. Revoking access at the provider has the same effect once the next request is refused.

**From the iPhone.** The redirect URI points at the Mac's loopback address and the code exchange must come from the host that holds the PKCE verifier, so a browser on the phone would land nowhere. The iPhone app therefore asks the host to start the flow and hands the browser step to the Mac (the URL it gets back opens there); the status events then show the outcome on both devices. API keys can be entered from either device.

## Microsoft 365, Teams, LinkedIn and Reddit

Connections › Connect lists these under Productivity and Social. Each needs an app you register once with the provider (no provider offers automatic registration); the Connect sheet shows the steps, the redirect URL to register (`http://localhost:47831/callback`), and remembers the client id per provider.

- **Microsoft 365 (built in).** Outlook mail and calendar, Teams chats and channels, OneDrive and SharePoint files through Microsoft Graph. Register an app in Entra (Mobile and desktop platform, no secret), add the delegated permissions listed on the sheet, grant admin consent, and paste the client and tenant IDs. No Copilot licence needed; Teams needs a work account.
- **Work IQ (Microsoft's own MCP servers).** Mail, Calendar, Teams, SharePoint, OneDrive, Word and Copilot. Each user needs a Microsoft 365 Copilot licence, the tenant must be a GUID, and the servers are in preview. The same Entra app works once it has the Work IQ permissions.
- **LinkedIn (built in).** Posts to your own feed (text, link card or image), comments and deletes, through your own app with the self-serve "Share on LinkedIn" and "Sign In with LinkedIn using OpenID Connect" products. LinkedIn needs the client secret, rejects PKCE on its standard flow, and gives self-serve apps no refresh token: sign in again every 60 days. Reading the feed or comments needs LinkedIn's partner programs.
- **Reddit (built in).** Read, search, post, comment and check the inbox as your account. Reddit approves Data API access by hand under its Responsible Builder Policy (2026); create an *installed app* only after approval. Tokens refresh (permanent duration); Pennant sends Reddit's required `macos:dev.pennant.mac:v… (by /u/you)` user agent.

## Files from agents

An agent hands a file to you with the `share_file` tool (every agent has it): the bytes are copied into `artifacts/` under the data directory as an artifact of kind `file`, and a card appears in the conversation where the tool ran, with the name, size, and the agent's one-line caption. On the Mac the card offers Save… (a save panel with the name pre-filled), Open (a temporary copy under `<tmp>/Pennant/<artifact id>/<name>`, handed to the default app), and for text-like files under 200 KB a Preview of the first 60 lines; on the iPhone, Save… presents the share sheet, which includes Save to Files. The model only ever sees `[shared file: <name>, <size>]` in its history, never the bytes.

Limits: one file per call, at most 50 MB (the tool tells the model to zip or split larger files), regular files only (directories are refused with a hint to zip them). Credential files are refused with a clear error and never reach the store: anything under `~/Library/Keychains`, `/Library/Keychains`, `~/.ssh`, `~/.gnupg`, or `~/.aws`, and names matching `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.keychain*`, `id_rsa*` (and the other SSH key names), `.env*`, `.netrc`, `.npmrc`, or `credentials.json`.

From a script: `pennant artifact save <id|prefix> <out-path>` writes the bytes to disk (a directory as the target keeps the original file name). A prefix is matched against the files shared into conversations; other artifacts (screenshots) need the full id.
