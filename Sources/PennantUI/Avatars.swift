import PennantCore
import SwiftUI

/// Pennant's avatar system: every agent flies a flag in its accent colour with a symbol for its job (an envelope
/// for the inbox, a pulse line for ops). Stored on the profile as `flag:<glyph>`. Older profiles that carry a
/// `shape:` token or an emoji still get a flag: the glyph is guessed from the agent's name and role.
public enum AgentGlyph: String, CaseIterable, Identifiable, Sendable {
    case compass, envelope, megaphone, play, pulse, nodes
    case magnifier, pencil, calendar, chat, book, folder
    case chart, dollar, cart, code, wrench, shield
    case bell, camera, globe, house, moon, sparkle

    public var id: String { rawValue }
    public var token: String { "flag:\(rawValue)" }
    public static let defaultGlyph: AgentGlyph = .sparkle

    /// The SF Symbol drawn on the flag.
    public var symbol: String {
        switch self {
        case .compass: return "safari"
        case .envelope: return "envelope.fill"
        case .megaphone: return "megaphone.fill"
        case .play: return "play.fill"
        case .pulse: return "waveform.path.ecg"
        case .nodes: return "point.3.connected.trianglepath.dotted"
        case .magnifier: return "magnifyingglass"
        case .pencil: return "pencil.line"
        case .calendar: return "calendar"
        case .chat: return "bubble.left.fill"
        case .book: return "book.fill"
        case .folder: return "folder.fill"
        case .chart: return "chart.bar.fill"
        case .dollar: return "dollarsign"
        case .cart: return "cart.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .wrench: return "wrench.and.screwdriver.fill"
        case .shield: return "checkmark.shield.fill"
        case .bell: return "bell.fill"
        case .camera: return "camera.fill"
        case .globe: return "globe"
        case .house: return "house.fill"
        case .moon: return "moon.stars.fill"
        case .sparkle: return "sparkles"
        }
    }

    /// What the symbol stands for, for the picker's tooltips and VoiceOver.
    public var title: String {
        switch self {
        case .compass: return "General help"
        case .envelope: return "Email"
        case .megaphone: return "Posting"
        case .play: return "Video"
        case .pulse: return "Operations"
        case .nodes: return "Architecture"
        case .magnifier: return "Research"
        case .pencil: return "Writing"
        case .calendar: return "Calendar"
        case .chat: return "Messages"
        case .book: return "Reading"
        case .folder: return "Files"
        case .chart: return "Reports"
        case .dollar: return "Money"
        case .cart: return "Shopping"
        case .code: return "Code"
        case .wrench: return "Maintenance"
        case .shield: return "Security"
        case .bell: return "Alerts"
        case .camera: return "Photos"
        case .globe: return "Web"
        case .house: return "Home"
        case .moon: return "Overnight"
        case .sparkle: return "Anything"
        }
    }

    /// Parses a stored `flag:` token. Returns nil for anything else (legacy shapes, emoji, blanks).
    public static func parse(_ avatar: String) -> AgentGlyph? {
        let s = avatar.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("flag:") else { return nil }
        return AgentGlyph(rawValue: String(s.dropFirst(5)))
    }

    /// The glyph for a profile: its own `flag:` token, else a guess from its name and role, else a stand-in for
    /// its old shape. Never nil, so every agent always has a flag.
    public static func resolve(avatar: String, name: String, role: String) -> AgentGlyph {
        if let own = parse(avatar) { return own }
        if let guessed = guess(name: name, role: role) { return guessed }
        switch avatar.trimmingCharacters(in: .whitespaces) {
        case "shape:wave", "🌊": return .compass
        case "shape:drop", "💧": return .magnifier
        case "shape:hexagon", "🛠️", "🛠": return .wrench
        case "shape:cloud", "☁️", "☁": return .moon
        case "shape:bloom", "🌸", "🌼": return .megaphone
        case "shape:leaf", "🍃", "🌿": return .nodes
        case "shape:pebble", "🪨": return .folder
        case "shape:squircle", "🤖": return .code
        default: return defaultGlyph
        }
    }

    /// Words that give an agent's job away, checked against the start of each word in its name, then its role.
    private static let clues: [(AgentGlyph, [String])] = [
        (.envelope, ["inbox", "email", "mail", "reply", "replies"]),
        (.megaphone, ["poster", "post", "linkedin", "social", "marketing", "announce"]),
        (.play, ["video", "demo", "record", "youtube", "film"]),
        (.nodes, ["architect", "diagram", "codebase"]),
        (.pulse, ["ops", "sre", "infra", "incident", "uptime", "monitor", "deploy", "release"]),
        (.magnifier, ["research", "scout", "search", "investigat"]),
        (.calendar, ["calendar", "schedul", "meeting", "agenda"]),
        (.pencil, ["writer", "write", "draft", "editor", "copy"]),
        (.book, ["reading", "reader", "papers", "summar"]),
        (.dollar, ["finance", "invoice", "budget", "expense", "account"]),
        (.folder, ["file", "folder", "desk", "download", "tidy"]),
        (.chart, ["report", "analytic", "metric", "dashboard", "review"]),
        (.shield, ["security", "secur", "audit", "compliance"]),
        (.code, ["code", "developer", "engineer"]),
        (.moon, ["overnight", "night", "after"]),
        (.compass, ["assistant", "pennant", "helper"]),
    ]

    static func guess(name: String, role: String) -> AgentGlyph? {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        for text in [name, role] {
            let ws = words(text)
            for (glyph, keys) in clues where ws.contains(where: { w in keys.contains { w.hasPrefix($0) } }) {
                return glyph
            }
        }
        return nil
    }
}

/// The "needs you" badge: a dot with a ring that swells out from it a few times when it appears, then rests.
/// (A ring that never stops redraws the window every frame for as long as an agent waits, which can be hours.)
struct PulsingDot: View {
    var color: Color
    var size: CGFloat
    var pulsing: Bool
    @State private var swell = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .stroke(color, lineWidth: max(1.5, size * 0.18))
                    .scaleEffect(swell ? 2.1 : 1)
                    .opacity(swell ? 0 : 0.8)
            }
            Circle().fill(color)
                .overlay(Circle().stroke(PennantTheme.windowBackground, lineWidth: max(1, size * 0.14)))
        }
        .frame(width: size, height: size)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.1).repeatCount(4, autoreverses: false)) { swell = true }
        }
    }
}

/// The still tile behind an agent's icon: the ribbon on violet for the lead, the job's symbol in its colour otherwise.
public struct AgentTile: View {
    var glyph: AgentGlyph
    var hex: String
    var size: CGFloat
    var isLead: Bool
    var needsYou: Bool
    var alarmed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(glyph: AgentGlyph, hex: String, size: CGFloat, isLead: Bool = false, needsYou: Bool = false, alarmed: Bool = false) {
        self.glyph = glyph; self.hex = hex; self.size = size; self.isLead = isLead; self.needsYou = needsYou; self.alarmed = alarmed
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(isLead ? PennantTheme.brandSoft : Color(hex: hex).opacity(0.16))
            if isLead {
                PennantMark(size: size * 0.96)
            } else {
                Image(systemName: glyph.symbol)
                    .font(.zoomed(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Color(hex: hex))
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            let badge = max(7, size * 0.26)
            if needsYou {
                PulsingDot(color: PennantTheme.color(for: AgentStatus.waitingForUser), size: badge, pulsing: !reduceMotion)
                    .offset(x: badge * 0.3, y: -badge * 0.3)
                    .transition(.scale.combined(with: .opacity))
            } else if alarmed {
                Circle().fill(PennantTheme.danger).frame(width: badge, height: badge)
                    .overlay(Circle().stroke(PennantTheme.windowBackground, lineWidth: max(1, size * 0.04)))
                    .offset(x: badge * 0.3, y: -badge * 0.3)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: needsYou)
        .accessibilityHidden(true)
    }
}

/// Pennant's own mark: a pennant abstracted into a ribbon caught in the wind, violet into blue. Used for the app icon
/// (Scripts/make-icon.py draws the same geometry), empty states, pairing and the about box.
public struct PennantMark: View {
    var size: CGFloat
    public init(size: CGFloat = 64) { self.size = size }
    public var body: some View {
        PennantShape()
            .fill(LinearGradient(colors: [Color(hex: "#8B5CF6"), Color(hex: "#2F80ED")], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The ribbon, in a unit square: a band that starts wide on the left and tapers to a point on the right, its centre
/// line one and a half waves of a sine. Keep in step with `ribbon_polygon` in Scripts/make-icon.py.
public struct PennantShape: Shape {
    public init() {}

    /// The outline as unit-square points: the upper edge left to right, then the lower edge back.
    public static func outline(steps: Int = 96) -> [CGPoint] {
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = 0.182 + 0.655 * t
            let y = 0.5 + 0.1335 * sin(t * .pi * 1.6 - 0.6)
            let half = 0.1456 * pow(1 - t, 0.8) + 0.0097
            top.append(CGPoint(x: x, y: y - half))
            bottom.append(CGPoint(x: x, y: y + half))
        }
        return top + bottom.reversed()
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        var path = Path()
        path.addLines(Self.outline().map { CGPoint(x: ox + $0.x * side, y: oy + $0.y * side) })
        path.closeSubpath()
        return path
    }
}
