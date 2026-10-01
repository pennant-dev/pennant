import PennantCore
import Foundation

/// Owns the one teach-mode session: starts and stops the recorder, collects its steps in order, and keeps
/// the stopped session for review until it is drafted, replaced, or cancelled. Every change is published
/// as `teachingUpdated` so the teaching panel and the review sheet follow along.
public actor TeachingService {
    private var session: TeachingSession?
    private var consumer: Task<Void, Never>?
    private var continuation: AsyncStream<TeachingRecorder.Recorded>.Continuation?
    private var nextID = 1
    private let publish: @Sendable (TeachingSession?) async -> Void
    /// Makes the recorder; tests pass one that never touches the event tap.
    private let startRecorder: @Sendable (@escaping @Sendable (TeachingRecorder.Recorded) -> Void) -> (stop: @Sendable () -> Void, started: Bool)

    public init(publish: @escaping @Sendable (TeachingSession?) async -> Void, fileURL: URL? = nil) {
        self.init(publish: publish, fileURL: fileURL, startRecorder: { sink in
            let recorder = TeachingRecorder(onEvent: sink)
            let ok = recorder.start()
            return ({ recorder.stop() }, ok)
        })
    }

    init(publish: @escaping @Sendable (TeachingSession?) async -> Void, fileURL: URL? = nil, startRecorder: @escaping @Sendable (@escaping @Sendable (TeachingRecorder.Recorded) -> Void) -> (stop: @Sendable () -> Void, started: Bool)) {
        self.startRecorder = startRecorder
        if let fileURL, let data = try? Data(contentsOf: fileURL), var saved = try? JSONDecoder().decode(TeachingSession.self, from: data) {
            if saved.isRecording { saved.isRecording = false; saved.endedAt = saved.endedAt ?? saved.events.last?.at ?? Date() }
            saved.isDrafting = false
            self.session = saved
            self.nextID = (saved.events.map(\.id).max() ?? 0) + 1
        }
        self.publish = { session in
            if let fileURL {
                if let session, let data = try? JSONEncoder().encode(session) {
                    try? data.write(to: fileURL, options: .atomic)
                } else if session == nil {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            await publish(session)
        }
    }

    private var stopRecorder: (@Sendable () -> Void)?

    public var current: TeachingSession? { session }

    public func start(goal: String) async -> TeachingSession {
        if session?.isRecording == true { await stopRecording() }
        var s = TeachingSession(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines))
        nextID = 1
        let (stream, continuation) = AsyncStream.makeStream(of: TeachingRecorder.Recorded.self)
        self.continuation = continuation
        consumer = Task { [weak self] in
            for await item in stream { await self?.record(item.kind, at: item.at) }
        }
        let started = startRecorder { item in continuation.yield(item) }
        stopRecorder = started.stop
        if !started.started {
            s.warning = "Pennant can’t watch the mouse and keyboard yet. Grant Accessibility and Input Monitoring to Pennant Host (Settings › Permissions), then start again. Notes still work."
        }
        session = s
        await publish(s)
        return s
    }

    /// Stops recording and waits until every step the recorder saw is in the session.
    @discardableResult
    public func stop() async -> TeachingSession? {
        guard session?.isRecording == true else { return session }
        await stopRecording()
        session?.isRecording = false
        session?.endedAt = Date()
        await publish(session)
        return session
    }

    public func cancel() async {
        await stopRecording()
        session = nil
        await publish(nil)
    }

    public func addNote(_ text: String) async -> TeachingSession? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, session != nil else { return session }
        append(.note(t), at: Date())
        await publish(session)
        return session
    }

    public func removeEvents(_ ids: [Int]) async -> TeachingSession? {
        let drop = Set(ids)
        session?.events.removeAll { drop.contains($0.id) }
        await publish(session)
        return session
    }

    public func setDrafting(_ drafting: Bool, goal: String? = nil) async {
        session?.isDrafting = drafting
        if drafting { session?.draftError = nil }
        if let goal, !goal.trimmingCharacters(in: .whitespaces).isEmpty { session?.goal = goal.trimmingCharacters(in: .whitespaces) }
        await publish(session)
    }

    public func finishDraft(skillID: SkillID?, error: String?) async {
        session?.isDrafting = false
        session?.draftSkillID = skillID ?? session?.draftSkillID
        session?.draftError = error
        await publish(session)
    }

    // MARK: Private

    private func stopRecording() async {
        stopRecorder?()          // flushes merged typing into the stream, synchronously
        stopRecorder = nil
        continuation?.finish()
        continuation = nil
        await consumer?.value    // every yielded step is appended before this returns
        consumer = nil
    }

    /// A step from the recorder: appended and published (and saved) in arrival order.
    private func record(_ kind: TeachingEventKind, at: Date) async {
        guard append(kind, at: at) else { return }
        await publish(session)
    }

    @discardableResult
    private func append(_ kind: TeachingEventKind, at: Date) -> Bool {
        guard var s = session else { return false }
        s.events.append(TeachingEvent(id: nextID, at: at, kind: kind))
        nextID += 1
        if s.events.count > 2000 { s.events.removeFirst(s.events.count - 2000) }
        session = s
        return true
    }
}
