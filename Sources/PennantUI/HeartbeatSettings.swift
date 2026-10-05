import PennantClientKit
import PennantCore
import SwiftUI

/// Settings › Pennant › Heartbeat: whether Pennant checks in on its own, how often, what else it does on each check-in
/// (in the owner's words), and how many times a day it may stop to think.
public struct HeartbeatSettings: View {
    @Environment(\.hostSession) private var session
    @State private var heartbeat = HostConfig.Heartbeat()
    @State private var loaded = false
    @State private var error: String?
    /// The save waiting for typing to pause.
    @State private var saving: Task<Void, Never>?

    public init() {}

    static let intervals: [(minutes: Int, label: String)] = [(15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"), (120, "Every 2 hours"), (240, "Every 4 hours")]
    static let caps: [Int] = [6, 12, 24, 48, 96]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pennant checks in on its own", isOn: $heartbeat.enabled)
            Picker("How often", selection: $heartbeat.intervalMinutes) {
                ForEach(Self.options(Self.intervals.map(\.minutes), keeping: heartbeat.intervalMinutes), id: \.self) { m in
                    Text(Self.intervals.first { $0.minutes == m }?.label ?? "Every \(m) minutes").tag(m)
                }
            }
            .disabled(!heartbeat.enabled)
            Picker("At most", selection: $heartbeat.maxTurnsPerDay) {
                ForEach(Self.options(Self.caps, keeping: heartbeat.maxTurnsPerDay), id: \.self) { n in
                    Text("\(n) check-ins a day").tag(n)
                }
            }
            .disabled(!heartbeat.enabled)
            PennantTextField("On each check-in, also", placeholder: "e.g. Check my email for anything that needs me today", text: Binding(
                get: { heartbeat.instructions ?? "" },
                set: { heartbeat.instructions = $0.isEmpty ? nil : $0 }), lines: 2 ... 5)
                .disabled(!heartbeat.enabled)
            Text(heartbeat.enabled
                 ? "Each check looks over your threads and goals without the model, and starts a goal's next session when it's due, so goals don't need schedules. Pennant only stops to think, and only costs anything, when something needs a look: work that stopped moving, or something left waiting on you. Whatever you write above, it does on every check-in with the tools and connections it has, and tells you only what needs you; that's a turn of the model each time."
                 : "Off: goals run on their own schedules, and Pennant only works when you ask or a schedule fires.")
                .font(.zoomed(.caption))
                .foregroundStyle(PennantTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger) }
        }
        .disabled(!loaded)
        .task {
            guard !loaded, let c = try? await session.getConfig().config else { return }
            heartbeat = c.heartbeat
            loaded = true
        }
        .onChange(of: heartbeat) { _, new in
            guard loaded else { return }
            saving?.cancel()
            saving = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                do {
                    var c = try await session.getConfig().config
                    guard c.heartbeat != new else { return }
                    c.heartbeat = new
                    _ = try await session.updateConfig(c)
                    error = nil
                } catch { self.error = HostSessionError.message(error) }
            }
        }
    }

    /// The choices, plus the current value when it's one set elsewhere (the command line).
    static func options(_ choices: [Int], keeping current: Int) -> [Int] {
        choices.contains(current) ? choices : (choices + [current]).sorted()
    }
}
