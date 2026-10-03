# Architecture

```text
 Mac app (SwiftUI)            iPhone app (SwiftUI)          pennant CLI
        \                            |                        /
         \        HostSession + WebSocketTransport (PennantClientKit)
          \                          |                      /
           +------------ WebSocket, JSON + binary frames --+
                                     |
                              HostAPIServer  (Network.framework, sign-in, Bonjour)
                                     |
                               HostService  (composition root, HostAPIDelegate)
        +-------------+--------------+---------------+----------------+
   TaskRuntime    MemoryService    ToolBroker     MCPManager     DesktopLease
   (loops, states, (graph, prefs,  (builtin +     (official      (one owner,
    checkpoints)    retrieval)      MCP tools)     Swift SDK)     takeover)
        |               |               |              |               |
        +---------------+-------+-------+--------------+---------------+
                                |                                      |
                          SQLiteStore (WAL, FTS5)           DesktopController
                                |                        (ScreenCaptureKit, CGEvent,
                          EventBus (fan-out)              AX, NSWorkspace, AppleScript)
                                |
                   InferenceProvider (OpenAI-compatible streaming)
```

## Modules

**PennantCore** holds every type that crosses a process boundary: identifiers, `AgentProfile`, `TaskRecord` and the `TaskState` machine, `Message` and `ContentPart`, `ToolSpec`/`ToolRecord`, memory entities and relations with `Provenance`, `Skill`, `Checkpoint`, desktop status and remote input, `HostEvent`/`EventPayload`, and the `ClientCommand`/`HostReply` protocol. It has no platform dependencies.

**PennantHostKit** is the host. Its contracts (`StoreProtocol`, `InferenceProvider`, `Tool`, `DesktopControlling`, `HostAPIDelegate`) are what the tests substitute.

- `Storage/SQLiteStore` is the source of truth. Tables are ordinary rows with a JSON column for the full record plus indexed columns for queries. FTS5 tables index messages, entities, preferences, and skills. The event log is an AUTOINCREMENT table; every durable event gets a monotonic sequence.
- `Inference/OpenAICompatibleProvider` streams chat completions, assembles tool calls from deltas, maps images to data URLs, and surfaces reasoning deltas. `TokenEstimator` budgets context.
- `Desktop/DesktopController` performs screen capture, input synthesis, accessibility reads, app control, and scripting. `DesktopLease` serialises access; `HumanInputMonitor` detects human input for pause-on-input. `PennantCursor` draws Pennant's own pointer, a click-through overlay above every app that agent screenshots leave out. `BackgroundInput` works in one app without the owner's pointer: AX actions on the element at a point, and events posted to that app's process.
- `Browser/BrowserLink` is the host's end of Pennant's Chrome extension (`Extensions/PennantChrome`, bundled in the app): a WebSocket on 127.0.0.1:7339 that accepts only the extension's origin. `Browser/WebTools` are the `web_*` tools that drive it, and `ChromeSites` keeps the sites the owner allowed. `ChromeExtension` keeps the copy Chrome loads in the data folder, stamped with a fingerprint of its files (the extension reports it, and the host asks an outdated one to reload). `ChromeSetup` adds the extension to Chrome for the owner (`chromeSetup`, Settings › Pennant › Chrome). `ChromeGuard` spots AppleScript that drives the owner's Chrome:
- **What counts as driving:** bringing it forward, opening or moving tabs, or scripts that click, fill in or navigate.
- **Where it's refused:** the runtime refuses it in the chat, which starts a thread instead. It also refuses it in a thread while the extension is connected, pointing at the `web_*` tools.
- **What stays allowed:** reading which page is open, or its text.
- `Tools/` holds the built-in tools (shell, files, browser, desktop) and `ToolBroker`, which also carries MCP tools while their servers are connected.
- `Memory/MemoryService` implements the memory rules and combined retrieval.
- `Runtime/TaskRuntime` runs tasks: `TaskRuntime.swift` holds its state, recovery and the loop, and a file per concern beside it (context, inference, tools, approvals, completion, delegation and the desktop lease, coding runs and the Pennant coding engine, models, the prompt inspector). `ContextBuilder` assembles the model's context from durable state. `Compactor` produces checkpoints. `SignOff` decides what the owner signs off on first. `HostService` wires everything; its models, client access and command table live in `HostService+Models`, `+Access` and `+Commands`.
- The Pennant chat (`TaskRuntime+Threads`): the one conversation people have with Pennant (`Conversation.isMain`, made at start). Its turns never wait for a task slot, read a work board of the threads in their turn note, and carry the thread tools (`start_thread`, `message_thread`, `read_thread`, `stop_thread`) but not the screen's input tools or `delegate_task`/`await_task`; every other conversation gets the reverse. A thread the chat starts is Pennant in a conversation of its own (`parentID` the chat, `requestedByTaskID` the chat's task). What comes of any thread reaches the chat as a `WorkUpdate` part: its cards (decided there by id, and marked with the outcome), its questions (Pennant passes the answer on), and its result when the chat asked for the work, when it failed, or when it made a report or a file. The apps open on the chat; threads are read there, not written in.
- The heartbeat (`Scheduling/Heartbeat`, `HostConfig.heartbeat`: on, every 30 minutes, at most 48 turns a day by default; Settings › Pennant, `pennant heartbeat`): each beat looks over the work without the model. Goal sessions whose cadence has come round since the last one start (`Scheduler.runDueGoalJobs`; the timer leaves goal jobs to it), except a goal waiting on the owner. Work that hasn't moved for 20 minutes, or a question or draft left for six hours, gets one turn of Pennant's in its chat (`heartbeatTurn`, raised once per six hours each), which nudges, stops or tells; "(nothing)" leaves no trace. A beat with nothing in it makes no model call.
- What reaches the chat comes from Pennant: a thread's result, failure, question or draft is worded by Pennant from the chat so far (`wordUpdate`, one tool-less call on its model), or kept to itself when the owner already knows (`WorkUpdate.silent`). Threads the chat starts get at most 30 steps, 45 minutes and 500k new tokens, then wrap up with what they have; long work takes stock every 15 steps.
- One card per decision (`TaskRuntime+CardReplacing`): before an agent's own card goes up (`request_approval`, the proposal tools), the cards it names in `replaces` and exact repeats from the same goal (its own thread and the chat it was proposed in, unless that's the Pennant chat), scheduled job or thread are withdrawn (they read "Replaced", and a task waiting on one goes on); other cards of the agent's still waiting there stop it until it passes `replaces` or `alongside`. Each thread the Pennant chat started is its own source. The gates' cards before a single command are never replaced.
- `MCP/MCPManager` owns server processes and connections.
- `API/HostAPIServer` accepts WebSocket clients, authenticates, forwards events, and streams screen frames. `DeviceTokens` keeps the local token and each signed-in device's token in the Keychain; `PeopleService` handles signing in and who may.

**PennantClientKit** is shared by both apps and the CLI: `HostSession` keeps a `ClientState` cache current from snapshots and events, reconnects with backoff, and replays events after the last sequence it saw.

## The task loop

1. A user message either answers a task waiting for the user, becomes a follow-up note for a task already running in that conversation, or creates a new task (`queued`).
2. The scheduler starts up to five loops at once (a task only waiting on a person, a helper or a coding run holds none, and the Pennant chat's turns neither wait for a slot nor take one). A loop transitions the task to `running` and repeats:
   - Build the context: system prompt (identity, rules, environment, governing preferences, relevant memory hits, relevant skills, task block, latest checkpoint) plus history after the checkpoint boundary. If the estimate exceeds the trigger fraction of the window, save a checkpoint first and rebuild.
   - Stream one model turn into an assistant message (deltas are transient events; the finalised message is durable).
   - If there are no tool calls, run completion checks and complete the task with the reply as its result.
   - For each tool call: record intent, enforce the allowlist, the read-back rule, and the fresh-screenshot rule; acquire the desktop lease when needed (`waitingForDesktop`); run the tool (`waitingForTool`); record the outcome; append the tool message.
   - A coding run on Claude Code leaves the loop: the thread's new messages go to the `claude` CLI, whose steps stream back into the thread and whose permission requests come back as `coderPermission` calls. A coding run on the Pennant engine stays in it, with three differences: the model is the thread's, the Coding setting's or the default (`codingProfile`); the tools are the five coding tools, scoped to the project folder (`ToolContext.project`); and each call goes through `coderPermission` as Claude Code's Bash, Write or Edit would, so both engines ask by the same rules. In plan mode its reply is the plan, put on the plan card; approved, the run gets its write tools.
3. Pause and cancel cancel the loop's Swift task. A tool that was mid-flight is recorded `uncertain` if consequential, `cancelled` otherwise. Resume re-queues the task; the next context starts from durable state plus a runtime note saying what happened.
4. On host start, tasks left `running`/`waitingForTool`/`waitingForDesktop` are recovered: `running` tool records become `uncertain`, `intended` become `cancelled`, and the task is re-queued with a note.

## Desktop sharing

`DesktopLease` has one holder. `acquire` returns immediately when free, otherwise queues (the task state shows why: another task, the user, or a pause). `humanTakeover` and `pause` revoke the holder and interrupt input synthesis; tools check `requireDesktop()` before every synthesised action and fail with `desktopRevoked` if the lease is gone. After any wait or interruption the runtime clears the task's fresh-screen flag, so the next pointer action is refused until `screenshot` or `ui_tree` runs.

In everyday mode `HostService` polls `HumanInputMonitor` five times a second while an agent holds the lease and pauses the lease when a human event is seen; synthesised events carry a marker so they are ignored.

Most work doesn't need the lease. Threads are told to try, in order:
1. Pennant's own Chrome tabs.
2. A Mac app in the background.
3. The owner's pointer and screen, only when neither can do it.

- **Chrome tabs (`web_*`).** The extension opens tabs in a Chrome window of Pennant's own, unfocused and in a tab group, and touches no other tab.
  - It clicks and types with Chrome's own input (`chrome.debugger`: `Input.dispatchMouseEvent`, `Input.insertText`), so the OS pointer and keyboard stay the owner's.
  - Pages are read as numbered elements; password values are never read.
  - It draws a cursor in the page and reports the screen point, so `PennantCursor` shows it above the owner's windows too.
  - With `chromeAsksForNewSites` on (off by default), a site's first use puts up a card (`ChromeSites`).
- **App tools (`app_*`).** `app_screenshot` captures one window, even a covered one (`SCContentFilter(desktopIndependentWindow:)`), and `app_click`, `app_type`, `app_press_key` and `app_scroll` act at points in that image through `BackgroundInput`.
  - Neither path takes the lease. Both stop while the owner has paused Pennant.

## Memory

Five forms map to tables: preferences (explicit instructions, versioned), entities and relations (graph, with provenance and status), tasks and checkpoints (task state), messages and tool records and artifacts (episodic), skills (procedural). `MemoryService.assertEntity` applies the rules: identical content refreshes `observedAt`; an asserted claim supersedes; an inferred claim that conflicts with an asserted one is stored as `contradicted` and the asserted one stays current. `retrieve` merges FTS hits (precise AND first, wide OR fallback), one-hop graph neighbours, optional embeddings, and earlier messages, ranking asserted above inferred. Forgetting clears content, removes the row from FTS and embeddings, and keeps a tombstone.

## Conversations and context

A conversation is the agent's history; a task is one unit of work inside it. The context for every turn is built from the whole conversation, so a follow-up task sees earlier turns verbatim until a checkpoint folds them into a summary. Checkpoints belong to the conversation (they carry `conversationID`), so later tasks inherit them. Each turn records the estimated context size and the model's window on the task (`usage.lastContextTokens`, `usage.contextWindowTokens`), which the apps show as a meter; `compactConversation` makes a checkpoint on demand, with or without a running task.

## Compaction

`Compactor.makeCheckpoint` asks the model for decisions, completed work, pending actions, open questions, next step, and a summary in JSON, then overrides what the model must not decide: outstanding tool records are appended to pending actions and removed from completed work; active delegations and artifacts come from the store; the event range covered is appended to the summary. If the model call fails, a mechanical summary is produced so compaction never blocks. The next context carries the checkpoint block and only the messages after its boundary; older screenshots are replaced by captions.

## Skills

`learn_skill` stores a provisional skill with the task as evidence; a same-name skill becomes a new version linked to the previous one. `use_skill` and `learn_skill` register the skill on the task; at completion the outcome is appended. Three successes at 75 % or better promote to `validated`; a failure marks the steps uncertain so the next run re-verifies them. Skills never grant tools: the allowlist and lease rules apply as always.

## Scheduled jobs

`Scheduler` ticks every 30 seconds and starts a task for each enabled job whose `nextRunAt` has passed, in a conversation named after the job (`⏰ name`), with the job's prompt and, when set, an instruction to follow a skill. The outcome is recorded from the task's terminal transition. Expressions are parsed by `CronSchedule`: intervals, friendly phrases (`daily at 09:00`, `weekdays at 08:30`, `weekly on mon,thu at 18:00`, `monthly on 1 at 07:00`, `once at …`), and 5-field cron. Jobs missed by more than six hours while the host was down are rescheduled, not caught up. Agents create jobs with `schedule_job`; the apps have a Schedules screen with presets and a live preview.

## Built-in and imported skills

`BuiltinSkills` seeds a small set on first run (schedule a recurring job, fill a web form, research and write a brief, inspect an app's interface, import skills), versioned so updates re-seed without touching outcomes; they can be disabled but not deleted. `SkillImporter` reads the `SKILL.md` format shared by Claude Code, Codex, and the Agent Skills standard: front matter `name` and `description`, the Markdown body as instructions, numbered lines as steps, and small text files under the folder as scripts. Re-importing an unchanged skill is a no-op; a changed one becomes a new version. `import_skills` (tool), `pennant skills import`, and the Skills screen's Import sheet all use it, and known folders (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, project-level equivalents) are scanned automatically.

## MCP

Each configured server gets a `Client` from the official SDK over stdio (a spawned process with pipes) or HTTP (bearer token from the Keychain). Tools are wrapped as `<server>__<tool>` with the server's schema and annotations (read-only servers are not treated as consequential). They are registered while the server is connected and removed when it disconnects.
