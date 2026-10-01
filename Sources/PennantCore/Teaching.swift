import Foundation

// Teach mode: the user demonstrates a procedure while the host records what they do (apps, clicks on named
// controls, typing, shortcuts, notes), not video. The trace is then drafted into a provisional skill.

/// The control under a click or the field being typed into, as Accessibility describes it.
public struct TeachingElement: Hashable, Codable, Sendable {
    /// AXRole, e.g. "AXButton", "AXMenuItem", "AXTextField".
    public var role: String
    /// The role in words, e.g. "button", "menu item".
    public var roleDescription: String
    /// The best human label found: title, description, help, or a nearby parent's title.
    public var label: String
    /// AXIdentifier when the app sets one; the most stable handle there is.
    public var identifier: String?
    /// A short value (a checkbox state, a popup's selection). Never the contents of text fields.
    public var value: String?

    public init(role: String, roleDescription: String = "", label: String = "", identifier: String? = nil, value: String? = nil) {
        self.role = role
        self.roleDescription = roleDescription
        self.label = label
        self.identifier = identifier
        self.value = value
    }

    /// Roles that say nothing about what was clicked when they have no label.
    public static let genericRoles: Set<String> = ["AXGroup", "AXUnknown", "AXWebArea", "AXImage", "AXStaticText", "AXLayoutArea", "AXLayoutItem", "AXScrollArea", "AXGenericElement", "AXSplitGroup", ""]

    /// "button “Record”", "menu item “New Recording”", or the role alone when nothing names it.
    public var phrase: String {
        let kind = roleDescription.isEmpty ? role.replacingOccurrences(of: "AX", with: "").lowercased() : roleDescription
        return label.isEmpty ? kind : "\(kind) “\(label)”"
    }
}

public enum TeachingEventKind: Hashable, Codable, Sendable {
    /// An app came to the front.
    case appActivated(app: String, bundleID: String?)
    /// The focused window of the front app changed.
    case window(app: String, title: String)
    /// A click. `x`/`y` are the point's position inside the window as fractions (0…1), for controls that
    /// Accessibility cannot name.
    case click(button: String, count: Int, element: TeachingElement?, app: String, window: String?, x: Double?, y: Double?)
    /// Text typed into one field, merged until focus or app changes.
    case typed(text: String, field: TeachingElement?, app: String)
    /// Typing into a password field; the text is never recorded.
    case secureTyped(app: String)
    /// A key combination with modifiers, e.g. "⌘⇧5".
    case shortcut(keys: String, app: String)
    /// A named key without modifiers: Return, Tab, Escape, Delete, arrows.
    case key(name: String, app: String)
    /// Scrolling, merged per app and direction.
    case scroll(direction: String, app: String)
    /// Something the user typed into the teaching panel to explain a step.
    case note(String)
}

public struct TeachingEvent: Hashable, Codable, Sendable, Identifiable {
    public var id: Int
    public var at: Date
    public var kind: TeachingEventKind

    public init(id: Int, at: Date = Date(), kind: TeachingEventKind) {
        self.id = id
        self.at = at
        self.kind = kind
    }

    /// One line in plain words, for the review list and the drafting prompt.
    public var summary: String {
        switch kind {
        case .appActivated(let app, _):
            return "Switched to \(app)"
        case .window(let app, let title):
            return "\(app) window “\(title)” came forward"
        case .click(let button, let count, let element, let app, let window, let x, let y):
            let verb = (count >= 2 ? "Double-clicked" : (button == "right" ? "Right-clicked" : "Clicked"))
            var target = element?.phrase ?? "an unlabelled spot"
            // A position helps only where nothing names the target; "close button" is clear on its own.
            if element == nil || (element?.label.isEmpty == true && TeachingElement.genericRoles.contains(element?.role ?? "")), let x, let y {
                target += String(format: " at %.0f%% across, %.0f%% down the window", x * 100, y * 100)
            }
            let place = window.map { " (window “\($0)”)" } ?? ""
            return "\(verb) \(target) in \(app)\(place)"
        case .typed(let text, let field, let app):
            let into = field.map { " into \($0.phrase)" } ?? ""
            return "Typed “\(text)”\(into) in \(app)"
        case .secureTyped(let app):
            return "Typed a password in \(app) (not recorded)"
        case .shortcut(let keys, let app):
            return "Pressed \(keys) in \(app)"
        case .key(let name, let app):
            return "Pressed \(name) in \(app)"
        case .scroll(let direction, let app):
            return "Scrolled \(direction) in \(app)"
        case .note(let text):
            return "Note: \(text)"
        }
    }

    public var isNote: Bool { if case .note = kind { return true } else { return false } }
}

/// One demonstration: what the user said they would show, and the steps recorded while they did.
public struct TeachingSession: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var goal: String
    public var startedAt: Date
    public var endedAt: Date?
    public var events: [TeachingEvent]
    public var isRecording: Bool
    /// Set while the host drafts the skill, and once it has.
    public var isDrafting: Bool
    public var draftSkillID: SkillID?
    public var draftError: String?
    /// Set when recording could not start or had to fall back (no Accessibility or Input Monitoring).
    public var warning: String?

    public init(id: String = UUID().uuidString, goal: String, startedAt: Date = Date(), endedAt: Date? = nil, events: [TeachingEvent] = [], isRecording: Bool = true, isDrafting: Bool = false, draftSkillID: SkillID? = nil, draftError: String? = nil, warning: String? = nil) {
        self.id = id
        self.goal = goal
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.events = events
        self.isRecording = isRecording
        self.isDrafting = isDrafting
        self.draftSkillID = draftSkillID
        self.draftError = draftError
        self.warning = warning
    }

    /// The demonstration as numbered lines with seconds since the start, as the drafting prompt and the
    /// skill's reference section show it.
    public var transcript: String {
        events.enumerated().map { index, event in
            let t = Int(event.at.timeIntervalSince(startedAt).rounded())
            return "\(index + 1). [+\(t)s] \(event.summary)"
        }.joined(separator: "\n")
    }
}
