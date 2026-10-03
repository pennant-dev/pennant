import PennantCore
import Foundation

/// Who may connect and what they see: tokens, signing in (providers, passwords, invites, Cloudflare Access),
/// the state snapshot, and the screen stream.
extension HostService {
    // MARK: HostAPIDelegate

    public func authenticate(token: String?) async -> Bool {
        guard let token, !token.isEmpty else { return false }
        switch await devices.owner(of: token) {
        case .owner?: return true
        case .person(let id)?:
            // A signed-in teammate who was removed or disabled no longer gets in.
            guard let person = await people.person(id), !person.disabled else { return false }
            return true
        case nil: break
        }
        return await devices.localToken() == token
    }

    // MARK: People and sign-in

    public func signInOptions() async -> [SignInProvider] { await people.signInSettings.configured }

    public func beginSignIn(provider: SignInProvider, redirectURI: String, trusted: Bool) async throws -> SignInStart {
        try await people.begin(provider, redirectURI: redirectURI, trusted: trusted)
    }

    public func completeSignIn(state: String, code: String?, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn {
        let person = try await people.complete(state: state, code: code, trusted: trusted)
        let token = await devices.mintToken(clientID: clientID, clientName: clientName, platform: platform, personID: person.id)
        await publish(.notice(level: .info, agentID: nil, text: "\(person.name) signed in on \(clientName) (\(platform))."))
        return SignedIn(token: token, person: person, hostName: Self.displayName)
    }


    public func signInWithPassword(email: String, password: String, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn {
        let person = try await people.signIn(email: email, password: password, trusted: trusted)
        return await signedIn(person, clientID: clientID, clientName: clientName, platform: platform)
    }

    public func redeemInvite(code: String, name: String, password: String, clientID: ClientID, clientName: String, platform: String, trusted: Bool) async throws -> SignedIn {
        let person = try await people.redeem(code: code, name: name, password: password, trusted: trusted)
        await publish(.notice(level: .info, agentID: nil, text: "\(person.name) (\(person.email)) joined with an invite code."))
        return await signedIn(person, clientID: clientID, clientName: clientName, platform: platform)
    }

    func signedIn(_ person: Person, clientID: ClientID, clientName: String, platform: String) async -> SignedIn {
        let token = await devices.mintToken(clientID: clientID, clientName: clientName, platform: platform, personID: person.id)
        await publish(.notice(level: .info, agentID: nil, text: "\(person.name) signed in on \(clientName) (\(platform))."))
        return SignedIn(token: token, person: person, hostName: Self.displayName)
    }

    /// Who "me" is for account changes: the signed-in person, or on the owner's own clients the owner's account
    /// (made on first use).
    func me(_ client: ConnectedClient) async throws -> Person {
        if let p = client.person, let current = await people.person(p.id) { return current }
        guard client.isOwner else { throw PeopleService.SignInError.unknownState }
        return try await people.ownerAccount(defaultName: NSFullUserName())
    }

    // MARK: Cloudflare Access

    /// The Pennant account a verified Cloudflare Access token belongs to: the one with its email.
    public func edgePerson(accessToken: String?) async throws -> Person {
        guard let edge = config.api.edge else { throw EdgeError("Cloudflare access isn't set up on this host.") }
        let email = try await accessVerifier.verify(accessToken, edge: edge)
        guard let person = await people.snapshot().people.first(where: { $0.email.lowercased() == email }) else {
            throw EdgeError("There's no Pennant account for \(email). Ask the owner to add you (Settings › People).")
        }
        await people.touch(person.id)
        return person
    }

    struct EdgeError: Error, CustomStringConvertible { var description: String; init(_ d: String) { description = d } }

    /// The sign-in handoff for apps, behind Access on the edge's HTTP port: Access has signed the person in (Entra),
    /// and the request arrives with their token; it goes back to the app on its own URL scheme. Only pennant:// targets.
    func startEdgeHandoff() async {
        guard let edge = config.api.edge else { return }
        do {
            try await edgeHTTP.start(port: UInt16(clamping: edge.httpPort)) { [weak self] request in
                await self?.edgeRequest(request) ?? .notFound
            }
            log.info("Cloudflare sign-in handoff on 127.0.0.1:\(edge.httpPort)", category: "api")
        } catch {
            log.error("Cloudflare handoff port \(edge.httpPort) didn't start: \(error)", category: "api")
        }
    }

    func edgeRequest(_ request: WebhookServer.Request) async -> WebhookServer.Response {
        let token = request.header("cf-access-jwt-assertion")
        func page(_ status: Int, _ text: String) -> WebhookServer.Response {
            let html = "<!doctype html><meta name=viewport content='width=device-width'><title>Pennant</title><body style='font:17px -apple-system,sans-serif;padding:40px;max-width:32em;line-height:1.5'><h2>Pennant</h2><p>\(text)</p>"
            return WebhookServer.Response(status: status, body: Data(html.utf8), headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"])
        }
        // A browser at the address: say what this is and who Access signed in.
        if request.method == "GET", request.path == "/" {
            let who = try? await edgePerson(accessToken: token)
            let hostName = config.api.edge?.hostname ?? "this address"
            return page(200, who.map { "This is \(Self.displayName)'s Pennant host, and you're signed in as <b>\($0.name)</b>.<br><br>To use it, open Pennant on your iPhone or Mac and choose <b>Sign in with Microsoft</b> with the address <b>\(hostName)</b>." }
                        ?? "This is a Pennant host. Your work account got you this far, but there's no Pennant account for it yet: ask the owner to add you.")
        }
        guard request.method == "GET", request.path == "/access/handoff" else { return .notFound }
        let person: Person
        do { person = try await edgePerson(accessToken: token) } catch { return page(403, "\(error)") }
        let target = request.parameter("return") ?? "pennant://access"
        guard target.hasPrefix("pennant://"), var components = URLComponents(string: target), let token else { return page(400, "Unknown app.") }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token), URLQueryItem(name: "name", value: person.name)]
        guard let url = components.url?.absoluteString else { return page(400, "Unknown app.") }
        return WebhookServer.Response(status: 302, headers: ["Location": url, "Cache-Control": "no-store"])
    }

    public func person(forToken token: String?) async -> Person? {
        guard let token else { return nil }
        switch await devices.owner(of: token) {
        case .person(let id)?:
            await people.touch(id)
            return await people.person(id)
        case .owner?:
            return await ownerPerson()
        case nil:
            return nil
        }
    }

    /// Who the Mac's own apps and devices from before accounts act as: the owner who signed in with a provider (so
    /// their messages match their phone's), else the Mac's user.
    func ownerPerson() async -> Person {
        await people.snapshot().people.first { $0.role == .owner } ?? Person.owner(name: NSFullUserName())
    }

    // MARK: Clients

    public func snapshot() async -> StateSnapshot {
        let agents = (try? await store.listAgents(includeRetired: false)) ?? []
        var tasks = (try? await store.listTasks(agentID: nil, includeFinished: true)) ?? []
        let unfinished = tasks.filter { !$0.state.isTerminal }
        let finished = tasks.filter { $0.state.isTerminal }.sorted { $0.updatedAt > $1.updatedAt }.prefix(40)
        tasks = unfinished + finished
        var conversations: [Conversation] = []
        for a in agents { conversations += (try? await store.listConversations(agentID: a.id)) ?? [] }
        conversations = Array(conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(300))
        return StateSnapshot(host: await hostInfo(), agents: agents, tasks: tasks, conversations: conversations, desktop: await desktopStatus(), mcpServers: await mcp.allStatuses(), latestEventSeq: (try? await store.latestEventSeq()) ?? 0, schedules: (try? await store.listSchedules()) ?? [], goals: (try? await store.listGoals()) ?? [])
    }

    public func screenFrames(options: ScreenStreamOptions) async -> AsyncStream<(ScreenFrameHeader, Data)> {
        let source = desktop.screenStream(options: options)
        let lease = self.lease
        let (stream, continuation) = AsyncStream<(ScreenFrameHeader, Data)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var seq: Int64 = 0
            for await frame in source {
                if Task.isCancelled { break }
                seq += 1
                let header = ScreenFrameHeader(sequence: seq, width: frame.width, height: frame.height, timestamp: frame.capturedAt, cursorX: frame.cursorX.map { $0 / Double(max(frame.displayWidth, 1)) }, cursorY: frame.cursorY.map { $0 / Double(max(frame.displayHeight, 1)) }, owner: await lease.owner, region: frame.region)
                continuation.yield((header, frame.jpeg))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func clientsChanged(_ clients: [ConnectedClient], streaming: Int) async {
        self.clients = clients
        self.streamingClients = streaming
        await publishHostStatus()
    }
}
