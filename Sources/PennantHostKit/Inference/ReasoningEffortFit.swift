import Foundation

/// Reasoning-effort names differ between servers ("high" on one, only "xhigh" on another). When an endpoint rejects
/// an effort and says which it supports, the nearest supported one is used instead, and remembered per model so the
/// next request goes right the first time.
enum ReasoningEffortFit {
    static let ladder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var remembered: [String: String?] = [:]

    static func key(base: String, model: String) -> String { "\(base)|\(model)" }

    /// The effort to send: a remembered substitute when this model rejected `effort` before. `.some(nil)` means
    /// send none at all.
    static func substitute(for effort: String, key: String) -> String?? {
        lock.withLock { remembered["\(key)|\(effort)"] }
    }

    static func remember(_ effort: String, as fitted: String?, key: String) {
        lock.withLock { remembered["\(key)|\(effort)"] = .some(fitted) }
    }

    nonisolated(unsafe) private static var completionTokenModels: Set<String> = []
    /// Models that refused `max_tokens` and asked for `max_completion_tokens`.
    static func wantsCompletionTokens(key: String) -> Bool { lock.withLock { completionTokenModels.contains(key) } }
    static func rememberCompletionTokens(key: String) { _ = lock.withLock { completionTokenModels.insert(key) } }

    /// Whether an error body is about the reasoning effort.
    static func isEffortError(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("reasoning") && lower.contains("effort")
    }

    /// The supported efforts named in an error body, in ladder order.
    static func supported(in body: String) -> [String] {
        let lower = body.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        // Only the part after "supported" lists the allowed ones; the rejected value comes before it.
        let tail = lower.range(of: "support").map { String(lower[$0.lowerBound...]) } ?? lower
        let tailWords = Set(tail.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return ladder.filter { tailWords.contains($0) && words.contains($0) }
    }

    /// The nearest supported effort; on a tie the stronger one, since the user asked for more thinking.
    static func nearest(to effort: String, among supported: [String]) -> String? {
        guard !supported.isEmpty else { return nil }
        guard let want = ladder.firstIndex(of: effort.lowercased()) else { return supported.first }
        return supported.min { a, b in
            let da = abs((ladder.firstIndex(of: a) ?? 0) - want), db = abs((ladder.firstIndex(of: b) ?? 0) - want)
            return da != db ? da < db : (ladder.firstIndex(of: a) ?? 0) > (ladder.firstIndex(of: b) ?? 0)
        }
    }
}
