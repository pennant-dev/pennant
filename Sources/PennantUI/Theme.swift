import PennantClientKit
import PennantCore
import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

public extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

public extension Color {
    /// Parse "#RRGGBB" or "RRGGBB". Falls back to the Pennant blue on bad input.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = Color(hex: PennantPalette.defaultHex); return }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// A colour that resolves differently in light and dark appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        return Color(uiColor: UIColor { trait in trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #endif
    }

    static func adaptive(_ lightHex: String, _ darkHex: String) -> Color {
        adaptive(light: Color(hex: lightHex), dark: Color(hex: darkHex))
    }

}

// MARK: - Palette

/// One of Pennant's accent colours. Agents, jobs, and chips pick from this set so the roster stays coherent.
public struct AccentSwatch: Identifiable, Hashable, Sendable {
    public let name: String
    public let hex: String
    public var id: String { hex }
    public var color: Color { Color(hex: hex) }
}

public enum PennantPalette {
    public static let defaultHex = "#2F80ED"

    public static let swatches: [AccentSwatch] = [
        AccentSwatch(name: "Bark", hex: "#8A5A3C"),
        AccentSwatch(name: "Coral", hex: "#E5484D"),
        AccentSwatch(name: "Tangerine", hex: "#F0762B"),
        AccentSwatch(name: "Honey", hex: "#F0A93B"),
        AccentSwatch(name: "Moss", hex: "#3DB553"),
        AccentSwatch(name: "Lagoon", hex: "#1FA79E"),
        AccentSwatch(name: "Ocean", hex: "#2F80ED"),
        AccentSwatch(name: "Violet", hex: "#8B5CF6"),
        AccentSwatch(name: "Rose", hex: "#EC4899"),
        AccentSwatch(name: "Slate", hex: "#6B7280"),
    ]

    /// The swatch closest to a stored hex, so agents created elsewhere still land on a palette dot.
    public static func nearest(to hex: String) -> AccentSwatch {
        func rgb(_ h: String) -> (Double, Double, Double) {
            var s = h; if s.hasPrefix("#") { s.removeFirst() }
            guard let v = UInt32(s, radix: 16) else { return (47, 128, 237) }
            return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
        }
        let t = rgb(hex)
        return swatches.min { a, b in
            let ra = rgb(a.hex), rb = rgb(b.hex)
            let da = pow(ra.0 - t.0, 2) + pow(ra.1 - t.1, 2) + pow(ra.2 - t.2, 2)
            let db = pow(rb.0 - t.0, 2) + pow(rb.1 - t.1, 2) + pow(rb.2 - t.2, 2)
            return da < db
        } ?? swatches[6]
    }
}

// MARK: - Theme tokens

/// Pennant's visual language: light and quiet. Violet is you: your messages, what you press and select, and
/// whatever waits for you. Every other colour belongs to an agent's flag or to a status. Every token adapts to dark
/// mode; views use these instead of raw colours.
public enum PennantTheme {
    // Brand: the violet of the mark (#8B5CF6), a step deeper where white text sits on it.
    public static let brand = Color.adaptive("#7A4FE6", "#7C5CF0")
    /// Violet as text or an icon on the page (links, selected labels): dark enough to read on white, light on dark.
    public static let brandInk = Color.adaptive("#6A3FD9", "#B9A5FF")
    /// A violet wash for what's selected or highlighted.
    public static let brandSoft = Color.adaptive("#EFE9FE", "#2E2646")

    // Surfaces
    public static let windowBackground = Color.adaptive("#FFFFFF", "#151517")
    public static let sidebarBackground = Color.adaptive("#F5F5F7", "#1C1C1F")
    public static let panelBackground = Color.adaptive("#F8F8FA", "#19191C")
    public static let cardBackground = Color.adaptive("#F2F2F5", "#232327")
    public static let cardElevated = Color.adaptive("#FFFFFF", "#26262B")
    public static let fieldBackground = Color.adaptive("#EEEEF2", "#27272C")
    public static let selection = Color.adaptive("#EFE9FE", "#2E2646")
    public static let hover = Color.adaptive("#EBEBF0", "#28282D")
    public static let border = Color.adaptive("#E4E4E9", "#303036")
    public static let divider = Color.adaptive("#E9E9EE", "#2A2A30")

    // Ink
    public static let ink = Color.adaptive("#121214", "#F3F3F5")
    public static let inkSecondary = Color.adaptive("#6F6F78", "#9B9BA4")
    public static let inkTertiary = Color.adaptive("#A3A3AB", "#6C6C75")

    // Conversation bubbles
    public static let userBubble = Color.adaptive("#7A4FE6", "#6A4BD8")
    public static let userBubbleText = Color.adaptive("#FFFFFF", "#FFFFFF")
    public static let assistantBubble = Color.adaptive("#F1F1F4", "#26262B")

    // Buttons
    public static let primaryButton = Color.adaptive("#7A4FE6", "#7C5CF0")
    public static let primaryButtonText = Color.adaptive("#FFFFFF", "#FFFFFF")
    public static let disabledButton = Color.adaptive("#DCDCE1", "#34343A")
    public static let disabledButtonText = Color.adaptive("#9A9AA2", "#7A7A83")

    // Semantic status colours (the same hues the status functions below use).
    public static let success = Color(hex: "#3DB553")
    public static let warning = Color(hex: "#F0A93B")
    public static let danger = Color(hex: "#E5484D")
    public static let info = Color(hex: "#2F80ED")
    public static let attention = Color(hex: "#F0762B")

    // Shape
    public static let radiusSmall: CGFloat = 8
    public static let cornerRadius: CGFloat = 12
    public static let radiusLarge: CGFloat = 16
    public static let bubbleRadius: CGFloat = 18

    // Status colour is the one place saturated colour appears outside avatars.
    public static func color(for status: AgentStatus) -> Color {
        switch status {
        case .idle: return inkTertiary
        case .thinking: return Color(hex: "#2F80ED")
        case .acting: return Color(hex: "#3DB553")
        case .waitingForDesktop: return Color(hex: "#F0762B")
        case .waitingForUser: return Color(hex: "#8B5CF6")
        case .paused: return Color(hex: "#F0A93B")
        case .error: return Color(hex: "#E5484D")
        case .retired: return inkTertiary
        }
    }

    public static func color(for state: TaskState) -> Color {
        switch state {
        case .queued: return inkTertiary
        case .running: return Color(hex: "#2F80ED")
        case .waitingForTool: return Color(hex: "#1FA79E")
        case .waitingForDesktop: return Color(hex: "#F0762B")
        case .waitingForUser: return Color(hex: "#8B5CF6")
        case .paused: return Color(hex: "#F0A93B")
        case .completed: return Color(hex: "#3DB553")
        case .failed: return Color(hex: "#E5484D")
        case .cancelled: return inkTertiary
        }
    }

    public static func label(for state: TaskState) -> String {
        switch state {
        case .queued: return "Queued"
        case .running: return "Working"
        case .waitingForTool: return "Running a tool"
        case .waitingForDesktop: return "Waiting for the computer"
        case .waitingForUser: return "Needs your answer"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    public static func color(for status: MemoryStatus) -> Color {
        switch status {
        case .asserted: return Color(hex: "#3DB553")
        case .inferred: return Color(hex: "#2F80ED")
        case .contradicted: return Color(hex: "#F0762B")
        case .superseded: return inkTertiary
        case .forgotten: return Color(hex: "#E5484D")
        }
    }
}

// MARK: - Small shared pieces

public struct StatusDot: View {
    var color: Color
    var pulsing: Bool
    @State private var phase = false
    public init(color: Color, pulsing: Bool = false) { self.color = color; self.pulsing = pulsing }
    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing {
                    Circle()
                        .stroke(color.opacity(phase ? 0 : 0.6), lineWidth: 2)
                        .scaleEffect(phase ? 2.2 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: phase)
                }
            }
            .onAppear { if pulsing { phase = true } }
            .onChange(of: pulsing) { _, on in phase = on }
    }
}

public struct Chip: View {
    var text: String
    var color: Color
    public init(_ text: String, color: Color = PennantTheme.inkSecondary) { self.text = text; self.color = color }
    public var body: some View {
        // A tag keeps to one line: never wrapped a letter or a syllable at a time in a narrow row.
        Text(text)
            .font(.zoomed(.caption2).weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

public struct CardBackground: ViewModifier {
    var elevated: Bool
    public func body(content: Content) -> some View {
        content
            .padding(12)
            .background(elevated ? PennantTheme.cardElevated : PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
    }
}

public extension View {
    /// A quiet rounded card. `elevated` uses the window colour on a grey panel.
    func card(elevated: Bool = false) -> some View { modifier(CardBackground(elevated: elevated)) }
}

/// Small uppercase-free section caption, as in "Routines" above a list.
public struct SectionLabel: View {
    var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.zoomed(.subheadline))
            .foregroundStyle(PennantTheme.inkSecondary)
    }
}

/// An agent's icon: Pennant's own ribbon for the agent you talk to, and a tile with the job's symbol for the ones
/// working behind it (a coding engine, a separate agent from before). It stays still; working shows as a spinner where it matters, so
/// nothing here redraws while an agent works.
public struct AgentAvatar: View {
    @Environment(\.hostSession) private var session
    var agent: AgentProfile
    var size: CGFloat
    public init(agent: AgentProfile, size: CGFloat = 28) { self.agent = agent; self.size = size }
    public var body: some View {
        AgentTile(glyph: AgentGlyph.resolve(avatar: agent.avatar, name: agent.name, role: agent.role), hex: agent.accentColorHex, size: size,
                  isLead: session.state.leadAgent?.id == agent.id, needsYou: session.state.needsUser(agentID: agent.id),
                  alarmed: agent.status == .error)
    }
}

/// One fixed starting point for every periodic TimelineView. `.periodic(from: .now, …)` gets a new start each time
/// its parent's body runs, and a new start fires at once: inside a layout that measures its children (ViewThatFits)
/// that became a loop of a thousand updates a second, even with the window hidden.
public enum Clock {
    public static let anchor = Date()
}

public func relativeTime(_ date: Date) -> String {
    if abs(date.timeIntervalSinceNow) < 60 { return "Just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

/// "7:34 PM" today, "Tuesday" this week, else a short date. Matches what a chat list expects.
public func conversationTimestamp(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if let week = cal.date(byAdding: .day, value: -6, to: Date()), date > week { return date.formatted(.dateTime.weekday(.wide)) }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
