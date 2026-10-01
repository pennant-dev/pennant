import PennantCore
import Foundation

/// Fan-out of host events to in-process subscribers (API server, runtime, tests).
/// Durable events are assigned a sequence by the store before being published here.
public actor EventBus {
    private var continuations: [UUID: AsyncStream<HostEvent>.Continuation] = [:]
    private(set) public var latestSeq: EventSeq = 0

    public init() {}

    public func subscribe(bufferingPolicy: AsyncStream<HostEvent>.Continuation.BufferingPolicy = .bufferingNewest(2048)) -> AsyncStream<HostEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HostEvent>.makeStream(bufferingPolicy: bufferingPolicy)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
    }

    public func publish(_ event: HostEvent) {
        if event.seq > latestSeq { latestSeq = event.seq }
        for c in continuations.values { c.yield(event) }
    }
}
