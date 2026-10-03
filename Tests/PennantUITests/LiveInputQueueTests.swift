import PennantCore
@testable import PennantClientKit
import Foundation
import XCTest

/// A host that answers a connection and records the live input it receives.
private final class RecordingHost: HostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<TransportInbound>.Continuation?
    private var received: [RemoteInput] = []
    private var acks: [Int64] = []
    /// Whether live input gets a reply (a busy link delivers it late; here, never).
    var repliesToInput = true
    var inputs: [RemoteInput] { lock.withLock { received } }
    var confirmedFrames: [Int64] { lock.withLock { acks } }

    func open(endpoint: HostEndpoint) async throws -> AsyncStream<TransportInbound> {
        AsyncStream { c in lock.withLock { continuation = c } }
    }

    func send(_ message: WireMessage) async throws {
        guard case .command(let command) = message else { return }
        switch command.body {
        case .hello:
            let host = HostInfo(hostName: "Studio", version: "0.1.0", startedAt: Date(), mode: .everyday, inferenceEndpoint: "", inferenceModel: "",
                                inferenceReachable: true, databasePath: "", activeTaskCount: 0, connectedClients: 1)
            reply(command.id, .welcome(StateSnapshot(host: host, agents: [], tasks: [], conversations: [], desktop: DesktopStatus(), mcpServers: [], latestEventSeq: 0)))
        case .listEvents:
            reply(command.id, .events([]))
        case .remoteInput(let input):
            lock.withLock { received.append(input) }
            // Like a real round trip: the reply comes a moment later.
            if lock.withLock({ repliesToInput }) { Task { try? await Task.sleep(for: .milliseconds(30)); self.reply(command.id, .ok) } }
        case .subscribeScreen:
            reply(command.id, .ok)
            for n in Int64(1) ... 3 {
                _ = lock.withLock { continuation?.yield(.screenFrame(ScreenFrameHeader(sequence: n, width: 4, height: 4, owner: .nobody), Data([0xFF, 0xD8, 0xFF, 0xD9]))) }
            }
        case .screenFrameReceived(let n):
            lock.withLock { acks.append(n) }
        default:
            reply(command.id, .ok)
        }
    }

    func close() async { lock.withLock { continuation?.finish() } }

    private func reply(_ id: CommandID, _ body: ReplyBody) {
        _ = lock.withLock { continuation?.yield(.message(.reply(HostReply(commandID: id, result: body)))) }
    }
}

@MainActor
final class LiveInputQueueTests: XCTestCase {
    func testLiveInputGoesOutInOrderWithWaitingMovesMerged() async throws {
        let host = RecordingHost()
        let session = HostSession(transport: host, token: "t", displayName: "iPhone", platform: "iOS")
        session.connect()
        let deadline = Date().addingTimeInterval(5)
        while session.state.host == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(session.state.host, "connected")

        // A drag as the finger produces it, then a click: the three moves waiting together become the last one.
        session.queueRemoteInput(.pointerDown(x: 0.1, y: 0.1, button: .left))
        session.queueRemoteInput(.pointerMove(x: 0.2, y: 0.2))
        session.queueRemoteInput(.pointerMove(x: 0.3, y: 0.3))
        session.queueRemoteInput(.pointerMove(x: 0.4, y: 0.4))
        session.queueRemoteInput(.pointerUp(x: 0.4, y: 0.4, button: .left))
        session.queueRemoteInput(.click(x: 0.5, y: 0.5, button: .left, count: 1))
        while host.inputs.count < 4, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(host.inputs, [.pointerDown(x: 0.1, y: 0.1, button: .left), .pointerMove(x: 0.4, y: 0.4),
                                     .pointerUp(x: 0.4, y: 0.4, button: .left), .click(x: 0.5, y: 0.5, button: .left, count: 1)])
        await session.disconnect()
    }

    func testLiveInputDoesntWaitForReplies() async throws {
        let host = RecordingHost()
        host.repliesToInput = false
        let session = HostSession(transport: host, token: "t", displayName: "iPhone", platform: "iOS")
        session.connect()
        let deadline = Date().addingTimeInterval(5)
        while session.state.host == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        // Replies that never come (or come late, behind frames) don't hold the next click back.
        session.queueRemoteInput(.click(x: 0.1, y: 0.1, button: .left, count: 1))
        try await Task.sleep(for: .milliseconds(50))
        session.queueRemoteInput(.click(x: 0.2, y: 0.2, button: .left, count: 1))
        try await Task.sleep(for: .milliseconds(50))
        session.queueRemoteInput(.click(x: 0.3, y: 0.3, button: .left, count: 1))
        let soon = Date().addingTimeInterval(0.5)
        while host.inputs.count < 3, Date() < soon { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(host.inputs.count, 3, "all three went out without replies")
        await session.disconnect()
    }

    func testEveryScreenFrameIsConfirmed() async throws {
        let host = RecordingHost()
        let session = HostSession(transport: host, token: "t", displayName: "iPhone", platform: "iOS")
        session.connect()
        let deadline = Date().addingTimeInterval(5)
        while session.state.host == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await session.watchScreen()
        while host.confirmedFrames.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(Set(host.confirmedFrames), [1, 2, 3])
        await session.disconnect()
    }
}

