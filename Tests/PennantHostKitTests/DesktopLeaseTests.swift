import PennantCore
@testable import PennantHostKit
import XCTest

private let agentA = AgentID("agent-a")
private let agentB = AgentID("agent-b")
private let taskA = TaskID("task-a")
private let taskB = TaskID("task-b")

final class DesktopLeaseTests: XCTestCase {

    func testAcquireGrantsImmediatelyWhenFree() async throws {
        let lease = DesktopLease()
        let token = try await lease.acquire(agentID: agentA, taskID: taskA)
        let owner = await lease.owner
        XCTAssertEqual(owner, .agent(agentA, taskA))
        let valid = await lease.isValid(token)
        XCTAssertTrue(valid)
        await lease.release(token)
        let after = await lease.owner
        XCTAssertEqual(after, .nobody)
    }

    func testReacquireBySameTaskReturnsSameToken() async throws {
        let lease = DesktopLease()
        let first = try await lease.acquire(agentID: agentA, taskID: taskA)
        let second = try await lease.acquire(agentID: agentA, taskID: taskA)
        XCTAssertEqual(first, second)
    }

    func testSecondTaskQueuesUntilRelease() async throws {
        let lease = DesktopLease()
        let tokenA = try await lease.acquire(agentID: agentA, taskID: taskA)
        let waiter = Task { try await lease.acquire(agentID: agentB, taskID: taskB) }
        try await Task.sleep(for: .milliseconds(50))
        let queue = await lease.queue
        XCTAssertEqual(queue, [taskB])
        await lease.release(tokenA)
        let tokenB = try await waiter.value
        XCTAssertEqual(tokenB.taskID, taskB)
        let owner = await lease.owner
        XCTAssertEqual(owner, .agent(agentB, taskB))
        let emptyQueue = await lease.queue
        XCTAssertTrue(emptyQueue.isEmpty)
    }

    func testHumanTakeoverRevokesHolderAndBlocksGrants() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease(desktop: desktop)
        let token = try await lease.acquire(agentID: agentA, taskID: taskA)
        await lease.humanTakeover()
        let valid = await lease.isValid(token)
        XCTAssertFalse(valid)
        let owner = await lease.owner
        XCTAssertEqual(owner, .human)
        XCTAssertEqual(desktop.interruptCount, 1)

        let waiter = Task { try await lease.acquire(agentID: agentB, taskID: taskB) }
        try await Task.sleep(for: .milliseconds(50))
        let queue = await lease.queue
        XCTAssertEqual(queue, [taskB], "no grants while a human holds the desktop")
        await lease.humanRelease()
        let tokenB = try await waiter.value
        XCTAssertEqual(tokenB.taskID, taskB)
    }

    func testPauseAndResume() async throws {
        let desktop = FakeDesktop()
        let lease = DesktopLease(desktop: desktop)
        let token = try await lease.acquire(agentID: agentA, taskID: taskA)
        await lease.pause()
        let paused = await lease.pausedByHuman
        XCTAssertTrue(paused)
        let valid = await lease.isValid(token)
        XCTAssertFalse(valid)
        let owner = await lease.owner
        XCTAssertEqual(owner, .nobody)
        XCTAssertEqual(desktop.interruptCount, 1)

        let waiter = Task { try await lease.acquire(agentID: agentA, taskID: taskA) }
        try await Task.sleep(for: .milliseconds(50))
        let queued = await lease.queue
        XCTAssertEqual(queued, [taskA])
        await lease.resume()
        let fresh = try await waiter.value
        XCTAssertNotEqual(fresh.id, token.id, "a paused holder gets a new token on resume")
        let validNow = await lease.isValid(fresh)
        XCTAssertTrue(validNow)
    }

    func testForgetRemovesQueuedTaskAndReleasesHolder() async throws {
        let lease = DesktopLease()
        let tokenA = try await lease.acquire(agentID: agentA, taskID: taskA)
        let waiter = Task { try await lease.acquire(agentID: agentB, taskID: taskB) }
        try await Task.sleep(for: .milliseconds(50))
        await lease.forget(taskID: taskB)
        do {
            _ = try await waiter.value
            XCTFail("forgotten waiter should be cancelled")
        } catch is CancellationError {
        }
        let queue = await lease.queue
        XCTAssertTrue(queue.isEmpty)

        await lease.forget(taskID: taskA)
        let owner = await lease.owner
        XCTAssertEqual(owner, .nobody)
        let valid = await lease.isValid(tokenA)
        XCTAssertFalse(valid)
    }

    func testCancellingWaitingAcquireRemovesWaiter() async throws {
        let lease = DesktopLease()
        let tokenA = try await lease.acquire(agentID: agentA, taskID: taskA)
        let waiter = Task { try await lease.acquire(agentID: agentB, taskID: taskB) }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("cancelled acquire should throw")
        } catch is CancellationError {
        }
        try await Task.sleep(for: .milliseconds(20))
        let queue = await lease.queue
        XCTAssertTrue(queue.isEmpty)
        await lease.release(tokenA)
        let owner = await lease.owner
        XCTAssertEqual(owner, .nobody)
    }

    func testSnapshotReflectsState() async throws {
        let lease = DesktopLease(pauseOnHumanInput: false)
        _ = try await lease.acquire(agentID: agentA, taskID: taskA)
        let snapshot = await lease.snapshot(permissions: DesktopPermissions(accessibility: true, screenRecording: false, automation: true), frontmostApp: "Finder", displayWidth: 1600, displayHeight: 1000, streamingClients: 2)
        XCTAssertEqual(snapshot.owner, .agent(agentA, taskA))
        XCTAssertFalse(snapshot.pauseOnHumanInput)
        XCTAssertEqual(snapshot.frontmostApp, "Finder")
        XCTAssertEqual(snapshot.streamingClients, 2)
        XCTAssertFalse(snapshot.permissions.screenRecording)
    }
}
