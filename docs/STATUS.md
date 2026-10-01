# Status

## Tests

`swift test --skip LiveInferenceTests` runs the whole suite in about half a minute: `PennantCoreTests` (models, the wire protocol, config, the MCP catalogue), `PennantHostKitTests` (the host, with in-process stand-ins for every model, sign-in and service it talks to) and `PennantUITests` (client state and view logic). What each area is checked by:

| Area | Tests |
| --- | --- |
| Store: events, tasks, messages, full-text search, memory graph, forgetting, embeddings, skills, backups, deleting conversations | `SQLiteStoreTests` |
| The runtime: the tool loop with intent and outcome records, pause and resume, questions, takeover and the fresh-screen rule, recovery after a crash or a restart with read-back, helpers, compaction, task limits | `RuntimeTests`, `ApprovalTests` |
| The owner's sign-offs, cards and what runs after an approval; coding runs on both engines and what they may do without asking; acting on GitHub only as the App | `SignOffTests`, `ApprovalTests`, `CodingRunTests`, `PennantEngineTests`, `CodingPermissionTests`, `GitHubIdentityTests`, `ClaudeCodeEngineTests` |
| Memory: retrieval with citations, passages, aliases and removed names, upkeep | `MemoryRetrievalTests`, `MemoryKeeperTests` |
| Skills (import, versions, git sources), teach mode, scheduled jobs, goals, reports, the health review | `SkillImportTests`, `TeachingTests`, `SchedulingTests`, `GoalTests`, `ReportTests`, `HealthToolsTests` |
| Models: OpenAI-compatible endpoints, Azure AI Foundry, the ChatGPT account, the on-device model, routing and fallbacks | `InferenceTests`, `ChatGPTProviderTests`, `AppleOnDeviceProviderTests`, `ModelRoutingTests` |
| The API server, sign-in and people, device tokens, TLS pinning, push notifications | `APITests`, `PeopleTests`, `PushServiceTests`, `CloudflareAccessTests`, `HostAddressesTests` |
| Channels (Teams, iMessage, Telegram), native connectors, MCP sign-in | `ChannelTests`, `TeamsTests`, `ChannelCardTests`, `NativeConnectorTests`, `MCPAuthTests` |
| Desktop tools and the lease, attachments, files, the Library and vault, moving to another Mac, the rename migrations | `DesktopToolsTests`, `DesktopLeaseTests`, `AttachmentTests`, `LibraryVaultTests`, `PennantTransferTests`, `RenameMigrationTests` |

`LiveInferenceTests` talk to a real model: `PENNANT_LIVE_INFERENCE=1` (with `PENNANT_LIVE_BASE_URL` and `PENNANT_LIVE_MODEL`) runs them against any OpenAI-compatible endpoint. `AppleOnDeviceProviderTests` run for real when Apple Intelligence is on and skip otherwise.

The Mac and iPhone apps are built by `Scripts/build-apps.sh`; `Scripts/demo-shots.sh` walks both through every screen against a demo host.

## Not yet verified

- The ChatGPT account is tested against a stand-in of its service; it follows the Codex CLI's own client, and OpenAI can change what it accepts without notice (see RUNBOOK).
- MCP sign-in is tested against an in-process authorization server; public servers vary in what they support.
- Embedding retrieval quality is not measured.
- Real jobs are not measured yet: completion rate, how often a person had to step in, duplicate actions, memory accuracy.

## Known limitations

- A small local model sometimes claims actions it did not perform. The runtime refuses a "remembered" claim without a memory tool record and nudges once; it cannot catch every false claim. Use a stronger model for real work.
- The Apple on-device model has no vision (screenshots become a text note), a small window (4096 tokens on macOS 26, 8192 on macOS 27), and ends its turn after the first tool batch; see RUNBOOK, "Apple on-device model".
