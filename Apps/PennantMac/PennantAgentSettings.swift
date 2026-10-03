import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Settings › Pennant: the one agent you talk to, how often it checks in on its own, how it writes code, and how long a
/// quiet thread stays in the list.
/// What it follows for each kind of work lives in Skills.
struct PennantAgentSettings: View {
    @Environment(\.hostSession) private var session
    @State private var editing: AgentProfile?

    var body: some View {
        SettingsPage {
            if let lead = session.state.leadAgent {
                SettingsCard("Who you talk to") {
                    HStack(alignment: .top, spacing: 12) {
                        AgentAvatar(agent: lead, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lead.name).font(.zoomed(.body).weight(.semibold)).foregroundStyle(PennantTheme.ink)
                            Text("Every thread, chat and scheduled job goes to \(lead.name). It follows a skill for each kind of work, brings in helpers when a job is big, and writes code itself.")
                                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Edit…") { editing = lead }
                            .buttonStyle(.pennantCompact)
                            .help("Instructions, voice, model and tools")
                    }
                    .padding(8)
                }
            }
            SettingsCard("Heartbeat") {
                HeartbeatSettings()
            }
            ChromeSettingsCard()
            SettingsCard("Coding") {
                CodingSettingsCard()
            }
            SettingsCard("Threads") {
                AutoTidyPicker()
                SettingsNote("A thread with work going, a question or card waiting on you, or an active goal stays. Anything new in a closed thread brings it back.")
            }
        }
        .sheet(item: $editing) { AgentEditorView(agent: $0) }
    }
}
