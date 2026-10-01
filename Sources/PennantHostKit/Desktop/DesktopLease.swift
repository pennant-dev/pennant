import PennantCore
import Foundation

/// One foreground owner per desktop. Agents queue; a human takeover revokes the current holder
/// and blocks new grants until released. Actions must check `isValid` before synthesizing input.
public actor DesktopLease {
    public struct Token: Sendable, Hashable {
        public let id: LeaseID
        public let agentID: AgentID
        public let taskID: TaskID
    }

    private struct Waiter {
        let agentID: AgentID
        let taskID: TaskID
        let continuation: CheckedContinuation<Token, Error>
    }

    private var holder: Token?
    private var waiters: [Waiter] = []
    private var revokedTokens: Set<LeaseID> = []
    private(set) public var humanHasControl = false
    private(set) public var pausedByHuman = false
    public var pauseOnHumanInput: Bool
    private let onChange: @Sendable (DesktopLease) async -> Void
    private let desktop: (any DesktopControlling)?

    public init(pauseOnHumanInput: Bool = true, desktop: (any DesktopControlling)? = nil, onChange: @escaping @Sendable (DesktopLease) async -> Void = { _ in }) {
        self.pauseOnHumanInput = pauseOnHumanInput
        self.desktop = desktop
        self.onChange = onChange
    }

    public var owner: DesktopOwner {
        if humanHasControl { return .human }
        if let h = holder { return .agent(h.agentID, h.taskID) }
        return .nobody
    }

    public var queue: [TaskID] { waiters.map(\.taskID) }
    public var currentHolder: Token? { holder }

    /// Wait for the desktop. Throws if cancelled while waiting.
    public func acquire(agentID: AgentID, taskID: TaskID) async throws -> Token {
        if let h = holder, h.taskID == taskID { return h }
        try Task.checkCancellation()
        if holder == nil, !humanHasControl, !pausedByHuman {
            let token = Token(id: LeaseID(), agentID: agentID, taskID: taskID)
            holder = token
            await onChange(self)
            return token
        }
        let token: Token = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(agentID: agentID, taskID: taskID, continuation: continuation))
                Task { await onChange(self) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(taskID: taskID) }
        }
        return token
    }

    private func cancelWaiter(taskID: TaskID) {
        if let i = waiters.firstIndex(where: { $0.taskID == taskID }) {
            let w = waiters.remove(at: i)
            w.continuation.resume(throwing: CancellationError())
        }
    }

    public func release(_ token: Token) async {
        guard holder?.id == token.id else { return }
        holder = nil
        await grantNext()
        await onChange(self)
    }

    public func isValid(_ token: Token) -> Bool {
        holder?.id == token.id && !humanHasControl && !pausedByHuman && !revokedTokens.contains(token.id)
    }

    /// Human takes over: current holder is revoked and any in-flight input is interrupted.
    public func humanTakeover() async {
        humanHasControl = true
        if let h = holder { revokedTokens.insert(h.id); holder = nil }
        await desktop?.interruptInput()
        await onChange(self)
    }

    public func humanRelease() async {
        humanHasControl = false
        if !pausedByHuman { await grantNext() }
        await onChange(self)
    }

    /// Pause agent desktop actions without claiming control (stop button, or pause-on-human-input).
    public func pause() async {
        pausedByHuman = true
        if let h = holder { revokedTokens.insert(h.id); holder = nil }
        await desktop?.interruptInput()
        await onChange(self)
    }

    public func resume() async {
        pausedByHuman = false
        if !humanHasControl { await grantNext() }
        await onChange(self)
    }

    private func grantNext() async {
        guard holder == nil, !humanHasControl, !pausedByHuman, !waiters.isEmpty else { return }
        let w = waiters.removeFirst()
        let token = Token(id: LeaseID(), agentID: w.agentID, taskID: w.taskID)
        holder = token
        w.continuation.resume(returning: token)
    }

    /// Drop a task from the queue and release its lease (task cancelled or finished).
    public func forget(taskID: TaskID) async {
        cancelWaiter(taskID: taskID)
        if let h = holder, h.taskID == taskID {
            holder = nil
            await grantNext()
        }
        await onChange(self)
    }

    public func snapshot(permissions: DesktopPermissions, frontmostApp: String?, displayWidth: Int, displayHeight: Int, streamingClients: Int) -> DesktopStatus {
        DesktopStatus(owner: owner, queue: queue, pausedByHuman: pausedByHuman, pauseOnHumanInput: pauseOnHumanInput, permissions: permissions, frontmostApp: frontmostApp, displayWidth: displayWidth, displayHeight: displayHeight, streamingClients: streamingClients)
    }
}
