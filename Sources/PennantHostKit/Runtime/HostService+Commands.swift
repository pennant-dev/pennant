import PennantCore
import Foundation

/// The commands clients send, one case each, grouped by what they touch.
extension HostService {
    // MARK: Commands

    /// The task id the owner's hand-run tools (`pennant tool`) share.
    static let consoleTask = TaskID("owner-console")

    public func handle(_ body: CommandBody, from client: ConnectedClient) async -> ReplyBody {
        do {
            return try await dispatch(body, client: client)
        } catch let error as TaskError {
            return .error(code: "task", message: error.description)
        } catch let error as ToolError {
            return .error(code: "tool", message: error.description)
        } catch let error as DesktopError {
            return .error(code: "desktop", message: error.description)
        } catch let error as InferenceError {
            return .error(code: "inference", message: error.description)
        } catch let error as HostCommandError {
            return .error(code: "invalid", message: error.description)
        } catch {
            return .error(code: "internal", message: String(describing: error))
        }
    }

    /// A skill source is a folder, a SKILL.md, or a git URL. URLs are cloned (or pulled) under the data folder and
    /// remembered as a location so they can be re-imported later.
    private func resolveSkillSource(_ path: String) async throws -> String {
        guard SkillImporter.isGitURL(path) else { return path }
        let reposRoot = paths.root.appendingPathComponent("skills/repos")
        let checkout = try SkillImporter.materialize(gitURL: path, reposRoot: reposRoot)
        var repos = await SkillImporter.repos(store: store)
        repos[checkout.path] = path.trimmingCharacters(in: .whitespaces)
        try await SkillImporter.setRepos(repos, store: store)
        var folders = await SkillImporter.customFolders(store: store)
        if !folders.contains(checkout.path) { folders.append(checkout.path); try await SkillImporter.setCustomFolders(folders, store: store) }
        return checkout.path
    }

    /// Largest file a message can carry (the socket frame is 32 MB and base64 adds a third).
    static let maxUploadBytes = 20 * 1024 * 1024

    /// Stores an attachment in the artifact store. Images reach the model as images; other files are also saved
    /// under `<data>/uploads` so the agent can read them with its file tools.
    private func storeUpload(fileName: String, mimeType: String, base64: String) async throws -> Attachment {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { throw HostCommandError.invalid("The attachment was empty or unreadable.") }
        guard data.count <= Self.maxUploadBytes else { throw HostCommandError.invalid("\(fileName) is larger than \(Self.maxUploadBytes / 1_048_576) MB.") }
        let name = (fileName as NSString).lastPathComponent.isEmpty ? "attachment" : (fileName as NSString).lastPathComponent
        let record = ArtifactRecord(kind: "upload", mimeType: mimeType, byteCount: data.count, fileName: name, caption: name)
        try await store.putArtifact(record, data: data)
        var path: String?
        if !mimeType.hasPrefix("image/") {
            let folder = paths.root.appendingPathComponent("uploads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = name.replacingOccurrences(of: "/", with: "-")
            let url = folder.appendingPathComponent("\(record.id.rawValue.prefix(8))-\(safe)")
            try data.write(to: url, options: .atomic)
            path = url.path
        }
        log.info("Stored upload \(name) (\(data.count) bytes, \(mimeType))", category: "api")
        return Attachment(artifactID: record.id, fileName: name, mimeType: mimeType, byteCount: data.count, path: path)
    }

    /// Drafts a provisional skill from the stopped demonstration with the current model, and saves it (as a new
    /// version when a skill of that name exists).
    private func draftTaughtSkill(goal: String?) async throws -> Skill {
        _ = await teaching.stop()
        guard let session = await teaching.current else {
            throw HostCommandError.invalid("There is no demonstration to draft from. Start teaching first.")
        }
        guard session.events.contains(where: { !$0.isNote }) || session.events.count >= 2 else {
            throw HostCommandError.invalid(SkillDrafter.DraftError.emptyDemonstration.description)
        }
        await teaching.setDrafting(true, goal: goal)
        let resolvedGoal = (await teaching.current)?.goal ?? session.goal
        let current = await teaching.current ?? session
        do {
            let response = try await provider.complete(InferenceRequest(messages: SkillDrafter.messages(goal: resolvedGoal, session: current), maxOutputTokens: 4000, temperature: 0.2, disableTools: true, jsonMode: true))
            var skill = try SkillDrafter.skill(from: response.text, goal: resolvedGoal, session: current)
            let existing = try await store.listSkills(includeDisabled: true).filter { $0.name.caseInsensitiveCompare(skill.name) == .orderedSame }
            if let latest = existing.max(by: { $0.version < $1.version }) {
                skill.version = latest.version + 1
                skill.previousVersionID = latest.id
            }
            try await store.upsertSkill(skill)
            await publish(.skillUpserted(skill))
            await teaching.finishDraft(skillID: skill.id, error: nil)
            log.info("Drafted taught skill '\(skill.name)' v\(skill.version) with \(skill.steps.count) steps", category: "teaching")
            return skill
        } catch {
            let message = (error as? SkillDrafter.DraftError)?.description ?? String(describing: error)
            await teaching.finishDraft(skillID: nil, error: message)
            throw HostCommandError.invalid(message)
        }
    }

    /// The environment a coding session acts on GitHub with: a fresh installation token for `identity`, signed with the
    /// App's private key from the Vault.
    static func gitHubEnvironment(for identity: GitHubAppIdentity, vault: VaultService, minter: GitHubAppToken = GitHubAppToken()) async throws -> [String: String] {
        let resolved = await vault.resolve([identity.vaultEntry])
        guard let pem = resolved.entries[identity.vaultEntry.lowercased()]?["secret"] ?? resolved.entries.values.first?["secret"], !pem.isEmpty else {
            throw GitHubAppToken.Failure(description: "the Vault has no private key under \"\(identity.vaultEntry)\"")
        }
        return try await minter.environment(for: identity, privateKeyPEM: pem)
    }

    /// The Coding projects' folders, then git repositories in the usual places, each once.
    private func chromeStatus() async -> ChromeStatus {
        let status = await chrome.currentStatus()
        return ChromeStatus(connected: status.connected, browser: status.browser, sites: await chromeSites.list(),
                            extensionID: BrowserLink.extensionID, folder: await chrome.installed?.folder.path)
    }

    private func projectFolders() -> [String] {
        var seen = Set<String>()
        return ((config.coding?.projects.map(\.path) ?? []) + Self.gitProjects()).filter { seen.insert($0).inserted }
    }

    /// Git repositories a coding run could work in: folders with a `.git` under Documents, Developer, Projects,
    /// src and code, two levels deep, most recently changed first.
    static func gitProjects() -> [String] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var found: [(String, Date)] = []
        func visit(_ dir: URL, depth: Int) {
            guard depth <= 2, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if fm.fileExists(atPath: item.appendingPathComponent(".git").path) {
                    found.append((item.path, (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
                } else if !["node_modules", "Library", ".build", "build", "dist"].contains(item.lastPathComponent) {
                    visit(item, depth: depth + 1)
                }
            }
        }
        for name in ["Documents", "Developer", "Projects", "src", "code"] { visit(home.appendingPathComponent(name), depth: 1) }
        return found.sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
    }

    /// Who a client's messages and decisions are from: the signed-in person, else the Mac's own user.
    static func author(of client: ConnectedClient) -> MessageAuthor {
        if let p = client.person { return MessageAuthor(id: p.id, name: p.name) }
        return MessageAuthor(id: PersonID("owner"), name: NSFullUserName())
    }

    /// The people list as this client may see it: members don't see sign-in settings or invite codes.
    private func visibleDirectory(for client: ConnectedClient) async -> PeopleDirectory {
        var directory = await people.snapshot()
        if !client.isOwner {
            directory.signIn = SignInSettings(allowedTenants: [])
            directory.invites = []
        }
        return directory
    }

    private static let ownerOnly = ReplyBody.error(code: "owner_only", message: "Only the host's owner can change who has access.")

    private func dispatch(_ body: CommandBody, client: ConnectedClient) async throws -> ReplyBody {
        switch body {
        case .hello, .ping, .subscribeScreen, .unsubscribeScreen, .screenFrameReceived, .listEvents, .signInOptions, .beginSignIn, .completeSignIn, .signInWithPassword, .redeemInvite:
            return .ok

        // People: anyone signed in may see who's here; only the owner changes it.
        case .listPeople:
            return .people(await visibleDirectory(for: client))
        case .invitePerson(let email):
            guard client.isOwner else { return Self.ownerOnly }
            try await people.invite(email)
            return .people(await people.snapshot())
        case .removeInvite(let email):
            guard client.isOwner else { return Self.ownerOnly }
            try await people.removeInvite(email)
            return .people(await people.snapshot())
        case .removePerson(let id):
            guard client.isOwner else { return Self.ownerOnly }
            try await people.remove(id)
            await devices.revoke(personID: id)
            return .people(await people.snapshot())
        case .setPersonRole(let id, let role):
            guard client.isOwner else { return Self.ownerOnly }
            try await people.setRole(id, role)
            return .people(await people.snapshot())
        case .updateSignInSettings(let settings):
            guard client.isOwner else { return Self.ownerOnly }
            try await people.update(settings)
            return .people(await people.snapshot())
        case .updateMyAccount(let name, let email):
            let me = try await me(client)
            _ = try await people.updateAccount(me.id, name: name, email: email)
            return .people(await visibleDirectory(for: client))
        case .setMyPassword(let current, let new):
            let me = try await me(client)
            // The Mac's own apps are the owner already; elsewhere the current password proves it's you.
            let atTheMac = client.person == nil && client.isLocal
            _ = try await people.setPassword(me.id, new: new, current: current, skipCurrent: atTheMac)
            return .people(await visibleDirectory(for: client))

        // Agents
        case .updateAgent(let agent):
            guard try await store.agent(agent.id) != nil else { return .error(code: "not_found", message: "Agent not found") }
            return .agent(try await saveAgentProfile(agent))
        case .retireAgent(let id):
            guard try await store.agent(id) != nil else { return .error(code: "not_found", message: "Agent not found") }
            try await retire(id)
            return .ok

        // Conversation
        case .sendMessage(let agentID, let conversationID, let text, let attachments):
            let (m, c, t) = try await runtime.submitUserMessage(agentID: agentID, conversationID: conversationID, text: text, attachments: attachments,
                                                                author: Self.author(of: client))
            return .messageAccepted(messageID: m, conversationID: c, taskID: t)
        case .listMessages(let conversationID, let before, let limit):
            let capped = max(1, min(limit, 200))
            let items = try await store.listMessages(conversationID: conversationID, before: before, limit: capped + 1)
            return .messages(Page(items: Array(items.prefix(capped)).reversed(), hasMore: items.count > capped))
        case .answerQuestion(let taskID, let text):
            try await runtime.answerQuestion(taskID: taskID, text: text)
            return .ok
        case .compactConversation(let id):
            return .task(try await runtime.compactConversation(id))
        case .closeConversation(let id, let closed):
            try await runtime.closeConversation(id, closed: closed)
            return .ok
        case .deleteConversations(let ids):
            guard client.isOwner else { return Self.ownerOnly }
            try await runtime.deleteConversations(ids, by: client.displayName)
            return .ok
        case .registerPushDevice(let token, let environment, let teamID, let name, let bundleID):
            let me = try? await me(client)
            try await push.register(PushDevice(token: token, environment: environment, personID: me?.id, name: name, bundleID: bundleID), teamID: teamID)
            return .pushStatus(await push.status())
        case .getPushStatus:
            return .pushStatus(await push.status())
        case .setPushKey(let keyID, let teamID, let p8):
            guard client.isOwner else { return Self.ownerOnly }
            try await push.setKey(keyID: keyID, teamID: teamID, p8: p8)
            return .pushStatus(await push.status())
        case .sendTestPush:
            let me = try? await me(client)
            let everyone = client.isOwner && client.person == nil
            let n = await push.notify(title: "Pennant", body: "Notifications work. You'll hear from Pennant when something needs you.",
                                      to: everyone ? [] : [me?.id].compactMap { $0 }, key: nil)
            var status = await push.status()
            if n == 0, status.lastError == nil { status.lastError = status.devices.isEmpty ? "No iPhone has registered yet: open Pennant on the iPhone and allow notifications." : "Nothing was sent." }
            return .pushStatus(status)
        case .pruneConversations(let days):
            guard client.isOwner else { return Self.ownerOnly }
            let goalThreads = Set(try await goals.list().filter { $0.status == .active }.compactMap(\.conversationID))
            return .pruned(count: try await runtime.pruneConversations(idleDays: days, keep: goalThreads))
        case .getConversationCheckpoints(let id):
            return .checkpoints(try await store.checkpoints(conversationID: id))

        // Tasks
        case .pauseTask(let id, let reason):
            try await runtime.pauseTask(id, reason: reason.isEmpty ? "Paused by \(client.displayName)" : reason)
            return .ok
        case .resumeTask(let id):
            try await runtime.resumeTask(id)
            return .ok
        case .cancelTask(let id, let reason):
            try await runtime.cancelTask(id, reason: reason.isEmpty ? "Cancelled by \(client.displayName)" : reason)
            return .ok
        case .getToolRecords(let id):
            return .toolRecords(try await store.toolRecords(taskID: id))

        // Desktop
        case .getDesktopStatus:
            return .desktop(await desktopStatus())
        case .takeoverDesktop:
            await lease.humanTakeover()
            await publish(.notice(level: .info, agentID: nil, text: "\(client.displayName) took control of the computer."))
            return .desktop(await desktopStatus())
        case .releaseDesktop:
            await lease.humanRelease()
            return .desktop(await desktopStatus())
        case .pauseDesktop:
            await lease.pause()
            await publish(.notice(level: .info, agentID: nil, text: "Computer use paused by \(client.displayName)."))
            return .desktop(await desktopStatus())
        case .resumeDesktop:
            await lease.resume()
            return .desktop(await desktopStatus())
        case .setPauseOnHumanInput(let on):
            await lease.setPauseOnHumanInput(on)
            config.desktop.pauseOnHumanInput = on
            try? ConfigLoader.save(config, to: paths.configURL)
            return .desktop(await desktopStatus())
        case .remoteInput(let input):
            guard await lease.humanHasControl else { return .error(code: "no_control", message: "Take over the computer first") }
            try await applyRemoteInput(input)
            return .ok
        case .captureScreenshot(let maxWidth):
            let shot = try await desktop.captureScreen(maxWidth: max(320, min(maxWidth, 4096)))
            let ref = ImageRef(artifactID: ArtifactID("transient"), mimeType: "image/jpeg", width: shot.width, height: shot.height, caption: "screenshot")
            return .screenshot(ref, base64: shot.jpeg.base64EncodedString())

        // Memory
        case .memoryOverview:
            var overview = try await store.memoryOverview()
            let counts = await memory.indexCounts()
            overview.passageCount = counts.passages
            overview.embeddedCount = counts.embedded
            overview.embeddableCount = counts.embeddable
            overview.needsReviewCount = counts.needsReview
            return .memoryOverview(overview)
        case .memoryEvidence(let id):
            return .memoryPassages(try await memory.evidence(for: id))
        case .renameEntity(let id, let name):
            return .entity(try await memory.rename(id, to: name))
        case .mergeEntities(let from, let into):
            return .entity(try await memory.merge(from, into: into))
        case .memoryUpkeepLog:
            return .memoryUpkeep(await memory.upkeepLog())
        case .undoMemoryUpkeep(let id):
            return .memoryUpkeep(try await memory.undoUpkeep(id))
        case .listChannels:
            guard client.isOwner else { return Self.ownerOnly }
            return .channels(await channels.overview())
        case .setChannelEnabled(let kind, let on):
            guard client.isOwner else { return Self.ownerOnly }
            try await channels.setEnabled(kind, on)
            return .channels(await channels.overview())
        case .setIMessagePersonal(let on):
            guard client.isOwner else { return Self.ownerOnly }
            try await channels.setIMessagePersonal(on)
            return .channels(await channels.overview())
        case .setTelegramToken(let token):
            guard client.isOwner else { return Self.ownerOnly }
            try await channels.setTelegramToken(token)
            return .channels(await channels.overview())
        case .setTeamsBot(let appID, let tenantID, let publicURL, let secret):
            guard client.isOwner else { return Self.ownerOnly }
            try await channels.setTeams(appID: appID, tenantID: tenantID, publicURL: publicURL, secret: secret)
            return .channels(await channels.overview())
        case .createChannelLink(let kind):
            guard client.isOwner else { return Self.ownerOnly }
            let owner = try? await people.ownerAccount(defaultName: NSFullUserName())
            let me = client.person ?? owner
            return .channelLink(try await channels.linkCode(kind: kind, personID: me?.id, name: me?.name ?? NSFullUserName()))
        case .upsertChannelContact(let contact):
            guard client.isOwner else { return Self.ownerOnly }
            try await channels.upsert(contact)
            return .channels(await channels.overview())
        case .removeChannelContact(let id):
            guard client.isOwner else { return Self.ownerOnly }
            try await channels.remove(id)
            return .channels(await channels.overview())
        case .listRemovedMemory:
            return .removedMemory(try await memory.ignoredNames())
        case .restoreRemovedMemory(let name, let kind):
            try await memory.restore(name, kind: kind)
            return .removedMemory(try await memory.ignoredNames())
        case .searchMemory(let query):
            return .memoryHits(try await memory.retrieve(query, agent: nil, includeInstructions: query.instructions ?? true))
        case .listEntities(let kind, let scope, let limit):
            return .entities(try await store.listEntities(kind: kind, scope: scope, includeInactive: false, limit: max(1, min(limit, 2000))))
        case .listPreferences(let scope):
            return .preferences(try await store.listPreferences(scopes: scope.map { [$0] }, includeInactive: false))
        case .listRelations(let entityID):
            return .relations(try await store.relations(entityID: entityID, includeInactive: false))
        case .upsertEntity(let entity):
            if try await store.entity(entity.id) != nil {
                return .entity(try await memory.editEntity(entity))
            }
            let created = try await memory.assertEntity(kind: entity.kind, name: entity.name, attributes: entity.attributes, summary: entity.summary, scope: entity.scope, status: .asserted, provenance: Provenance(sourceType: .userEdit, note: "Added in Memory view"))
            return .entity(created)
        case .upsertPreference(let pref):
            if try await store.preference(pref.id) != nil {
                return .preference(try await memory.editPreference(pref))
            }
            return .preference(try await memory.addPreference(text: pref.text, scope: pref.scope, provenance: Provenance(sourceType: .userEdit, note: "Added in Memory view")))
        case .forgetEntity(let id):
            // Not a fact (a standing instruction's id, say): say so, so `pennant memory forget` tries the instruction.
            guard try await store.entity(id) != nil else { return .error(code: "not_found", message: "No fact with that id") }
            try await memory.forgetEntity(id)
            return .ok
        case .forgetPreference(let id):
            try await memory.forgetPreference(id)
            return .ok
        case .getArtifact(let id):
            guard let record = try await store.artifact(id), let data = try await store.artifactData(id) else { return .error(code: "not_found", message: "Artifact not found") }
            return .artifact(record, base64: data.base64EncodedString())

        // Skills
        case .listSkills:
            return .skills(try await store.listSkills(includeDisabled: true))
        case .updateSkill(var skill):
            skill.updatedAt = Date()
            try await store.upsertSkill(skill)
            await publish(.skillUpserted(skill))
            return .skill(skill)
        case .setSkillStatus(let id, let status):
            guard try await store.skill(id) != nil else { return .error(code: "not_found", message: "Skill not found") }
            return .skill(try await setSkillStatus(id, status))
        case .deleteSkill(let id):
            if let skill = try await store.skill(id), skill.origin == "builtin" { return .error(code: "builtin", message: "Built-in skills can be disabled but not deleted") }
            try await store.deleteSkill(id)
            await publish(.skillRemoved(id))
            return .ok
        case .importSkills(let path, let only):
            let root: String
            do { root = try await resolveSkillSource(path) } catch { return .error(code: "git", message: String(describing: error)) }
            let result = await SkillImporter.importAll(path: root, only: only, store: store, eventBus: eventBus, workingDirectory: config.workingDirectory)
            return .importedSkills(result.skills, warnings: result.warnings)
        case .previewSkillImport(let path):
            let root: String
            do { root = try await resolveSkillSource(path) } catch { return .error(code: "git", message: String(describing: error)) }
            return .skillPreview(await SkillImporter.preview(path: root, store: store, workingDirectory: config.workingDirectory))
        case .deleteSkills(let ids):
            var refused: [String] = []
            for id in ids {
                guard let skill = try await store.skill(id) else { continue }
                if skill.origin == "builtin" { refused.append(skill.name); continue }
                try await store.deleteSkill(id)
                await publish(.skillRemoved(id))
            }
            if !refused.isEmpty { await publish(.notice(level: .warning, agentID: nil, text: "Built-in skills can be disabled but not deleted: \(refused.joined(separator: ", "))")) }
            return .ok
        case .addSkillFolder(let path):
            let resolved = PathResolver.resolve(path, base: config.workingDirectory)
            var folders = await SkillImporter.customFolders(store: store)
            if !folders.contains(resolved) { folders.append(resolved); try await SkillImporter.setCustomFolders(folders, store: store) }
            return .skillLocations(await SkillImporter.locations(store: store, workingDirectory: config.workingDirectory))
        case .removeSkillFolder(let path):
            let resolved = PathResolver.resolve(path, base: config.workingDirectory)
            let folders = await SkillImporter.customFolders(store: store).filter { $0 != resolved && $0 != path }
            try await SkillImporter.setCustomFolders(folders, store: store)
            var repos = await SkillImporter.repos(store: store)
            if repos.removeValue(forKey: resolved) != nil || repos.removeValue(forKey: path) != nil { try await SkillImporter.setRepos(repos, store: store) }
            return .skillLocations(await SkillImporter.locations(store: store, workingDirectory: config.workingDirectory))
        case .scanSkillLocations:
            return .skillLocations(await SkillImporter.locations(store: store, workingDirectory: config.workingDirectory))

        case .listReports:
            return .reports(try await runtime.reports())
        case .listPendingApprovals:
            return .pendingApprovals(try await runtime.pendingApprovals())
        case .setReviewsGitHubApp(let clientID, let secret):
            guard client.isOwner else { return Self.ownerOnly }
            try await reviews.configure(clientID: clientID, secret: secret)
            return .ok
        case .runTool(let name, let arguments):
            guard client.isOwner else { return .error(code: "owner_only", message: "Only the host's owner can run tools by hand.") }
            guard let tool = await broker.tool(named: name) else { return .error(code: "not_found", message: "No tool named \(name)") }
            let chat = try await runtime.ensureMainChat()
            // One console "task" for all of the owner's hand-run tools, so a screenshot's coordinates carry to the next call.
            let context = ToolContext(agentID: chat.agentID, taskID: Self.consoleTask, conversationID: chat.id, store: store, desktop: desktop, lease: lease, config: config)
            let result = try await tool.invoke(arguments, context: context)
            var text = result.textContent
            for case .image(let ref) in result.content { text += "\n[image: artifact \(ref.artifactID.rawValue)]" }
            return .coderToolResult(text: text, isError: result.isError)
        case .chromeStatus:
            return .chromeStatus(await chromeStatus())
        case .chromeForgetSite(let site):
            guard client.isOwner else { return .error(code: "owner_only", message: "Only the host's owner can change which sites Pennant may use.") }
            await chromeSites.remove(site)
            return .chromeStatus(await chromeStatus())
        case .chromeSetup(let browser):
            guard client.isOwner else { return .error(code: "owner_only", message: "Only the host's owner can add Pennant to Chrome.") }
            guard let folder = await chrome.installed?.folder else {
                return .error(code: "unavailable", message: "This host has no copy of Pennant's Chrome extension to add.")
            }
            let link = chrome, cursor = desktop
            let setup = ChromeSetup(bundleID: browser ?? "com.google.Chrome", folder: folder,
                                    showCursor: { point, click in await cursor.showCursor(x: point.x, y: point.y, click: click) },
                                    pressKey: { chord in try await cursor.pressKey(chord) },
                                    isConnected: { await link.currentStatus().connected })
            do { try await setup.run() } catch { return .error(code: "chrome_setup", message: String(describing: error)) }
            return .chromeStatus(await chromeStatus())
        case .coderTool(let taskID, let name, let arguments):
            let r = try await runtime.coderTool(taskID: taskID, name: name, arguments: arguments)
            return .coderToolResult(text: r.text, isError: r.isError)
        case .coderPermission(let taskID, let tool, let input):
            let d = try await runtime.coderPermission(taskID: taskID, tool: tool, input: input)
            return .coderDecision(allow: d.allow, input: d.input, message: d.message, mode: d.mode)
        case .setConversationFolder(let id, let path):
            guard var c = try await store.conversation(id) else { return .error(code: "not_found", message: "No such conversation") }
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else { return .error(code: "not_found", message: "\(path) isn't a folder on this Mac") }
            // A new folder is a new project: the CLI's session belongs to the old one.
            if c.workingDirectory != expanded { c.engineSessionID = nil }
            c.workingDirectory = expanded
            try await store.upsertConversation(c)
            await eventBus.publish(HostEvent(seq: 0, payload: .conversationUpserted(c)))
            return .ok
        case .listProjects:
            return .projects(projectFolders())
        case .checkGitHubApp(let identity):
            do { _ = try await Self.gitHubEnvironment(for: identity, vault: vault) } catch {
                throw HostCommandError.invalid("Couldn't act as \(identity.botLogin): \(error)")
            }
            return .ok
        case .setConversationCoding(let id, let mode, let model):
            guard var c = try await store.conversation(id) else { return .error(code: "not_found", message: "No such conversation") }
            c.engineMode = mode
            c.engineModel = model?.nilIfEmpty
            try await store.upsertConversation(c)
            await eventBus.publish(HostEvent(seq: 0, payload: .conversationUpserted(c)))
            return .ok
        case .answerChoices(let taskID, let questionID, let answers):
            try await runtime.answerChoices(taskID: taskID, questionID: questionID, answers: answers, by: Self.author(of: client))
            return .ok
        case .decideApproval(let decision):
            try await runtime.decideApproval(decision, by: Self.author(of: client))
            return .ok

        case .uploadAttachment(let fileName, let mimeType, let base64):
            return .attachment(try await storeUpload(fileName: fileName, mimeType: mimeType, base64: base64))

        case .inspectPrompt(let agentID):
            return .promptInspection(try await runtime.inspectPrompt(agentID))

        // Library
        case .listLibrary:
            return .library(await library.index())
        case .uploadLibraryAsset(let collection, let fileName, let mimeType, let base64, let name, let notes):
            guard let data = Data(base64Encoded: base64) else { throw HostCommandError.invalid("The file could not be read.") }
            return .library(try await library.upload(collection: collection, fileName: fileName, mimeType: mimeType, data: data, name: name, notes: notes))
        case .updateLibraryAsset(let asset):
            return .library(try await library.update(asset))
        case .deleteLibraryAsset(let id):
            return .library(try await library.delete(id: id))
        case .saveLibraryCollection(let collection):
            return .library(try await library.saveCollection(collection))
        case .deleteLibraryCollection(let name):
            return .library(try await library.deleteCollection(name))
        case .libraryPreview(let id):
            return .libraryPreview(id: id, base64: try await library.preview(id: id).base64EncodedString())

        // Vault
        case .listVault:
            return .vault(await vault.items())
        case .saveVaultItem(let item, let secret):
            let items = try await vault.save(item, secret: secret)
            log.info("Vault entry saved: \(item.name)", category: "vault")
            return .vault(items)
        case .deleteVaultItem(let id):
            let name = await vault.items().first { $0.id == id }?.name ?? id
            let items = try await vault.delete(id: id)
            log.info("Vault entry deleted: \(name)", category: "vault")
            return .vault(items)
        case .usageReport(let from, let to):
            return .usage(try await usageReport(from: from, to: to))
        case .exportData(let folder, let passphrase):
            let parent = folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
            return .exported(try await PennantTransfer.export(store: store, paths: paths, into: parent, passphrase: passphrase))
        case .importData(let folder, let passphrase):
            try PennantTransfer.stage(from: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true), passphrase: passphrase, paths: paths)
            await publish(.notice(level: .info, agentID: nil, text: "Importing: Pennant restarts to swap in the export. This Mac's previous data is kept alongside."))
            let restart = restartHandler
            Task { try? await Task.sleep(for: .seconds(1)); await restart() }
            return .ok
        case .testModel(let inference):
            return .modelTest(await testModel(inference))
        case .azureStatus:
            return .azureStatus(await AzureCLI.status())
        case .azureLogin:
            return .azureStatus(try await AzureCLI.login())
        case .azureSubscriptions:
            return .azureSubscriptions(try await AzureCLI.subscriptions())
        case .azureResources(let subscription):
            return .azureResources(try await AzureCLI.resources(subscription: subscription))
        case .azureDeployments(let subscription, let group, let resource):
            return .azureDeployments(try await AzureCLI.deployments(subscription: subscription, resourceGroup: group, resource: resource))
        case .listChromeProfiles:
            return .chromeProfiles(ChromeSignIns.profiles())
        case .listChromeSites(let profile):
            return .chromeSites(try ChromeSignIns.sites(profile: profile))
        case .importChromeSignIns(let profile, let sites):
            let result = try await ChromeSignIns.importInto(browserRunner, profile: profile, sites: sites)
            let info = ChromeSignIns.profiles().first { $0.id == profile }
            _ = try await vault.recordSignIns(result, profileName: info?.name ?? profile, account: info?.account)
            log.info("Imported \(result.cookies) cookie(s) from Chrome \(profile) for \(sites.joined(separator: ", "))", category: "vault")
            return .chromeImport(result)
        case .listBrowserSignIns:
            return .browserSignIns(await vault.browserSignIns())
        case .removeBrowserSignIn(let site):
            try await ChromeSignIns.remove(site: site, from: browserRunner)
            log.info("Removed the \(site) sign-in from Pennant's browser", category: "vault")
            return .browserSignIns(try await vault.forgetSignIn(site))

        // Teach mode
        case .startTeaching(let goal):
            let session = await teaching.start(goal: goal)
            log.info("Teaching started: \(session.goal)", category: "teaching")
            return .teaching(session)
        case .stopTeaching:
            let session = await teaching.stop()
            log.info("Teaching stopped with \(session?.events.count ?? 0) step(s)", category: "teaching")
            return .teaching(session)
        case .cancelTeaching:
            await teaching.cancel()
            return .teaching(nil)
        case .addTeachingNote(let text):
            return .teaching(await teaching.addNote(text))
        case .removeTeachingEvents(let ids):
            return .teaching(await teaching.removeEvents(ids))
        case .getTeaching:
            return .teaching(await teaching.current)
        case .draftSkillFromTeaching(let goal):
            return .skill(try await draftTaughtSkill(goal: goal))

        // Scheduled jobs
        case .listSchedules:
            return .schedules(try await scheduler.list())
        case .upsertSchedule(let job):
            // A goal's job edited in Schedules: the goal takes the new time (and on/off), and its jobs follow it.
            if let goalID = job.goalID, var goal = try await store.goal(goalID) {
                if job.goalRun == "review" { goal.reviewSchedule = job.schedule } else { goal.workSchedule = job.schedule }
                if !job.enabled, goal.status == .active { goal.status = .paused } else if job.enabled, goal.status == .paused { goal.status = .active }
                goal.skillID = job.skillID  // pinning a skill on either job pins it for the goal
                _ = try await goals.save(goal)
                return .schedule(try await store.schedule(job.id) ?? job)
            }
            return .schedule(try await scheduler.upsert(job))
        case .deleteSchedule(let id):
            if let job = try await store.schedule(id), job.goalID != nil {
                return .error(code: "goal_job", message: "This job belongs to a goal. Pause or drop the goal instead (Goals).")
            }
            try await scheduler.delete(id)
            return .ok
        case .runScheduleNow(let id):
            return .schedule(try await scheduler.runNow(id))

        // Goals
        case .listGoals:
            return .goals(try await goals.list())
        case .upsertGoal(let goal):
            guard client.isOwner else { return Self.ownerOnly }
            return .goal(try await goals.save(goal))
        case .setGoalStatus(let id, let status):
            guard client.isOwner else { return Self.ownerOnly }
            return .goal(try await goals.setStatus(id, status))
        case .deleteGoal(let id):
            guard client.isOwner else { return Self.ownerOnly }
            try await goals.delete(id)
            return .ok
        case .listGoalItems(let id):
            return .goalItems(try await goals.items(id))
        case .upsertGoalItem(let item):
            guard client.isOwner else { return Self.ownerOnly }
            return .goalItem(try await goals.saveItem(item))
        case .commentGoalItem(let id, let text):
            return .goalItem(try await goals.comment(id, text: text, by: "owner"))
        case .previewSchedule(let expression, let timeZone, let count):
            let (dates, error) = Scheduler.preview(expression: expression, timeZone: timeZone, count: count)
            return .schedulePreview(dates, error: error)

        // MCP
        case .listMCPServers:
            return .mcpServers(await mcp.allStatuses())
        case .addMCPServer(let cfg):
            try await mcp.add(cfg)
            return .mcpServers(await mcp.allStatuses())
        case .removeMCPServer(let id):
            try await mcp.remove(id)
            return .mcpServers(await mcp.allStatuses())
        case .reconnectMCPServer(let id):
            await mcp.reconnect(id)
            return .mcpServers(await mcp.allStatuses())
        case .beginMCPAuth(let id):
            let url = try await mcp.beginAuth(id)
            return .mcpAuthStarted(serverID: id, url: url.absoluteString)
        case .cancelMCPAuth(let id):
            await mcp.cancelAuth(id)
            return .mcpServers(await mcp.allStatuses())
        case .setMCPCredential(let id, let secret):
            try await mcp.setCredential(id, secret: secret)
            return .mcpServers(await mcp.allStatuses())
        case .signOutMCP(let id):
            try await mcp.signOut(id)
            return .mcpServers(await mcp.allStatuses())
        case .listMCPCatalog:
            return .mcpCatalog(MCPCatalog.entries)
        case .beginChatGPTSignIn:
            return .chatGPTSignInStarted(url: try await chatGPT.beginSignIn().absoluteString)
        case .importCodexLogin:
            return .chatGPTAccount(try await chatGPT.importCodexLogin())
        case .signOutChatGPT:
            return .chatGPTAccount(try await chatGPT.signOut())
        case .getChatGPTAccount:
            return .chatGPTAccount(await chatGPT.account())
        case .listChatGPTModels:
            let (models, note) = await chatGPT.availableModels()
            return .chatGPTModels(models, note: note)

        // Diagnostics and settings
        case .getDiagnostics:
            let report = DiagnosticsReport(host: await hostInfo(), databasePath: paths.databaseURL.path, artifactDirectory: paths.artifactsURL.path, configPath: paths.configURL.path, logPath: paths.logURL.path, eventCount: try await store.eventCount(), toolSpecs: await broker.allSpecs, recentToolRecords: try await store.recentToolRecords(limit: 50), memory: try await store.memoryOverview())
            return .diagnostics(report)
        case .getConfig:
            return .config(config, restartRequired: false)
        case .updateConfig(var newConfig):
            newConfig.reconcileModels(previous: config)
            let inferenceChanged = newConfig.inference != config.inference
            let restart = newConfig.api != config.api || newConfig.embeddings != config.embeddings || newConfig.mode != config.mode
            config = newConfig
            try ConfigLoader.save(newConfig, to: paths.configURL)
            await runtime.updateConfig(newConfig)
            await heartbeat.update(newConfig.heartbeat)
            await lease.setPauseOnHumanInput(newConfig.desktop.pauseOnHumanInput)
            if inferenceChanged {
                switchableProvider.replace(Self.makeProvider(newConfig.inference, chatGPT: chatGPT, vault: vault))
                let ok = await provider.healthCheck()
                await updateInference(reachable: ok)
                let where_ = await inferenceEndpointLabel()
                if newConfig.inference.provider == HostConfig.Inference.chatGPTProvider {
                    await publish(.notice(level: ok ? .info : .warning, agentID: nil, text: ok ? "Now using \(newConfig.inference.model) through your ChatGPT account (\(where_))." : "Saved. Sign in to a ChatGPT account (Settings › Host) to use \(newConfig.inference.model)."))
                } else {
                    await publish(.notice(level: ok ? .info : .warning, agentID: nil, text: ok ? "Now using \(newConfig.inference.model) at \(where_)." : "Saved, but \(where_) is not reachable yet."))
                }
            } else {
                await publish(.notice(level: .info, agentID: nil, text: restart ? "Settings saved. Restart the host to apply network or mode changes." : "Settings saved."))
            }
            return .config(config, restartRequired: restart)
        case .requestPermissions(let targets):
            _ = await desktop.requestPermissions(targets: targets)
            let status = await desktopStatus(freshPermissions: true)
            await eventBus.publish(HostEvent(seq: 0, payload: .desktopStatus(status)))
            return .desktop(status)
        case .resetPermission(let target):
            let ok = await PermissionCheck.reset(target: target)
            await publish(.notice(level: ok ? .info : .warning, agentID: nil, text: ok ? "Cleared the \(PermissionCheck.tccService(for: target)) entry for \(PermissionCheck.hostDisplayName); request it again." : "Could not reset \(PermissionCheck.tccService(for: target))."))
            let status = await desktopStatus(freshPermissions: true)
            await eventBus.publish(HostEvent(seq: 0, payload: .desktopStatus(status)))
            return .desktop(status)
        case .recheckPermissions:
            let status = await desktopStatus(freshPermissions: true)
            await eventBus.publish(HostEvent(seq: 0, payload: .desktopStatus(status)))
            return .desktop(status)
        case .listModels(let baseURL, let apiKey, let apiKeyVault):
            var key = apiKey
            if let entry = apiKeyVault?.nilIfEmpty { key = try await VaultKeyAuthority.key(entry, in: vault) }
            return .models(try await ModelDiscovery.listModels(baseURL: baseURL, apiKey: key))
        }
    }

    private func applyRemoteInput(_ input: RemoteInput) async throws {
        let size = await desktop.displaySize()
        func px(_ x: Double, _ y: Double) -> (Double, Double) { (x * Double(size.width), y * Double(size.height)) }
        switch input {
        case .pointerMove(let x, let y), .pointerDown(let x, let y, _), .pointerUp(let x, let y, _), .click(let x, let y, _, _):
            let p = px(x, y)
            try await desktop.livePointer(input, x: p.0, y: p.1)
        case .scroll(let x, let y, let dx, let dy): let p = px(x, y); try await desktop.scroll(x: p.0, y: p.1, deltaX: dx, deltaY: dy)
        case .typeText(let text): try await desktop.typeText(text)
        case .key(let chord): try await desktop.pressKey(chord)
        }
    }
}

/// A command the host cannot carry out as asked; the message is written for the user.
enum HostCommandError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let message): return message }
    }
}
