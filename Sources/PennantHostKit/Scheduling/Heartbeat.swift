import PennantCore
import Foundation

/// Pennant's heartbeat. Every so often (Settings › Pennant › Heartbeat) it looks over the work without the model:
/// the goal sessions that are due start (a goal needs no schedule of its own), and when something needs a look (work
/// that stopped moving, a question or draft left waiting for hours), Pennant takes one turn in its chat to nudge,
/// stop or tell. A beat with nothing in it costs nothing, and Pennant's turns are capped per day.
public actor Heartbeat {
    /// What one beat did, for the log and the tests.
    public struct Beat: Sendable {
        public var goalSessions: [String] = []
        public var signals: [String] = []
        public var turn: TaskID?
        public var skipped: String?
    }

    private let runtime: TaskRuntime
    private let scheduler: Scheduler
    private var settings: HostConfig.Heartbeat
    private var loop: Task<Void, Never>?
    /// When each signal was last raised: the same stalled thread isn't raised on every beat.
    private var raised: [String: Date] = [:]
    private var turns: (day: String, count: Int) = ("", 0)

    /// How long before the same thing is raised again.
    static let raiseAgainAfter: TimeInterval = 6 * 3600

    public init(runtime: TaskRuntime, scheduler: Scheduler, settings: HostConfig.Heartbeat) {
        self.runtime = runtime
        self.scheduler = scheduler
        self.settings = settings
    }

    public func start() async {
        await scheduler.setGoalsOnHeartbeat(settings.enabled)
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let minutes = max(5, await self.settings.intervalMinutes)
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                if Task.isCancelled { return }
                _ = await self.beat()
            }
        }
    }

    public func stop() { loop?.cancel() }

    /// New settings: the next beat comes a full interval from now.
    public func update(_ new: HostConfig.Heartbeat) async {
        let changed = new != settings
        settings = new
        if changed { await start() }
    }

    /// One look over the work.
    @discardableResult
    public func beat(now: Date = Date()) async -> Beat {
        var beat = Beat()
        guard settings.enabled else { beat.skipped = "off"; return beat }
        let runtime = self.runtime
        let started = await scheduler.runDueGoalJobs(now: now) { job in await runtime.goalWaitsOnOwner(job) }
        beat.goalSessions = started.map(\.name)

        let fresh = await runtime.heartbeatSignals(now: now).filter { signal in
            raised[signal.key].map { now.timeIntervalSince($0) > Self.raiseAgainAfter } ?? true
        }
        beat.signals = fresh.map(\.text)
        if !fresh.isEmpty {
            let day = Self.day(now)
            if turns.day != day { turns = (day, 0) }
            if turns.count >= settings.maxTurnsPerDay {
                beat.skipped = "already took \(turns.count) turns today"
            } else if let id = try? await runtime.heartbeatTurn(brief: fresh.map { "- " + $0.text }.joined(separator: "\n")) {
                beat.turn = id
                turns.count += 1
                for signal in fresh { raised[signal.key] = now }
            } else {
                beat.skipped = "the chat was busy"
            }
        }
        raised = raised.filter { now.timeIntervalSince($0.value) < 2 * Self.raiseAgainAfter }
        if !beat.goalSessions.isEmpty || beat.turn != nil {
            log.info("Heartbeat: \(beat.goalSessions.count) goal session(s), \(beat.signals.count) thing(s) to look at\(beat.turn == nil ? "" : ", Pennant took a turn")", category: "heartbeat")
        }
        return beat
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
