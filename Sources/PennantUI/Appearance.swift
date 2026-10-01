import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Light, dark, or whatever the device uses. Each app keeps its own choice (the Mac and the phone can differ).
public enum PennantAppearance: String, CaseIterable, Hashable, Sendable {
    case system, light, dark

    public static let storageKey = "pennant.appearance"

    public var title: String {
        switch self { case .system: return "Match system"; case .light: return "Light"; case .dark: return "Dark" }
    }

    public var symbol: String {
        switch self { case .system: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .dark: return "moon" }
    }

    public var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }

    #if os(macOS)
    /// Sets the whole app's appearance, so menus, sheets, the menu bar extra and AppKit views follow too.
    @MainActor public func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// Applies the stored appearance to a window's content and follows changes to it.
struct PennantAppearanceModifier: ViewModifier {
    @AppStorage(PennantAppearance.storageKey) private var stored = PennantAppearance.system.rawValue
    private var appearance: PennantAppearance { PennantAppearance(rawValue: stored) ?? .system }

    func body(content: Content) -> some View {
        #if os(macOS)
        // The app-wide NSAppearance does the work on the Mac; preferredColorScheme there would pin the window even
        // when "Match system" is chosen.
        content
            .onAppear { appearance.apply() }
            .onChange(of: stored) { appearance.apply() }
        #else
        content.preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

public extension View {
    /// Light, dark, or the system's, as chosen in Settings › Appearance.
    func pennantAppearance() -> some View { modifier(PennantAppearanceModifier()) }
}

/// The Appearance choice, for either app's settings.
public struct AppearancePicker: View {
    @AppStorage(PennantAppearance.storageKey) private var stored = PennantAppearance.system.rawValue
    public init() {}
    public var body: some View {
        ChipRow(selection: Binding(get: { PennantAppearance(rawValue: stored) ?? .system }, set: { stored = $0.rawValue }),
                options: PennantAppearance.allCases.map { ChoiceOption($0, title: $0.title, symbol: $0.symbol) })
    }
}
