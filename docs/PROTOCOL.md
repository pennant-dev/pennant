# Host protocol

One WebSocket per client. Text frames carry `WireMessage` JSON; binary frames carry screen frames. Types are in `Sources/PennantCore/Protocol.swift`; the codec is `JSONCodec` (ISO-8601 dates, sorted keys).

```json
{"command": {"id": "…", "body": {"hello": {"clientID": "…", "displayName": "…", "platform": "macOS", "appVersion": "0.1.0", "protocolVersion": 1, "lastEventSeq": 0, "token": "…"}}}}
{"reply": {"commandID": "…", "result": {"welcome": { "host": {…}, "agents": […], "tasks": […], "conversations": […], "desktop": {…}, "mcpServers": […], "latestEventSeq": 812 }}}}
{"event": {"seq": 813, "at": "2026-09-22T01:09:29.766Z", "payload": {"taskTransition": {…}}}}
```

## Handshake

- The first command must be `hello` or one of the sign-in commands (`signInOptions`, `beginSignIn`, `completeSignIn`, `signInWithPassword`, `redeemInvite`). Anything else gets `error(unauthenticated)` and the socket closes.
- Signing in (with Microsoft, Google or GitHub, a password, or an invite's one-time code) replies `signedIn` with a token for that device. The Mac's own apps and the CLI read the host's local token from `client-token` in its data folder instead.
- `hello` carries the token and the last event sequence the client applied. The host replies `welcome(StateSnapshot)`; the client then requests `listEvents(afterSeq:limit:)` pages until it has caught up, and live events follow.

## Events

`HostEvent.seq` is monotonic for durable events. `messageDelta`, `hostStatus`, and `desktopStatus` are transient (seq 0) and never replayed; the welcome snapshot carries their current values. Every message, task transition, tool record, checkpoint, memory change, skill change, MCP status, and notice is durable.

## Commands

`CommandBody` in `Protocol.swift` documents each command and its reply; they are grouped there the same way.

| Group | Commands |
| --- | --- |
| Session and signing in | `hello`, `signInOptions`, `beginSignIn`, `completeSignIn`, `signInWithPassword`, `redeemInvite`, `ping` |
| People | `listPeople`, `invitePerson`, `removeInvite`, `removePerson`, `setPersonRole`, `updateSignInSettings`, `updateMyAccount`, `setMyPassword` |
| The agent | `updateAgent`, `retireAgent`, `inspectPrompt` |
| Conversations | `sendMessage`, `listMessages`, `answerQuestion`, `answerChoices`, `uploadAttachment`, `compactConversation`, `getConversationCheckpoints`, `closeConversation`, `deleteConversations`, `pruneConversations` |
| Tasks | `pauseTask`, `resumeTask`, `cancelTask`, `getToolRecords`, `getArtifact` |
| Approvals and reports | `decideApproval`, `listPendingApprovals`, `listReports` |
| Coding runs | `setConversationFolder`, `setConversationCoding`, `listProjects`, `coderPermission`, `coderTool`, `checkGitHubApp`, `setReviewsGitHubApp` |
| Desktop | `getDesktopStatus`, `takeoverDesktop`, `releaseDesktop`, `pauseDesktop`, `resumeDesktop`, `setPauseOnHumanInput`, `subscribeScreen`, `unsubscribeScreen`, `remoteInput`, `captureScreenshot`, `requestPermissions`, `recheckPermissions`, `resetPermission` |
| Memory | `memoryOverview`, `searchMemory`, `listEntities`, `listPreferences`, `listRelations`, `upsertEntity`, `upsertPreference`, `forgetEntity`, `forgetPreference`, `memoryEvidence`, `renameEntity`, `mergeEntities`, `memoryUpkeepLog`, `undoMemoryUpkeep`, `listRemovedMemory`, `restoreRemovedMemory` |
| Skills | `listSkills`, `updateSkill`, `setSkillStatus`, `deleteSkill`, `importSkills`, `previewSkillImport`, `deleteSkills`, `addSkillFolder`, `removeSkillFolder`, `scanSkillLocations` |
| Teach mode | `startTeaching`, `stopTeaching`, `cancelTeaching`, `addTeachingNote`, `removeTeachingEvents`, `getTeaching`, `draftSkillFromTeaching` |
| Library | `listLibrary`, `uploadLibraryAsset`, `updateLibraryAsset`, `deleteLibraryAsset`, `saveLibraryCollection`, `deleteLibraryCollection`, `libraryPreview`, `listVault`, `saveVaultItem`, `deleteVaultItem`, `listChromeProfiles`, `listChromeSites`, `importChromeSignIns`, `listBrowserSignIns`, `removeBrowserSignIn` |
| Goals | `listGoals`, `upsertGoal`, `setGoalStatus` (any status, proposed included), `deleteGoal` (with its board and jobs; its conversation stays), `listGoalItems`, `upsertGoalItem`, `commentGoalItem` |
| Scheduled jobs | `listSchedules`, `upsertSchedule`, `deleteSchedule`, `runScheduleNow`, `previewSchedule` |
| Channels | `listChannels`, `setChannelEnabled`, `setIMessagePersonal`, `setTelegramToken`, `setTeamsBot`, `createChannelLink`, `upsertChannelContact`, `removeChannelContact` |
| Notifications on iPhones | `registerPushDevice`, `getPushStatus`, `setPushKey`, `sendTestPush` |
| Connected services | `listMCPServers`, `addMCPServer`, `removeMCPServer`, `reconnectMCPServer`, `beginMCPAuth`, `cancelMCPAuth`, `setMCPCredential`, `signOutMCP`, `listMCPCatalog` |
| Models | `testModel`, `usageReport`, `listModels`, `azureStatus`, `azureLogin`, `azureSubscriptions`, `azureResources`, `azureDeployments` |
| ChatGPT account as the inference provider | `beginChatGPTSignIn`, `importCodexLogin`, `signOutChatGPT`, `getChatGPTAccount`, `listChatGPTModels` |
| Any signed-in provider | `beginProviderSignIn`, `importProviderLogin`, `signOutProvider`, `getProviderAccount`, `listProviderModels` |
| Pennant in Chrome | `chromeStatus` (connected, browser, allowed sites, the extension's ID and folder), `chromeForgetSite`, `chromeSetup` (owner only: Pennant adds the extension to Chrome on the host's Mac) |
| The host | `getDiagnostics`, `listEvents`, `getConfig`, `updateConfig`, `exportData`, `importData`, `runTool` (owner only: one built-in tool run by hand, as `pennant tool`) |

The Pennant chat is the conversation with `isMain: true` (one per host, made at start; older hosts have none). Messages in it can carry `update` parts (`WorkUpdate`: a thread finished or failed, asks something, or put up a card, with the card's `approvalID` and, once decided, its `outcome`); clients from before them show a placeholder line. A card in an update is decided with `decideApproval` like any other.

`sendMessage` returns `messageAccepted(messageID, conversationID, taskID)`; the reply itself arrives as events (`messageAppended` for the streaming assistant message, `messageDelta` while it streams, `messageFinalized` when done, `taskTransition` as the task moves).

## Screen stream

`subscribeScreen(options)` starts frames for that client only. Each binary frame is a 4-byte big-endian header length, a JSON `ScreenFrameHeader` (sequence, size, timestamp, normalised cursor, current owner), then JPEG bytes. Slow clients receive the latest frame only. `unsubscribeScreen` stops it. Task messages and frames have separate lifecycles: closing the stream does not affect the control channel.

## Remote input

During human takeover (`takeoverDesktop`), `remoteInput` accepts pointer moves, clicks, drags (down/up), scroll, typed text, and key chords with normalised 0…1 coordinates. The host refuses remote input unless the human holds the desktop.
