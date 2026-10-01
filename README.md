# Pennant

Pennant is one open-source AI agent that lives on your Mac, with an iPhone companion. It triages the inbox, writes the posts, records the demos, watches production and fixes the code, on your schedule and with whatever model you choose. It remembers what you told it and uses your apps the way you do. Before it publishes, sends, deletes or spends, it hands you a card and waits for your OK.

You talk to Pennant and nobody else. Each job is a skill on a schedule that runs in a thread of its own; big jobs bring in helpers on a cheaper model, and code changes go to a coding run in one of your project folders (Claude Code, or Pennant's own engine on any of your models), in a thread under the one that asked.

- **Nothing goes out without you.** Publishing, sending email, deleting and spending always stop at an approval card, whatever the skill or the model says; approving runs exactly what the card shows. Skills can ask for more cards of their own. Edit the text, send it back with a note, or reject it, on the Mac or the iPhone. A run ends in a report card, not a wall of text.
- **Any model, including local ones.** Use any OpenAI-compatible endpoint, a GPU box on your desk, Ollama, LM Studio or Apple's on-device model, with fallbacks. Rate limits pause and resume a task; an outage moves it to your next model.
- **Your Mac, your data.** Everything lives in one folder you own. There's no sign-up and no telemetry, and export/import moves everything to your next Mac.
- **Built for the ways agents fail.** One owner of the desktop at a time, uncertain actions reconciled before they're retried, memory with provenance, schedules that don't collide, a cost ledger per run, job and model, and a vault that keeps secrets out of the model's view.
- **Memory with receipts.** Pennant remembers facts and the passages they came from, searches them by keyword and meaning, names its sources, never lets something it inferred overwrite something you said, and forgets for good when you ask.
- **Skills are folders.** Skills use the `SKILL.md` format used by Claude Code, Codex and Agent Skills, in a git repository you own. Pennant writes new versions of its skills when you give feedback, and you can teach one by doing the task once while it watches.

The design spec is in [docs/SPEC.md](docs/SPEC.md); what exists today and what is verified is in [docs/STATUS.md](docs/STATUS.md).

## Download

Get the latest signed and notarized build from the [releases](https://github.com/pennant-dev/pennant/releases/latest) or
[pennant.dev](https://pennant.dev): open the DMG, drag Pennant to Applications, and launch it. It needs macOS 15 or later,
on Apple silicon or Intel, and updates itself once you allow it. Releases are cut with `Scripts/release.sh`; see
[docs/RELEASE.md](docs/RELEASE.md).

## Requirements

- macOS 15 or newer and Xcode 27 to build; `xcodegen` for the apps (`brew install xcodegen`).
- The iPhone app needs iOS 18 or newer.
- An inference endpoint. For a first run with no API key, Ollama with a vision and tools model works: `ollama pull gemma4:e2b-it-qat`.

## Quick start

```sh
# Build everything (host, CLI, libraries) and run the tests
swift build
swift test --skip LiveInferenceTests

# Run the host in the foreground against a local model
swift run pennant-host --endpoint http://localhost:11434/v1 --model gemma4:e2b-it-qat

# In another terminal: talk to it
swift run pennant status
swift run pennant send "List the files in ~/Documents and summarise them"
swift run pennant watch
```

The host keeps its database, artifacts, config and log under `~/Library/Application Support/Pennant`. Edit `config.json` there, or use the Mac app's Settings, to choose a model:

```json
{
  "inference": {
    "baseURL": "http://gpu-box.local:8000/v1",
    "model": "deepseek-ai/DeepSeek-V4-Flash-Vision-Exp",
    "contextWindowTokens": 128000,
    "maxOutputTokens": 4096,
    "supportsVision": true,
    "supportsTools": true
  }
}
```

`"provider": "openai"` (the default) is any OpenAI-compatible endpoint at `baseURL`. Settings › Models offers presets (OpenAI, Anthropic, Google AI Studio, xAI, Mistral, DeepSeek, Moonshot, Z.ai, Alibaba Model Studio, OpenRouter, Groq, Together, Fireworks, Perplexity, Ollama Cloud, and the local Ollama, LM Studio and vLLM servers), each with a "Where do I get a key?" link. `"provider": "apple"` runs Apple's on-device model, private and offline, text only. The runbook also covers the ChatGPT sign-in provider; using a subscription that way is governed by OpenAI's terms.

Compaction runs when the context reaches `compaction.triggerTokens` (128k by default) or 75% of the model's window, whichever comes first. Each task gets an allowance from `defaultBudget` (steps, tokens, wall time, workers); reaching it pauses the agent with a note, and any reply grants the same allowance again.

Skills can be imported from a folder or a git URL: `pennant skills preview <source>` shows what would change, and `pennant skills import <source> --only <name>` takes just the ones you want.

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for the vLLM/SGLang flags the adapter expects, the macOS permissions the host needs, and how to install it as a LaunchAgent.

## The apps

```sh
Scripts/build-release.sh --open   # release host + signed Pennant.app with the host embedded → dist/Pennant.app
Scripts/generate-project.sh       # xcodegen → Pennant.xcodeproj (for development in Xcode)
Scripts/build-apps.sh             # debug builds of PennantMac and PennantiOS
```

`build-release.sh` signs with the first Apple Development or Developer ID identity in your keychain (or ad hoc if there is none), so macOS keeps the Accessibility and Screen Recording grants across rebuilds. To build the iPhone app for a device, put `DEVELOPMENT_TEAM = <your team id>` in `Apps/Signing.local.xcconfig` (git ignores it); the repository leaves the team empty.

The Mac app starts the host if nothing is listening, connects over the loopback WebSocket with the local token, and shows the threads, approvals, reports, schedules, memory and a live view of the screen when Pennant is using the desktop. The iPhone app signs in to your Mac with an account from the Mac app's Settings › People and gets the same threads, approvals, memory and takeover controls.

Coding runs are set up in Settings › Pennant › Coding. The engine is Claude Code (the `claude` program you installed and signed in to) or Pennant's own, which writes the code itself on any model from Settings › Models, with a shell that starts in the project folder and file tools that write only inside it. Add as many project folders as you like; a request names one, or goes to the first. The same place gives coding runs their own GitHub App identity (its key goes into the Vault), so pushes and pull requests never go out as you. By default a run asks only before publishing or sending email, deleting, or spending; set it to ask for everything, or to plan first, under Asks. Every setting has a command too: `pennant coding folder <dir>`, `engine pennant`, `model <name>`, `mode manual`, `github …`. `pennant health enable` turns on a daily review in which Pennant reads how its runs, skills and jobs are doing and proposes fixes as cards.

Connections opens with a small MCP marketplace: services Pennant knows how to reach (GitHub, Notion, Linear, Sentry, Stripe, Figma, Supabase, Exa, the local Filesystem and Git servers, and more), each with one Connect button. OAuth servers sign in through the browser with PKCE, API-key servers store the key in the host's Keychain, and anything not in the catalogue can be added by hand.

The look is a light, quiet design system in which colour is kept for status and the agent's flag; see [docs/DESIGN.md](docs/DESIGN.md). The app icon is generated by `Scripts/make-icon.py`.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/PennantCore` | Models, task state machine, event log types, client/host protocol. Shared by every target. |
| `Sources/PennantHostKit` | The host: SQLite store, inference, desktop control, tool broker, task runtime, memory, skills, MCP, API server. macOS only. |
| `Sources/PennantHost` | `pennant-host`, the user-session service. |
| `Sources/PennantClientKit` | Client session, WebSocket transport, cached state, sign-in credentials, Bonjour discovery. Mac and iOS. |
| `Sources/PennantUI` | SwiftUI views shared by the Mac and iPhone apps. |
| `Sources/PennantCLI` | `pennant`, a terminal client for scripting and diagnostics. |
| `Apps/PennantMac`, `Apps/PennantiOS` | App targets, generated into `Pennant.xcodeproj` by xcodegen from `project.yml`. |
| `Tests` | XCTest suites for the core, the host and the UI. |
| `docs` | Spec, architecture, protocol, design, runbook, decisions, status. |

## Principles carried through the code

- **The host is authoritative.** Every task transition, tool intent and tool outcome is a durable record with a sequence number. Clients replay from the last sequence they saw.
- **One desktop owner at a time.** A task takes a lease on the desktop; a human takeover or pause revokes it. After any interruption the agent must look at the screen again before it clicks.
- **Uncertain actions are reconciled, not retried.** A crash between an action and its acknowledgement leaves the record `uncertain`; an identical consequential call is refused until an observation tool has run.
- **Memory has provenance.** Facts carry source, time, scope and status. An inferred claim never silently replaces something the user asserted.
- **Summaries point at evidence.** Checkpoints keep the event range they cover and never mark an unverified action as done.
- **Personalities do not change permissions.** Style and role live in the profile; what the agent may do is decided by the harness (sign-off rules, grants, the desktop lease), not by its instructions.

## Contributing, security and license

Contributions are welcome; start with [CONTRIBUTING.md](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

Pennant is licensed under the [Apache License 2.0](LICENSE). The name and icon are not: see [TRADEMARKS.md](TRADEMARKS.md). Third-party code and marks are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
