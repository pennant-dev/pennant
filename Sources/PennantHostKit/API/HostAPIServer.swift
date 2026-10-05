import PennantCore
import Foundation
import Network

/// WebSocket API for Mac and iPhone clients, built on Network.framework.
/// Text frames carry `WireMessage` JSON in both directions; binary frames carry screen frames
/// encoded with `ScreenFrameCodec`, and speech for Talk mode encoded with `SpeechChunkCodec`. The first command on a connection must be `hello` or `pair`.
public actor HostAPIServer {
    public static let maximumMessageSize = 32 * 1024 * 1024
    public static let helloTimeout: TimeInterval = 10

    private let config: HostConfig.API
    private let delegate: any HostAPIDelegate
    private let eventBus: EventBus
    private let store: any StoreProtocol
    private let hostName: String
    private let queue = DispatchQueue(label: "dev.pennant.host.api", qos: .userInitiated)

    private var listener: NWListener?
    /// The encrypted listener beside the plain one: the same API over TLS with the host's own certificate.
    private var tlsListener: NWListener?
    /// The Cloudflare Tunnel's way in: loopback only, every connection must carry an Access token.
    private var edgeListener: NWListener?
    private let tls: HostTLSIdentity?
    private var boundTLSPort: Int = 0
    private var connections: [UUID: ClientConnection] = [:]
    private var clientsByConnection: [UUID: ConnectedClient] = [:]
    private var streamingConnections: Set<UUID> = []
    private var boundPort: Int = 0

    public init(config: HostConfig.API, delegate: any HostAPIDelegate, eventBus: EventBus, store: any StoreProtocol, hostName: String, tls: HostTLSIdentity? = nil) {
        self.config = config
        self.tls = tls
        self.delegate = delegate
        self.eventBus = eventBus
        self.store = store
        self.hostName = hostName
        self.boundPort = config.port
    }

    /// Port the listener is bound to (resolved after `start()` when the configured port is 0).
    public var port: Int { boundPort }
    /// The encrypted port, once listening (0 without TLS).
    public var tlsPort: Int { boundTLSPort }
    public var connectedClients: [ConnectedClient] { clientsByConnection.values.sorted { $0.connectedAt < $1.connectedAt } }

    // MARK: Lifecycle

    public func start() async throws {
        guard listener == nil else { return }
        // The encrypted port first, so the plain one's Bonjour record can advertise it.
        if let tls {
            let tlsPort = config.tlsPort
            do {
                let secure = try await makeListener(port: tlsPort, tls: tls, service: nil)
                tlsListener = secure
                boundTLSPort = Int(secure.port?.rawValue ?? UInt16(clamping: tlsPort))
                log.info("API listening with TLS on port \(boundTLSPort) (certificate \(tls.fingerprint.prefix(16))…)", category: "api")
            } catch {
                log.error("Encrypted API port \(tlsPort) didn't start: \(error)", category: "api")
            }
        }
        var service: NWListener.Service?
        if config.listenOnNetwork, config.advertiseBonjour {
            var s = NWListener.Service(name: hostName, type: PennantVersion.bonjourServiceType)
            // Advertise a dialable IPv4: clients whose Bonjour probe resolves to link-local IPv6
            // (a valid display address, not a reliable connect one) fall back to this. The encrypted port and the
            // certificate's fingerprint let clients check the host they found before trusting it.
            var txt: [String: String] = [:]
            if let ipv4 = Self.advertisedIPv4() { txt["ipv4"] = ipv4 }
            if let tls, boundTLSPort > 0 { txt["tls"] = String(boundTLSPort); txt["fp"] = tls.fingerprint }
            if !txt.isEmpty { s.txtRecordObject = NWTXTRecord(txt) }
            service = s
        }
        if let edge = config.edge {
            do {
                edgeListener = try await makeListener(port: edge.port, tls: nil, service: nil, loopbackOnly: true, edge: true)
                log.info("Cloudflare edge listening on 127.0.0.1:\(edge.port) for \(edge.hostname)", category: "api")
            } catch {
                log.error("Cloudflare edge port \(edge.port) didn't start: \(error)", category: "api")
            }
        }
        let listener = try await makeListener(port: config.port, tls: nil, service: service)
        self.listener = listener
        boundPort = Int(listener.port?.rawValue ?? UInt16(clamping: config.port))
        log.info("API listening on port \(boundPort) (\(config.listenOnNetwork ? "all interfaces" : "loopback only"))\(service != nil ? ", advertising \(PennantVersion.bonjourServiceType) as \(hostName)" : "")", category: "api")
    }

    private func makeListener(port requested: Int, tls: HostTLSIdentity?, service: NWListener.Service?, loopbackOnly: Bool = false, edge: Bool = false) async throws -> NWListener {
        let params: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(tls.identity)!)
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maximumMessageSize
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let port: NWEndpoint.Port = requested == 0 ? .any : (NWEndpoint.Port(rawValue: UInt16(clamping: requested)) ?? .any)
        let listener: NWListener
        if config.listenOnNetwork, !loopbackOnly {
            listener = try NWListener(using: params, on: port)
        } else {
            // Loopback only: the required local endpoint carries the port (passing both is rejected with EINVAL).
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            listener = try NWListener(using: params)
        }
        if let service { listener.service = service }
        let encrypted = tls != nil
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection, encrypted: encrypted, edge: edge) }
        }
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.trip() { continuation.resume() }
                case .failed(let error):
                    if once.trip() { continuation.resume(throwing: error) } else if let self { Task { await self.listenerFailed(error) } }
                case .cancelled:
                    if once.trip() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }

    /// First non-loopback IPv4 (en0 preferred) for the Bonjour TXT advertisement.
    static func advertisedIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(first) }
        var best: String?
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [Int8](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "en0" { return value }
            if best == nil { best = value }
        }
        return best
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        tlsListener?.cancel()
        tlsListener = nil
        edgeListener?.cancel()
        edgeListener = nil
        let all = connections.values
        connections.removeAll()
        clientsByConnection.removeAll()
        streamingConnections.removeAll()
        for connection in all { await connection.close(reason: "server stopped") }
        await delegate.clientsChanged([], streaming: 0)
        log.info("API stopped", category: "api")
    }

    private func listenerFailed(_ error: Error) {
        log.error("API listener failed: \(error)", category: "api")
        listener = nil
    }

    private func accept(_ nwConnection: NWConnection, encrypted: Bool, edge: Bool = false) {
        let id = UUID()
        let connection = ClientConnection(id: id, connection: nwConnection, server: self, delegate: delegate, eventBus: eventBus, store: store, hostName: hostName, queue: queue, encrypted: encrypted, edge: edge)
        connections[id] = connection
        Task { await connection.start() }
    }

    // MARK: Connection bookkeeping (called by ClientConnection)

    func register(client: ConnectedClient, connectionID: UUID) async {
        clientsByConnection[connectionID] = client
        await notifyClientsChanged()
    }

    func setStreaming(_ streaming: Bool, connectionID: UUID) async {
        if streaming { streamingConnections.insert(connectionID) } else { streamingConnections.remove(connectionID) }
        await notifyClientsChanged()
    }

    func connectionClosed(_ connectionID: UUID) async {
        connections[connectionID] = nil
        let wasClient = clientsByConnection.removeValue(forKey: connectionID) != nil
        let wasStreaming = streamingConnections.remove(connectionID) != nil
        if wasClient || wasStreaming { await notifyClientsChanged() }
    }

    private func notifyClientsChanged() async {
        await delegate.clientsChanged(connectedClients, streaming: streamingConnections.count)
    }
}

// MARK: - Per-connection handler

actor ClientConnection {
    let id: UUID
    private let connection: NWConnection
    private let server: HostAPIServer
    private let delegate: any HostAPIDelegate
    private let eventBus: EventBus
    private let store: any StoreProtocol
    private let hostName: String
    private let queue: DispatchQueue

    private var client: ConnectedClient?
    private var authenticated = false
    private var closed = false
    private var isLoopback = false
    /// Loopback, Tailscale, or encrypted: where sign-in is accepted from by default (nothing crosses a network in
    /// the clear there).
    private var onTailnet = false
    /// Came in on the TLS port.
    private let encrypted: Bool
    /// Came through the Cloudflare Tunnel: it looks like loopback but isn't; the hello's Access token says who it is.
    private let edge: Bool
    private var remoteDescription = "?"

    private var receiveTask: Task<Void, Never>?
    private var helloTimeoutTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    /// Which stream `screenTask` is. A replaced stream finishes after its successor started and must leave it alone.
    private var screenStreamID = 0
    private var commandTasks: [CommandID: Task<Void, Never>] = [:]
    /// The owner's live input from this client, applied strictly in the order it came (other commands run side by side).
    private var inputTail: Task<Void, Never>?
    /// The last frame the client confirmed, and a stream waiting for a confirmation (`acknowledges`).
    private var screenAcked: Int64 = 0
    private var framesSent: Int64 = 0
    private var ackWaiter: (sequence: Int64, continuation: CheckedContinuation<Void, Never>)?
    /// Speech for this client, sent in the order it was made.
    private var speech: AsyncStream<Data>.Continuation?
    private var speechTask: Task<Void, Never>?

    init(id: UUID, connection: NWConnection, server: HostAPIServer, delegate: any HostAPIDelegate, eventBus: EventBus, store: any StoreProtocol, hostName: String, queue: DispatchQueue, encrypted: Bool = false, edge: Bool = false) {
        self.id = id
        self.encrypted = encrypted
        self.edge = edge
        self.connection = connection
        self.server = server
        self.delegate = delegate
        self.eventBus = eventBus
        self.store = store
        self.hostName = hostName
        self.queue = queue
    }

    // MARK: Lifecycle

    func start() async {
        let once = OnceFlag()
        let ready: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.trip() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if once.trip() { continuation.resume(returning: false) } else if let self { Task { await self.close(reason: "connection \(state)") } }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        guard ready else {
            await close(reason: "failed before ready")
            return
        }
        let remote = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        // Tunnel traffic arrives from cloudflared on this Mac; it's a remote client behind Cloudflare Access, not this Mac.
        isLoopback = !edge && Self.isLoopback(remote)
        onTailnet = isLoopback || encrypted || edge || PeopleService.isTailscale(remote)
        remoteDescription = edge ? "Cloudflare Access" : "\(remote)\(encrypted ? " (TLS)" : "")"
        log.info("Connection from \(remoteDescription)", category: "api")

        helloTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HostAPIServer.helloTimeout))
            guard let self, !Task.isCancelled else { return }
            if await !self.authenticated { await self.close(reason: "hello timeout") }
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func close(reason: String) async {
        guard !closed else { return }
        closed = true
        helloTimeoutTask?.cancel()
        eventTask?.cancel()
        screenTask?.cancel()
        speech?.finish()
        speechTask?.cancel()
        if authenticated {
            let id = self.id
            let delegate = self.delegate
            Task { await delegate.stopSpeaking(connection: id) }
        }
        for task in commandTasks.values { task.cancel() }
        commandTasks.removeAll()
        inputTail?.cancel()
        releaseAckWaiter()
        receiveTask?.cancel()
        connection.cancel()
        log.info("Connection \(remoteDescription) closed: \(reason)", category: "api")
        await server.connectionClosed(id)
    }

    // MARK: Receiving

    private func receiveLoop() async {
        while !closed, !Task.isCancelled {
            let received: (Data?, NWProtocolWebSocket.Opcode?)
            do {
                received = try await receiveOne()
            } catch {
                await close(reason: "receive error: \(error)")
                return
            }
            let (data, opcode) = received
            switch opcode {
            case .close:
                await close(reason: "peer closed")
                return
            case .ping, .pong:
                continue
            case .text, .binary:
                guard let data, !data.isEmpty else { continue }
                await handleFrame(data)
            default:
                if data == nil {
                    await close(reason: "end of stream")
                    return
                }
            }
        }
    }

    private func receiveOne() async throws -> (Data?, NWProtocolWebSocket.Opcode?) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, NWProtocolWebSocket.Opcode?), Error>) in
            connection.receiveMessage { content, context, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if content == nil, metadata == nil, isComplete {
                    continuation.resume(returning: (nil, nil))
                    return
                }
                continuation.resume(returning: (content, metadata?.opcode))
            }
        }
    }

    private func handleFrame(_ data: Data) async {
        let message: WireMessage
        do {
            message = try WireMessage.decode(data)
        } catch {
            log.warn("Malformed frame from \(remoteDescription): \(error)", category: "api")
            if !authenticated { await close(reason: "malformed frame before hello") }
            return
        }
        guard case .command(let command) = message else { return }
        await dispatch(command)
    }

    // MARK: Dispatch

    private func dispatch(_ command: ClientCommand) async {
        switch command.body {
        case .signInOptions:
            await reply(command.id, .signInOptions(await delegate.signInOptions(), hostName: hostName))

        case .signInWithPassword(let email, let password, let clientID, let clientName, let platform):
            do {
                await reply(command.id, .signedIn(try await delegate.signInWithPassword(email: email, password: password, clientID: clientID, clientName: clientName, platform: platform, trusted: onTailnet)))
            } catch {
                await reply(command.id, Self.signInError(error))
            }

        case .redeemInvite(let code, let name, let password, let clientID, let clientName, let platform):
            do {
                await reply(command.id, .signedIn(try await delegate.redeemInvite(code: code, name: name, password: password, clientID: clientID, clientName: clientName, platform: platform, trusted: onTailnet)))
            } catch {
                await reply(command.id, Self.signInError(error))
            }

        case .beginSignIn(let provider, let redirectURI):
            extendSignInWindow()
            do {
                await reply(command.id, .signInStarted(try await delegate.beginSignIn(provider: provider, redirectURI: redirectURI, trusted: onTailnet)))
            } catch {
                await reply(command.id, Self.signInError(error))
            }

        case .completeSignIn(let state, let code, let clientID, let clientName, let platform):
            extendSignInWindow()
            // GitHub's device code is polled for minutes; don't hold up the connection's other frames.
            let trusted = onTailnet
            let id = command.id
            Task { [weak self] in
                guard let self else { return }
                do {
                    let signedIn = try await self.delegate.completeSignIn(state: state, code: code, clientID: clientID, clientName: clientName, platform: platform, trusted: trusted)
                    await self.reply(id, .signedIn(signedIn))
                } catch {
                    await self.reply(id, Self.signInError(error))
                }
            }

        case .hello(let hello):
            guard hello.protocolVersion == pennantProtocolVersion else {
                await reply(command.id, .error(code: "unsupported_version", message: "Host speaks protocol \(pennantProtocolVersion), client sent \(hello.protocolVersion)"))
                await close(reason: "unsupported protocol version")
                return
            }
            let person: Person?
            if edge {
                // Through Cloudflare: the Access token is the sign-in; Pennant tokens aren't accepted here.
                do { person = try await delegate.edgePerson(accessToken: hello.accessToken) } catch {
                    await reply(command.id, .error(code: "access_denied", message: "\(error)"))
                    await close(reason: "Cloudflare Access: \(error)")
                    return
                }
            } else {
                guard await delegate.authenticate(token: hello.token) else {
                    await reply(command.id, .error(code: "unauthenticated", message: "Invalid token. Sign in to this host again."))
                    await close(reason: "authentication failed")
                    return
                }
                person = await delegate.person(forToken: hello.token)
            }
            helloTimeoutTask?.cancel()
            authenticated = true
            let connected = ConnectedClient(id: hello.clientID, displayName: hello.displayName, platform: hello.platform, person: person, isLocal: isLoopback)
            client = connected
            var snapshot = await delegate.snapshot()
            snapshot.me = person
            await reply(command.id, .welcome(snapshot))
            startEventForwarding()
            await server.register(client: connected, connectionID: id)
            log.info("Client \(connected.displayName) (\(connected.platform)) authenticated from \(remoteDescription), lastEventSeq \(hello.lastEventSeq)", category: "api")

        case .ping:
            await reply(command.id, .ok)

        default:
            guard authenticated, let client else {
                await reply(command.id, .error(code: "unauthenticated", message: "Send hello first"))
                await close(reason: "command before hello")
                return
            }
            switch command.body {
            case .listEvents(let afterSeq, let limit):
                let capped = max(1, min(limit, 1000))
                do {
                    let events = try await store.events(afterSeq: afterSeq, limit: capped)
                    await reply(command.id, .events(events))
                } catch {
                    await reply(command.id, .error(code: "store_error", message: "\(error)"))
                }

            case .subscribeScreen(let options):
                startScreenStream(options: options)
                await reply(command.id, .ok)

            case .unsubscribeScreen:
                await stopScreenStream()
                await reply(command.id, .ok)

            case .screenFrameReceived(let sequence):
                acknowledged(upTo: sequence)

            case .speak(let request):
                let outlet = speechOutlet()
                do {
                    try await delegate.speak(request, connection: id) { header, samples in
                        guard let frame = try? SpeechChunkCodec.encode(header: header, samples: samples) else { return }
                        outlet.yield(frame)
                    }
                    await reply(command.id, .ok)
                } catch {
                    await reply(command.id, .error(code: "voice_unavailable", message: error.localizedDescription))
                }

            case .stopSpeaking:
                await delegate.stopSpeaking(connection: id)
                await reply(command.id, .ok)

            case .remoteInput:
                // In order, one after another; the reply goes out on its own, so the next input never waits behind
                // screen frames on a busy link.
                let body = command.body
                let commandID = command.id
                let previous = inputTail
                inputTail = Task { [weak self] in
                    await previous?.value
                    guard let self else { return }
                    let result = await self.delegate.handle(body, from: client)
                    Task { await self.commandFinished(commandID, result: result) }
                }

            default:
                let body = command.body
                let commandID = command.id
                commandTasks[commandID] = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.delegate.handle(body, from: client)
                    await self.commandFinished(commandID, result: result)
                }
            }
        }
    }

    private func commandFinished(_ commandID: CommandID, result: ReplyBody) async {
        commandTasks[commandID] = nil
        guard !closed else { return }
        await reply(commandID, result)
    }

    // MARK: Event forwarding

    private func startEventForwarding() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.eventBus.subscribe()
            for await event in stream {
                if Task.isCancelled { break }
                await self.sendEvent(event)
            }
        }
    }

    private func sendEvent(_ event: HostEvent) async {
        guard !closed else { return }
        guard let data = try? WireMessage.event(event).encoded() else { return }
        await send(data, opcode: .text)
    }

    // MARK: Speech

    /// Where this client's speech goes: one stream, sent in order on the binary channel.
    private func speechOutlet() -> AsyncStream<Data>.Continuation {
        if let speech { return speech }
        let (frames, outlet) = AsyncStream<Data>.makeStream()
        speech = outlet
        speechTask = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.send(frame, opcode: .binary)
            }
        }
        return outlet
    }

    // MARK: Screen streaming

    private func startScreenStream(options: ScreenStreamOptions) {
        screenTask?.cancel()
        releaseAckWaiter()
        screenStreamID += 1
        let streamID = screenStreamID
        let channel = LatestValueChannel<(ScreenFrameHeader, Data)>()
        screenTask = Task { [weak self] in
            guard let self else { return }
            let frames = await self.delegate.screenFrames(options: options)
            let producer = Task {
                for await frame in frames {
                    if Task.isCancelled { break }
                    await channel.put(frame)
                }
                await channel.finish()
            }
            defer { producer.cancel() }
            let paced = options.acknowledges == true
            var previous: Int64?
            while !Task.isCancelled, let (captured, jpeg) = await channel.next() {
                // Numbered across this connection's streams, so a confirmation from an earlier one can't count here.
                var header = captured
                header.sequence = await self.nextFrameNumber()
                guard let data = try? ScreenFrameCodec.encode(header: header, jpeg: jpeg) else { continue }
                await self.send(data, opcode: .binary)
                // At most two frames unconfirmed: on a slow link the newest frame waits here (older ones are
                // dropped), instead of frames piling up in the network buffers for seconds.
                if paced, let previous { await self.waitForAck(of: previous) }
                previous = header.sequence
            }
            await self.screenStreamEnded(streamID)
        }
        Task { await server.setStreaming(true, connectionID: id) }
    }

    /// Waits until the client confirms frame `sequence`, or two seconds, so a lost confirmation never stalls the stream.
    private func waitForAck(of sequence: Int64) async {
        guard screenAcked < sequence, !closed else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ackWaiter?.continuation.resume()
            ackWaiter = (sequence, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.acknowledged(upTo: sequence)
            }
        }
    }

    private func nextFrameNumber() -> Int64 {
        framesSent += 1
        return framesSent
    }

    private func acknowledged(upTo sequence: Int64) {
        screenAcked = max(screenAcked, sequence)
        if let waiter = ackWaiter, screenAcked >= waiter.sequence {
            ackWaiter = nil
            waiter.continuation.resume()
        }
    }

    private func releaseAckWaiter() {
        ackWaiter?.continuation.resume()
        ackWaiter = nil
    }

    private func stopScreenStream() async {
        screenTask?.cancel()
        screenTask = nil
        releaseAckWaiter()
        await server.setStreaming(false, connectionID: id)
    }

    private func screenStreamEnded(_ streamID: Int) async {
        // Forgetting the newer stream here left it running for good: every desktop hand-over subscribes twice, and on
        // 2026-09-28 the host ended up encoding 28 captures nobody read.
        guard streamID == screenStreamID else { return }
        screenTask = nil
        guard !closed else { return }
        await server.setStreaming(false, connectionID: id)
    }

    // MARK: Sending

    private func reply(_ commandID: CommandID, _ result: ReplyBody) async {
        guard !closed else { return }
        do {
            let data = try WireMessage.reply(HostReply(commandID: commandID, result: result)).encoded()
            await send(data, opcode: .text)
        } catch {
            log.error("Could not encode reply: \(error)", category: "api")
        }
    }

    /// Sends one WebSocket message and waits until the stack has accepted it (backpressure).
    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) async {
        guard !closed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: opcode == .binary ? "binary" : "text", metadata: [metadata])
        let error: NWError? = await withCheckedContinuation { (continuation: CheckedContinuation<NWError?, Never>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                continuation.resume(returning: error)
            })
        }
        if let error {
            await close(reason: "send failed: \(error)")
        }
    }

    // MARK: Helpers

    /// A sign-in waits on a person (typing a GitHub code, a password): give the connection up to 15 minutes instead
    /// of the usual seconds before hello.
    private func extendSignInWindow() {
        guard !authenticated else { return }
        helloTimeoutTask?.cancel()
        helloTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15 * 60))
            guard let self, !Task.isCancelled else { return }
            if await !self.authenticated { await self.close(reason: "sign-in timeout") }
        }
    }

    private static func signInError(_ error: Error) -> ReplyBody {
        if let e = error as? PeopleService.SignInError { return .error(code: e.code, message: e.description) }
        return .error(code: "sign_in_failed", message: String(describing: error))
    }

    private static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address == IPv4Address.loopback
        case .ipv6(let address):
            if address.isLoopback { return true }
            if address.isIPv4Mapped, let v4 = address.asIPv4 { return v4 == IPv4Address.loopback }
            return false
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }
}

// MARK: - Support types

/// Resume-once guard for continuations driven by state handlers that may fire repeatedly.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}

/// Keeps only the newest value so a slow consumer never falls behind the producer.
actor LatestValueChannel<Value: Sendable> {
    private var value: Value?
    private var finished = false
    private var waiter: CheckedContinuation<Value?, Never>?

    func put(_ newValue: Value) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: newValue)
        } else {
            value = newValue
        }
    }

    func finish() {
        finished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    func next() async -> Value? {
        if let current = value {
            value = nil
            return current
        }
        if finished { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                if let current = value {
                    value = nil
                    continuation.resume(returning: current)
                } else if finished || Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWait() }
        }
    }

    private func cancelWait() {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}
