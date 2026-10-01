import Observation
import SwiftUI

/// The text zoom on the Mac (View › Zoom In, Zoom Out, Actual Size: ⌘+, ⌘−, ⌘0), remembered across launches. macOS
/// gives SwiftUI's text styles no size setting, so every font goes through `Font.zoomed`, which reads this; reading
/// it while a view draws is what redraws the view when the zoom changes. The iPhone stays at 100% and keeps Dynamic
/// Type.
@MainActor
@Observable
public final class PennantZoom {
    public static let shared = PennantZoom()
    public static let steps: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.5]
    private static let storageKey = "pennant.zoom"

    public private(set) var factor: CGFloat

    private init() {
        #if os(macOS)
        let stored = CGFloat(UserDefaults.standard.double(forKey: Self.storageKey))
        factor = Self.steps.contains(stored) ? stored : 1
        #else
        factor = 1
        #endif
    }

    public var canZoomIn: Bool { factor < Self.steps.last! }
    public var canZoomOut: Bool { factor > Self.steps.first! }
    public var isActualSize: Bool { factor == 1 }

    public func zoomIn() { set(Self.steps.first { $0 > factor } ?? factor) }
    public func zoomOut() { set(Self.steps.last { $0 < factor } ?? factor) }
    public func actualSize() { set(1) }

    private func set(_ new: CGFloat) {
        guard new != factor else { return }
        factor = new
        UserDefaults.standard.set(Double(new), forKey: Self.storageKey)
    }
}

public extension Font {
    /// A text style at the app's zoom: the style itself at 100%, else its macOS size times the zoom.
    @MainActor static func zoomed(_ style: TextStyle, design: Design = .default) -> Font {
        let factor = PennantZoom.shared.factor
        guard factor != 1 else { return .system(style, design: design) }
        return .system(size: style.macSize * factor, weight: style == .headline ? .bold : .regular, design: design)
    }

    /// A fixed size at the app's zoom.
    @MainActor static func zoomed(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        .system(size: size * PennantZoom.shared.factor, weight: weight, design: design)
    }
}

extension Font.TextStyle {
    /// The point size macOS gives each text style.
    var macSize: CGFloat {
        switch self {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
    }
}
