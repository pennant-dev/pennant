import PennantCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Small helpers shared by the shell views (roster, conversation, composer, status bars).
// Everything here is internal: the public surface stays on the views themselves.

/// Status colours for the shell. These mirror the state palette in `PennantTheme` so a chip on a card
/// agrees with the dot in the roster.
enum ShellPalette {
    static let danger = Color(hex: "#E5484D")
    static let warning = Color(hex: "#F0762B")
    static let caution = Color(hex: "#F0A93B")
    static let info = Color(hex: "#2F80ED")
    static let violet = Color(hex: "#8B5CF6")
    static let teal = Color(hex: "#1FA79E")
}

/// Timestamp separators inside a conversation: "9:41 AM" today, "Yesterday, 9:41 AM",
/// "Tuesday, 9:41 AM" this week, otherwise "Sep 12, 9:41 AM".
func messageTimestamp(_ date: Date) -> String {
    let cal = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(date) { return time }
    if cal.isDateInYesterday(date) { return "Yesterday, \(time)" }
    if let week = cal.date(byAdding: .day, value: -6, to: Date()), date > week {
        return "\(date.formatted(.dateTime.weekday(.wide))), \(time)"
    }
    return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
}

/// Three quiet dots that breathe while the assistant is still writing.
struct TypingDots: View {
    var body: some View {
        // The system spinner rather than three breathing dots: those redraw the window every frame for as long as
        // the model thinks.
        ProgressView().controlSize(.small)
            .accessibilityLabel("Writing")
    }
}

/// A hairline in the theme's divider colour. Use instead of `Divider()` so the line matches the sidebar and cards.
struct ShellHairline: View {
    var body: some View {
        Rectangle().fill(PennantTheme.divider).frame(height: 1)
    }
}

// MARK: - Tool activity helpers

extension ShellPalette {
    /// Reserved for MCP tools, so third-party activity reads apart from Pennant's own.
    static let rose = Color(hex: "#EC4899")
}

/// "340 ms", "1.2 s", "1 min 12 s": how long a tool ran.
func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 1 { return "\(max(1, Int((seconds * 1000).rounded()))) ms" }
    if seconds < 60 { return String(format: "%.1f s", seconds) }
    let m = Int(seconds) / 60, s = Int(seconds) % 60
    return s == 0 ? "\(m) min" : "\(m) min \(s) s"
}

/// The home directory as "~", so paths read the way people type them.
func abbreviatePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// The last path component, or the path itself when it has none.
func fileName(of path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    let name = (trimmed as NSString).lastPathComponent
    return name.isEmpty ? abbreviatePath(path) : name
}

/// One line, at most `limit` characters, with an ellipsis when cut. Newlines collapse to spaces.
func truncatedLine(_ text: String, limit: Int) -> String {
    let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    guard flat.count > limit else { return flat }
    return String(flat.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
}

/// "cmd+s" → "⌘S", "shift+enter" → "⇧↩", "ctrl+alt+delete" → "⌃⌥⌫". Unknown tokens are capitalised.
func keyGlyphs(_ combo: String) -> String {
    let glyphs: [String: String] = [
        "cmd": "⌘", "command": "⌘", "meta": "⌘", "super": "⌘",
        "shift": "⇧", "alt": "⌥", "option": "⌥", "opt": "⌥",
        "ctrl": "⌃", "control": "⌃",
        "enter": "↩", "return": "↩", "tab": "⇥", "esc": "⎋", "escape": "⎋",
        "delete": "⌫", "backspace": "⌫", "forwarddelete": "⌦",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "arrowup": "↑", "arrowdown": "↓", "arrowleft": "←", "arrowright": "→",
        "space": "Space", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]
    let tokens = combo.split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return combo }
    return tokens.map { token in
        let key = token.lowercased()
        if let g = glyphs[key] { return g }
        return token.count == 1 ? token.uppercased() : token.prefix(1).uppercased() + token.dropFirst()
    }.joined()
}

/// Copies text for the user, on either platform.
func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
