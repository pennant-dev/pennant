import PennantClientKit
import PennantCore
import SwiftUI

/// Every approval card waiting for the user, from any agent, newest first: who asked and when above each card,
/// and the card itself, so it can be approved, sent back or rejected right here. Decided cards leave the list.
public struct ApprovalsView: View {
    @Environment(\.hostSession) private var session
    /// Opens the conversation a card came from.
    var onOpen: ((AgentID, ConversationID) -> Void)?

    public init(onOpen: ((AgentID, ConversationID) -> Void)? = nil) { self.onOpen = onOpen }

    public var body: some View {
        let pending = session.state.pendingApprovals
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(pending) { item in
                    ApprovalCard(request: item.request, agentID: item.agentID,
                                 onOpenChat: onOpen.map { open in { open(item.agentID, item.conversationID) } })
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: pending.map(\.id))
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .overlay {
            if pending.isEmpty {
                EmptyState(title: "Nothing waiting for you", message: "When an agent wants to post, send or publish something, its card shows up here as well as in its chat.")
            }
        }
        .background(PennantTheme.panelBackground)
        .decisionToasts()
        .refreshable { try? await session.loadPendingApprovals() }
        .task { try? await session.loadPendingApprovals() }
    }
}

/// The little orange bubble: how many cards wait for the user. Hidden when none do.
public struct ApprovalsBubble: View {
    @Environment(\.hostSession) private var session
    var action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        let count = session.state.pendingApprovals.count
        if count > 0 {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").font(.zoomed(size: 11, weight: .semibold))
                    Text("\(count) approval\(count == 1 ? "" : "s")").font(.zoomed(.caption).weight(.semibold)).monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(PennantTheme.attention, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(count) card\(count == 1 ? "" : "s") waiting for your approval")
            .accessibilityLabel("\(count) approvals waiting")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }
}
