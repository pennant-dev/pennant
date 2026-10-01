import PennantCore
import SwiftUI

/// Tells whoever shows approval cards that one was just decided, so it can confirm it with a toast.
private struct ApprovalDecidedKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (ApprovalRequest, ApprovalDecision.Verdict) -> Void)? = nil
}

public extension EnvironmentValues {
    var approvalDecided: (@MainActor @Sendable (ApprovalRequest, ApprovalDecision.Verdict) -> Void)? {
        get { self[ApprovalDecidedKey.self] }
        set { self[ApprovalDecidedKey.self] = newValue }
    }
}

/// A short confirmation at the bottom each time a card is decided under this view ("Sent · Reply to Dana").
struct DecisionToasts: ViewModifier {
    struct Toast: Equatable {
        var id = UUID()
        var symbol: String
        var text: String
        var color: Color
    }
    @State private var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    HStack(spacing: 7) {
                        Image(systemName: toast.symbol).foregroundStyle(toast.color)
                        Text(toast.text).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(PennantTheme.cardElevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(PennantTheme.border))
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                }
            }
            .environment(\.approvalDecided) { request, verdict in show(request, verdict) }
    }

    private func show(_ request: ApprovalRequest, _ verdict: ApprovalDecision.Verdict) {
        let t: Toast
        switch verdict {
        case .approve:
            let label = request.action?.label ?? "Approved"
            t = Toast(symbol: "checkmark.circle.fill", text: "\(Self.pastTense(label)) · \(request.title)", color: PennantTheme.success)
        case .approveRest:
            t = Toast(symbol: "checkmark.circle.fill", text: "Allowed for the rest of this task · \(request.title)", color: PennantTheme.success)
        case .requestChanges:
            t = Toast(symbol: "arrow.uturn.backward.circle.fill", text: "Sent back · \(request.title)", color: PennantTheme.warning)
        case .reject:
            t = Toast(symbol: "xmark.circle.fill", text: "Rejected · \(request.title)", color: PennantTheme.danger)
        }
        withAnimation(.snappy) { toast = t }
        let id = t.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.2))
            if toast?.id == id { withAnimation(.easeOut(duration: 0.3)) { toast = nil } }
        }
    }

    /// "Approve & send" → "Sent", "Approve & post" → "Posted"; anything else reads "Approved".
    static func pastTense(_ label: String) -> String {
        let verb = label.components(separatedBy: "&").last?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch verb {
        case "send": return "Sent"
        case "post": return "Posted"
        case "publish": return "Published"
        case "upload": return "Uploaded"
        case "deploy": return "Deploying"
        case "run": return "Running"
        default: return "Approved"
        }
    }
}

public extension View {
    /// Confirms each approval decided inside this view with a toast.
    func decisionToasts() -> some View { modifier(DecisionToasts()) }
}
