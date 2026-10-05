# Status

## Tests

`swift test --skip LiveInferenceTests` runs the whole suite in about half a minute: `PennantCoreTests` (models, the wire protocol, config, the MCP catalogue), `PennantHostKitTests` (the host, with in-process stand-ins for every model, sign-in and service it talks to) and `PennantUITests` (client state and view logic). What each area is checked by:

| Area | Tests |
| --- | --- |
| Store: events, tasks, messages, full-text search, memory graph, forgetting, embeddings, skills, backups, deleting conversations | `SQLiteStoreTests` |
| The runtime: the tool loop with intent and outcome records, pause and resume, questions, takeover and the fresh-screen rule, recovery after a crash or a restart with read-back, helpers, compaction, task limits | `RuntimeTests`, `ApprovalTests` |
| The Pennant chat: one chat that never closes, threads it starts, steers, reads and stops, news from them in Pennant's words (or kept quiet), drafts introduced, limits and wrap-up, its own task slot, each thread its own card source; the heartbeat (goal sessions when due, a look at stuck work, quiet beats free, a daily cap) | `PennantChatTests`, `PennantChatSpeedTests`, `SpokenTextTests`, `WorkUpdateTests`, `HeartbeatTests`, `BrowserRunnerTests` |
| The owner's sign-offs, cards and what runs after an approval; coding runs on both engines and what they may do without asking; acting on GitHub only as the App | `SignOffTests`, `ApprovalTests`, `CodingRunTests`, `PennantEngineTests`, `CodingPermissionTests`, `GitHubIdentityTests`, `ClaudeCodeEngineTests` |
| Memory: retrieval with citations, passages, aliases and removed names, upkeep | `MemoryRetrievalTests`, `MemoryKeeperTests` |
| Skills (import, versions, git sources), teach mode, scheduled jobs, goals, reports, the health review | `SkillImportTests`, `TeachingTests`, `SchedulingTests`, `GoalTests`, `ReportTests`, `HealthToolsTests` |
| Models: OpenAI-compatible endpoints, Azure AI Foundry, the ChatGPT account, the on-device model, routing and fallbacks | `InferenceTests`, `ChatGPTProviderTests`, `AppleOnDeviceProviderTests`, `ModelRoutingTests` |
| The API server, sign-in and people, device tokens, TLS pinning, push notifications | `APITests`, `PeopleTests`, `PushServiceTests`, `CloudflareAccessTests`, `HostAddressesTests` |
| Channels (Teams, iMessage, Telegram), native connectors, MCP sign-in | `ChannelTests`, `TeamsTests`, `ChannelCardTests`, `NativeConnectorTests`, `MCPAuthTests` |
| Desktop tools and the lease, apps in the background, Pennant in Chrome (site cards, tabs it owns, the paused stop), attachments, files, the Library and vault, moving to another Mac, the rename migrations | `DesktopToolsTests`, `DesktopLeaseTests`, `AppToolsTests`, `WebToolsTests`, `ChromeGuardTests`, `PromptInspectionTests`, `AttachmentTests`, `LibraryVaultTests`, `PennantTransferTests`, `RenameMigrationTests` |

`LiveInferenceTests` talk to a real model: `PENNANT_LIVE_INFERENCE=1` (with `PENNANT_LIVE_BASE_URL` and `PENNANT_LIVE_MODEL`) runs them against any OpenAI-compatible endpoint. `AppleOnDeviceProviderTests` run for real when Apple Intelligence is on and skip otherwise.

The iPhone's live screen has UI tests with real touches in the simulator (`PennantiOSUITests`, against the debug touch lab: pinch, taps while zoomed, two-finger right click, drags, trackpad mode): `xcodebuild test -scheme PennantiOS -destination 'platform=iOS Simulator,name=iPhone 17'`. The Mac and iPhone apps are built by `Scripts/build-apps.sh`; `Scripts/demo-shots.sh` walks both through every screen against a demo host.

## Not yet verified

- The ChatGPT account is tested against a stand-in of its service; it follows the Codex CLI's own client, and OpenAI can change what it accepts without notice (see RUNBOOK).
- MCP sign-in is tested against an in-process authorization server; public servers vary in what they support.
- Embedding retrieval quality is not measured.
- Talk mode is tested for its text and its message flow, and its voice renders and resamples on the Mac. Speaking and listening together (echo cancellation, interrupting) is checked by people, not tests.
- The natural voice was run end to end on an M5 Max, through the app's own download and helper code:
  - **Kokoro:** downloaded in 35 s, loaded in 0.3 s, and said a sentence in 0.04–0.15 s. A stop cut it off within 0.1 s.
  - **Qwen3-TTS 1.7B:** loaded in 1–4 s, started speaking in 0.13–0.2 s, and ran at about 3.4× real time. Cloning with it ran slower than real time, which is too slow for conversation.
  - **Penny (Qwen3-TTS 0.6B, cloning):** loaded in 0.9 s, started speaking in 0.09 s, and ran at about 5× real time.
  - **The command line:** a two-scene narration in a cloned voice took 16 s through the video skill's script. Whisper heard both clips word for word.
  - **Not covered:** how the voices sound, which people judge; Intel Macs don't get the voice at all.
- The Chrome extension was run end to end only in headless Chrome for Testing, against a host on a spare port.
  - It opened, read, clicked, typed and searched, and the site card refused a site it hadn't been allowed.
  - Set it up for me was run against a visible Chrome for Testing: Developer mode, Load unpacked and the folder, connected in about 13 seconds. Not run yet in Chrome itself, or with Chrome in another language (the routine finds controls by their English names; a failure falls back to the steps by hand).
  - Not checked yet in a visible Chrome:
    - whether its window stays behind the owner's;
    - Chrome's "started debugging this browser" bar;
    - input while its window is covered.
- Apps in the background were checked on Calculator, under other windows. Apps that ignore events posted to their process (some games, some Electron apps) still need the screen.
- Real jobs are not measured yet: completion rate, how often a person had to step in, duplicate actions, memory accuracy.

## Known limitations

- A small local model sometimes claims actions it did not perform. The runtime refuses a "remembered" claim without a memory tool record and nudges once; it cannot catch every false claim. Use a stronger model for real work.
- The Apple on-device model has no vision (screenshots become a text note), a small window (4096 tokens on macOS 26, 8192 on macOS 27), and ends its turn after the first tool batch; see RUNBOOK, "Apple on-device model".
