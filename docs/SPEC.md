# Personal Mac agent — product and architecture specification

Status: proposed architecture; implementation in progress under the name **Pennant**.

Since 2026-09-28 the product runs **one agent**, Pennant, as the only point of contact (docs/DECISIONS.md #34). Kinds of work are skills on schedules, big jobs are split across task-scoped helpers, and code changes are coding runs.

## Product goal

Build a native personal agent application with one persistent agent, visible computer use, dependable task continuity, and a light, minimal interface. It runs against any OpenAI-compatible endpoint, including models served on your own hardware. Confirm the exact vision checkpoint, image format, tool-call format, and measured latency during integration.

Support both deployment modes:

- **Everyday Mac:** the agent operates the same desktop the user works on. The user can pause computer use, intervene, and resume the task.
- **Dedicated Mac:** the same host service operates a separate Mac. Native Mac and iPhone clients provide chat, live viewing, and takeover.

The application controls the Mac with the access granted to its logged-in user and through macOS permissions. Protected authentication and operating-system restrictions still apply. Closing the client window must not stop work; sleeping the host or losing its usable desktop can interrupt work. The runtime must represent those conditions accurately and reconcile state after reconnecting.

## Requirements and implementation decisions

| Requirement | Proposed implementation |
| --- | --- |
| Runs on Mac | Swift host service and native SwiftUI Mac application, with AppKit integration where needed. |
| Full machine control | Accessibility APIs, keyboard/mouse events, app automation, browser tools, shell processes, and filesystem access. Prefer structured tools for reliable actions; use visual interaction when needed. |
| Visible computer use | Actual desktop actions, a clear active-agent indicator, and a live screen panel using ScreenCaptureKit. Remote clients receive an authenticated screen stream. |
| Native Mac and iPhone apps | Shared Swift models and client protocol, with platform-specific SwiftUI layouts. The iPhone controls work on the Mac; execution stays on the host. |
| Delegation and personalities | One persistent agent with a name, role, style and skills, plus task-scoped helpers and coding runs. |
| Learned skills | The agent records successful procedures as versioned skills with prerequisites, steps, and checks for success. |
| Strong memory | Local SQLite database, relationship tables, searchable original history, explicit preferences, task checkpoints, and optional local semantic retrieval. |
| Automatic compaction | Runtime-managed context budgeting and durable checkpoints, with summaries linked back to original evidence. |
| MCP tools | Official Swift MCP client SDK; local subprocess and remote HTTP integrations owned by the host service. |
| Minimal interface | Threads (one per job run or conversation), results, and an optional computer panel; details appear when relevant. |

## System boundaries

```text
Native Mac app                   Native iPhone app
      |                                  |
      +---- authenticated host API ------+
                         |
                Mac host service
       +-----------------+-----------------+
       |                 |                 |
   Task runtime      Memory / skills   Computer control
   and scheduler     and event log     and live capture
       |                 |                 |
       +------ Tool broker / MCP ---------+
                         |
              Local inference endpoint
          (local GPU box or API)
```

The Mac host owns authoritative task state and its database. Clients subscribe to events, cache enough state to remain useful when disconnected, and submit commands with unique IDs. Clients never open the host database over a network filesystem. Reconnection replays events from the last received ID.

Keep the runtime in a separately managed user-session service so it survives closing the interface. Computer interaction must run in the appropriate logged-in graphical session. Use a signed Mac build installed directly for the host rather than designing its broad machine access around App Store sandbox restrictions.

Keep inference behind a small provider adapter. Validate screenshot input, structured tool calls, cancellation, streaming, and context limits against the user's actual server. Available memory and model benchmarks do not establish interactive throughput; measure it under the intended workload.

## Sharing the computer

Use one foreground computer-control owner per desktop session. Several tasks (and their helpers) can plan and perform independent background work, subject to resource conflicts and model capacity. They queue when they need the same desktop, browser session, application, or file.

Human takeover revokes the agent's ability to start new desktop actions. The runtime cancels actions where cancellation is supported and reconciles any action already in progress before granting control. On resume, the agent reads a fresh screen and application state; it does not continue clicking from an old screenshot.

On an everyday Mac, provide a visible stop control and configurable pause-on-human-input behavior. On a dedicated Mac, the clients provide a live view and explicit takeover. Truly simultaneous independent GUI sessions would require additional desktops or machines and are a later extension.

## Task runtime and delegation

Use explicit task states: queued, running, waiting for a tool, waiting for the desktop, waiting for the user, paused, completed, failed, and cancelled. Persist each transition.

Every delegated task has an owner, a specific objective, completion criteria, dependencies, relevant context, and a resource budget. The parent remains responsible for collecting and verifying the result. A worker can request help or delegate further within the configured limits.

Personalities affect communication style and role behavior. They do not change the correctness standard or create additional machine permissions. The agent keeps its identity and memory; temporary helpers leave their useful results with the task that started them and are retired.

Record tool intent and outcome. A crash between an external action and its acknowledgement leaves an uncertain result. Read back the target state before retrying a consequential action; an internal task ID alone cannot prevent duplicate effects in an external application.

## Memory design

Use SQLite as the local source of truth. A graph is represented by ordinary entity and relationship tables, avoiding a separate database service for the personal application.

Store five complementary forms of memory:

1. **Explicit preferences and instructions:** what the user said should govern future work, with the original source and revision history.
2. **Project facts and relationships:** people, projects, documents, applications, deadlines, and their connections.
3. **Task state:** objective, completed steps, remaining work, dependencies, blockers, artifacts, and unresolved actions.
4. **Episodic history:** conversations, tool observations, corrections, outcomes, and selected visual evidence.
5. **Procedural memory:** versioned skills and their recorded outcomes.

Each fact or relationship has provenance, observed time, applicable scope, and a status such as asserted, inferred, contradicted, or superseded. Keep historical versions. Newly inferred information must not silently replace an explicit instruction.

Example relationship: `Invoice 042 → belongs to → Project Atlas`. Attach the originating document or observation to that relationship. Graph structure makes related information easier to retrieve; it does not make an extracted claim true.

Retrieval combines exact identifiers and full-text search, relevant graph relationships, and semantic search when useful. Fetch original evidence when the decision warrants it. Separate durable instructions from historical content supplied as evidence.

The interface provides a readable Memory view with source links and edit, correct, and forget actions. Forgetting must update derived search indexes and summaries as well as the underlying records. Backup and restore must preserve a consistent database and its referenced artifacts.

## Automatic compaction

Compaction reduces the model's active context while durable task state remains in storage.

Before context becomes crowded, the runtime saves a checkpoint containing the current objective, governing instructions, decisions, completed work, pending actions, active delegations, artifact references, unresolved questions, and the next intended step. It preserves enough context capacity to finish that checkpoint.

Build the next context from authoritative task state, relevant memories and skills, a concise history summary, and recent interaction. Summaries retain references to original events. Retrieve from those originals when necessary instead of repeatedly relying on summaries of summaries.

Tool execution state and permission decisions remain runtime records. A generated summary cannot mark an unverified action as completed or manufacture authorization. Compaction must wait for or accurately represent outstanding tool results.

## Learning skills

After a verified successful workflow, the agent can create or update a skill containing its purpose, applicability, prerequisites, inputs, steps, expected result, and known failure conditions. It can include supporting scripts where appropriate.

Keep versions, evidence from the successful run, and subsequent outcomes. Label a newly learned skill as provisional until it has sufficient validation. Revalidate uncertain steps during use. User corrections update the relevant skill version and supporting memory.

A skill is visible in the app and can be edited or disabled. Creating a skill does not independently expand the agent's access. Do not require the user to organize internal folders to benefit from learned procedures.

## MCP and companion connectivity

The host service owns MCP connections, process lifecycle, credentials, and tool execution. Load relevant tool descriptions on demand to avoid filling context with every integration. Pin and test SDK/protocol compatibility with the chosen servers.

Companion apps sign in to the host (a password, Microsoft, Google or GitHub, or an invite) over authenticated, encrypted connections. Store credentials in Keychain. Begin with local-network and private-network access. Remote video uses an authenticated streaming channel; task messages and screen frames have separate lifecycles.

The host continues work when the iPhone app is suspended. Reliable notifications to a suspended iPhone require a supported push delivery path, normally APNs and a small provider service; an always-open socket is not a substitute. Push delivery can be added separately from the fully local execution path.

## Interface

On Mac: a sidebar of threads (what needs you first, then the rest, closed ones folded away), a conversation area with completed outputs, and a computer panel that opens when useful. The panel offers pause, takeover, and resume. Memory, skills, and connections live in focused secondary views.

On iPhone: an agent list, conversation and results, live computer view, and prominent pause/takeover controls. Adapt remote pointer and keyboard interaction for touch. Display disconnected or stale state explicitly.

Show concise progress and evidence of results. Keep raw tool traffic, configuration files, and internal database paths behind an optional diagnostic view. Familiar interaction patterns can be reproduced with original branding and visual assets.

## Delivery order and acceptance criteria

1. **Mac control and local model integration.** Chat can launch an app, perform a task, inspect its result, and show live activity. Verify visual inputs and tool calls against the existing inference server.
2. **Continuity and human takeover.** Pause, intervention, restart, and reconnection preserve the task. Uncertain external actions are reconciled before retrying.
3. **Memory and compaction.** Corrections survive restarts and repeated compactions; the agent retrieves the right project facts and does not confuse superseded facts with current ones.
4. **Delegation, skills, and MCP.** Workers coordinate without desktop collisions; successful procedures can be learned and reused; representative local and remote MCP servers work.
5. **Native iPhone companion and refinement.** Sign-in, chat, live viewing, takeover, reconnect behavior, and optional push notifications.

Build against a small set of the user's actual jobs. Measure verified completion rate, human interventions, duplicate actions, elapsed time, and memory accuracy. Repeat after interruptions and compaction. Those measurements determine whether the implementation reaches the desired work outcomes.

## Sources

- Apple: [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [UI automation permissions](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AutomatetheUserInterface.html), [background service management](https://developer.apple.com/documentation/servicemanagement/smappservice), and [push notification delivery](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns).
- MCP: [Official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk/blob/main/README.md).
- SQLite: [Appropriate uses and concurrency](https://sqlite.org/whentouse.html) and [FTS5 full-text search](https://www.sqlite.org/fts5.html).
- DeepSeek: [V4 Flash Vision model card](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-Vision-Exp).
