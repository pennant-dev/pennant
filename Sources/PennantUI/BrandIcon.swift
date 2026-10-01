import PennantCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A service's own mark in a soft circle of its brand colour, or the category-tinted SF Symbol when the entry has
/// none. Marks are template PNGs in the PennantUI asset catalog, fetched by `Scripts/fetch-brand-icons.swift`; the
/// catalog entry names the asset (`brandIcon`) and the colour (`brandColor`), and `BrandTint` pulls that colour
/// toward readable in each appearance.
struct BrandIcon: View {
    var symbol: String
    var category: String
    var brandIcon: String?
    var brandColor: String?
    var size: CGFloat = 36

    init(symbol: String, category: String, brandIcon: String? = nil, brandColor: String? = nil, size: CGFloat = 36) {
        self.symbol = symbol
        self.category = category
        self.brandIcon = brandIcon
        self.brandColor = brandColor
        self.size = size
    }

    init(entry: MCPCatalogEntry, size: CGFloat = 36) {
        // A catalog sent by an older host carries no brand fields; the built-in entry with the same id fills them in.
        let builtIn = MCPCatalog.entry(entry.id)
        self.init(symbol: entry.symbol, category: entry.category,
                  brandIcon: entry.brandIcon ?? builtIn?.brandIcon,
                  brandColor: entry.brandColor ?? builtIn?.brandColor,
                  size: size)
    }

    /// The mark of the catalog entry a server was made from; nil for custom servers.
    init?(server: MCPServerConfig, size: CGFloat = 36) {
        guard let id = server.catalogID, let entry = MCPCatalog.entry(id) else { return nil }
        self.init(entry: entry, size: size)
    }

    var body: some View {
        if let name = brandIcon, BrandIconStore.exists(name) {
            let tint = BrandTint.color(hex: brandColor) ?? MCPCategoryTint.color(for: category)
            ZStack {
                Circle().fill(tint.opacity(0.12))
                Image(name, bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
                    .frame(width: size * 0.5, height: size * 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            // No mark (Microsoft and LinkedIn are not in Simple Icons): the symbol in the brand colour, when known.
            InspectorTintedSymbol(symbol: symbol, tint: BrandTint.color(hex: brandColor) ?? MCPCategoryTint.color(for: category), size: size)
        }
    }
}

/// Which brand marks the PennantUI bundle actually holds, so a catalog entry naming a missing asset falls back to its
/// symbol instead of drawing nothing.
@MainActor
enum BrandIconStore {
    private static var cache: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let hit = cache[name] { return hit }
        #if canImport(AppKit)
        let found = Bundle.module.image(forResource: name) != nil
        #else
        let found = UIImage(named: name, in: .module, compatibleWith: nil) != nil
        #endif
        cache[name] = found
        return found
    }
}

/// The colour a mark is drawn in. Brand colours are picked for white or black backgrounds, not for a 12% tint of
/// themselves on a card in either appearance, so: neutral marks (GitHub, Notion, Square) use the ink colour and
/// invert in dark mode the way those brands' own dark-mode marks do; bright colours (Hugging Face yellow,
/// Intercom cyan) are darkened for light mode; deep ones (PayPal, Sentry, SQLite) are brightened for dark mode.
/// Adjustments happen in linear light and keep the hue.
enum BrandTint {
    /// The adaptive colour for a "#RRGGBB" brand hex; nil when the hex does not parse.
    static func color(hex: String?) -> Color? {
        guard let hex, let rgb = parse(hex) else { return nil }
        if isNeutral(rgb) { return PennantTheme.ink }
        let light = adjusted(rgb, forDarkBackground: false)
        let dark = adjusted(rgb, forDarkBackground: true)
        return Color.adaptive(light: Color(red: light.r, green: light.g, blue: light.b), dark: Color(red: dark.r, green: dark.g, blue: dark.b))
    }

    struct RGB: Equatable { var r: Double; var g: Double; var b: Double }

    /// Highest relative luminance a mark may have on a light card, and the lowest on a dark one.
    static let lightCeiling = 0.35
    static let darkFloor = 0.18
    /// Below this spread between channels a colour is a grey and reads as ink.
    static let neutralChroma = 0.08

    static func parse(_ hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    static func isNeutral(_ c: RGB) -> Bool {
        max(c.r, c.g, c.b) - min(c.r, c.g, c.b) < neutralChroma
    }

    /// WCAG relative luminance of an sRGB colour.
    static func luminance(_ c: RGB) -> Double {
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// The colour scaled in linear light so its luminance lands inside the readable band for the background.
    static func adjusted(_ c: RGB, forDarkBackground dark: Bool) -> RGB {
        let l = luminance(c)
        var lin = (r: linear(c.r), g: linear(c.g), b: linear(c.b))
        if !dark, l > lightCeiling {
            let k = lightCeiling / l
            lin = (lin.r * k, lin.g * k, lin.b * k)
        } else if dark, l < darkFloor, l > 0 {
            // Scale up first (keeps the hue vivid), then mix toward white for whatever the clamp at 1 lost.
            let k = darkFloor / l
            lin = (min(lin.r * k, 1), min(lin.g * k, 1), min(lin.b * k, 1))
            let reached = 0.2126 * lin.r + 0.7152 * lin.g + 0.0722 * lin.b
            if reached < darkFloor {
                let t = (darkFloor - reached) / (1 - reached)
                lin = (lin.r + t * (1 - lin.r), lin.g + t * (1 - lin.g), lin.b + t * (1 - lin.b))
            }
        } else if dark, l == 0 {
            return RGB(r: 0.6, g: 0.6, b: 0.6)
        } else {
            return c
        }
        return RGB(r: gamma(lin.r), g: gamma(lin.g), b: gamma(lin.b))
    }

    private static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
