#!/usr/bin/env swift
// Fetches the brand marks the MCP marketplace shows and writes them into the PennantUI asset catalog.
//
//   swift Scripts/fetch-brand-icons.swift [--force]
//
// The marks come from Simple Icons (https://simpleicons.org), a CC0-licensed set of monochrome SVGs. The marks
// themselves remain their owners' trademarks; Pennant shows them only to say which service a card connects to.
//
// For each (slug, asset) pair below the script downloads https://cdn.simpleicons.org/<slug>, reads the brand
// colour (from the Simple Icons data file when it is reachable, else from the SVG's own fill attribute, else from
// the table at the bottom), rasterises the glyph in black at 128, 256, and 384 px (1x/2x/3x of a 128-pt canvas),
// and writes Sources/PennantUI/Resources/BrandIcons.xcassets/<asset>.imageset with a template-rendering Contents.json.
// The view tints the template with the brand colour at runtime, so the PNGs carry only the silhouette.
//
// Idempotent: an imageset that already holds its three PNGs is skipped unless --force is given. The script prints
// what it fetched, skipped, and could not find, then a slug → hex table to paste into MCPCatalog.swift.

import AppKit
import Foundation

// MARK: - What to fetch

/// Simple Icons slug → asset name. Keep the asset name a lowercase slug; MCPCatalogTests checks that.
let marks: [(slug: String, asset: String)] = [
    ("asana", "asana"),
    ("atlassian", "atlassian"),
    ("brave", "brave"),
    ("cloudflareworkers", "cloudflareworkers"),
    ("figma", "figma"),
    ("git", "git"),
    ("github", "github"),
    ("hubspot", "hubspot"),
    ("huggingface", "huggingface"),
    ("intercom", "intercom"),
    ("linear", "linear"),
    ("neon", "neon"),
    ("notion", "notion"),
    ("paypal", "paypal"),
    ("postgresql", "postgresql"),
    ("sentry", "sentry"),
    ("sqlite", "sqlite"),
    ("square", "square"),
    ("stripe", "stripe"),
    ("supabase", "supabase"),
    ("webflow", "webflow"),
    ("zapier", "zapier"),
    ("reddit", "reddit"),
]

/// Brand colours as of Simple Icons 16.x, used only when neither the data file nor the SVG gives one.
let fallbackHex: [String: String] = [
    "asana": "F06A6A", "atlassian": "0052CC", "brave": "FB542B", "cloudflareworkers": "F38020", "figma": "F24E1E",
    "git": "F03C2E", "github": "181717", "hubspot": "FF7A59", "huggingface": "FFD21E", "intercom": "6AFDEF",
    "linear": "5E6AD2", "neon": "34D59A", "notion": "000000", "paypal": "002991", "postgresql": "4169E1",
    "sentry": "362D59", "sqlite": "003B57", "square": "3E4348", "stripe": "635BFF", "supabase": "3FCF8E",
    "webflow": "146EF5", "zapier": "FF4F00",
]

let scales = [1, 2, 3]
let canvasPoints = 128
let force = CommandLine.arguments.contains("--force")

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let catalogURL = repoRoot.appendingPathComponent("Sources/PennantUI/Resources/BrandIcons.xcassets")

// MARK: - HTTP

final class Box: @unchecked Sendable {
    var data: Data?
    var status = 0
    var error: Error?
}

/// One blocking GET; returns the body and status, or nil when the request itself failed.
func get(_ url: URL) -> (data: Data, status: Int)? {
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("pennant-fetch-brand-icons", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, response, error in
        box.data = data
        box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        box.error = error
        done.signal()
    }.resume()
    done.wait()
    if let error = box.error { print("  network: \(url.lastPathComponent): \(error.localizedDescription)"); return nil }
    guard let data = box.data else { return nil }
    return (data, box.status)
}

// MARK: - Colours

/// slug → hex from the Simple Icons data file, when one of its mirrors answers.
func loadDataFileColours() -> [String: String] {
    let mirrors = [
        "https://cdn.jsdelivr.net/npm/simple-icons@latest/data/simple-icons.json",
        "https://unpkg.com/simple-icons@latest/data/simple-icons.json",
        "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/data/simple-icons.json",
    ]
    for mirror in mirrors {
        guard let url = URL(string: mirror), let (data, status) = get(url), status == 200 else { continue }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { continue }
        // Older releases wrap the list in {"icons": [...]}; newer ones are a bare array.
        let icons = (json as? [String: Any])?["icons"] as? [[String: Any]] ?? json as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for icon in icons {
            guard let title = icon["title"] as? String, let hex = icon["hex"] as? String else { continue }
            let slug = (icon["slug"] as? String) ?? slugify(title)
            out[slug] = hex.uppercased()
        }
        if !out.isEmpty {
            print("colours: \(out.count) entries from \(mirror)")
            return out
        }
    }
    print("colours: data file unreachable; using the SVG fill or the built-in table")
    return [:]
}

/// Simple Icons' own slug rule, for data files that carry no explicit slug.
func slugify(_ title: String) -> String {
    let replacements: [(String, String)] = [("+", "plus"), (".", "dot"), ("&", "and"), ("đ", "d"), ("ħ", "h"), ("ı", "i"), ("ĸ", "k"), ("ŀ", "l"), ("ł", "l"), ("ß", "ss"), ("ŧ", "t")]
    var s = title.lowercased()
    for (from, to) in replacements { s = s.replacingOccurrences(of: from, with: to) }
    s = s.folding(options: .diacriticInsensitive, locale: nil)
    return s.filter { $0.isLetter || $0.isNumber }
}

/// The fill="#RRGGBB" the CDN puts on the root element.
func fillHex(in svg: String) -> String? {
    guard let range = svg.range(of: ##"fill="#([0-9A-Fa-f]{6})""##, options: .regularExpression) else { return nil }
    let match = svg[range]
    return String(match.dropFirst(7).dropLast(1)).uppercased()
}

// MARK: - Rendering

/// Rasterises the SVG in black on a transparent canvas of the given pixel size.
func renderPNG(svg: Data, pixels: Int) -> Data? {
    guard let image = NSImage(data: svg) else { return nil }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill()
    rect.fill()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func contentsJSON(asset: String) -> String {
    let images = scales.map { scale in
        let file = scale == 1 ? "\(asset).png" : "\(asset)@\(scale)x.png"
        return "    { \"filename\" : \"\(file)\", \"idiom\" : \"universal\", \"scale\" : \"\(scale)x\" }"
    }.joined(separator: ",\n")
    return """
    {
      "images" : [
    \(images)
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "template-rendering-intent" : "template" }
    }

    """
}

func pngNames(asset: String) -> [String] { scales.map { $0 == 1 ? "\(asset).png" : "\(asset)@\($0)x.png" } }

func imagesetIsComplete(_ dir: URL, asset: String) -> Bool {
    let fm = FileManager.default
    return (pngNames(asset: asset) + ["Contents.json"]).allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(at: catalogURL, withIntermediateDirectories: true)
let rootContents = catalogURL.appendingPathComponent("Contents.json")
if !fm.fileExists(atPath: rootContents.path) {
    try "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n".write(to: rootContents, atomically: true, encoding: .utf8)
}

let dataColours = loadDataFileColours()
var fetched: [String] = [], skipped: [String] = [], missing: [String] = [], failed: [String] = []
var table: [(asset: String, hex: String, source: String)] = []

for mark in marks {
    let dir = catalogURL.appendingPathComponent("\(mark.asset).imageset")
    var hex = dataColours[mark.slug]
    var source = hex == nil ? "" : "data file"

    if !force, imagesetIsComplete(dir, asset: mark.asset) {
        skipped.append(mark.asset)
        if hex == nil, let fallback = fallbackHex[mark.slug] { hex = fallback; source = "built-in table" }
        if let hex { table.append((mark.asset, hex, source)) }
        print("skip   \(mark.asset) (present)")
        continue
    }

    guard let url = URL(string: "https://cdn.simpleicons.org/\(mark.slug)"), let (data, status) = get(url) else {
        failed.append(mark.asset); print("fail   \(mark.asset): request failed"); continue
    }
    guard status == 200, var svg = String(data: data, encoding: .utf8), svg.contains("<svg") else {
        missing.append(mark.asset); print("miss   \(mark.asset): HTTP \(status) for \(mark.slug)"); continue
    }
    if hex == nil, let fromSVG = fillHex(in: svg) { hex = fromSVG; source = "svg fill" }
    if hex == nil, let fallback = fallbackHex[mark.slug] { hex = fallback; source = "built-in table" }

    // The PNG is a template: only the silhouette matters, so draw it black regardless of the brand fill.
    svg = svg.replacingOccurrences(of: ##"fill="#[0-9A-Fa-f]{6}""##, with: "fill=\"#000000\"", options: .regularExpression)
    guard let svgData = svg.data(using: .utf8) else { failed.append(mark.asset); continue }

    var rendered: [(String, Data)] = []
    for (i, scale) in scales.enumerated() {
        guard let png = renderPNG(svg: svgData, pixels: canvasPoints * scale) else { break }
        rendered.append((pngNames(asset: mark.asset)[i], png))
    }
    guard rendered.count == scales.count else { failed.append(mark.asset); print("fail   \(mark.asset): could not rasterise"); continue }

    do {
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, png) in rendered { try png.write(to: dir.appendingPathComponent(name)) }
        try contentsJSON(asset: mark.asset).write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    } catch {
        failed.append(mark.asset); print("fail   \(mark.asset): \(error.localizedDescription)"); continue
    }
    fetched.append(mark.asset)
    if let hex { table.append((mark.asset, hex, source)) }
    let bytes = rendered.reduce(0) { $0 + $1.1.count }
    print("fetch  \(mark.asset) ← \(mark.slug)  #\(hex ?? "??????") (\(source))  \(bytes) bytes")
}

print("")
print("fetched \(fetched.count), skipped \(skipped.count), missing \(missing.count), failed \(failed.count)")
if !missing.isEmpty { print("missing: \(missing.joined(separator: ", ")) — these entries keep their SF Symbol") }
if !failed.isEmpty { print("failed: \(failed.joined(separator: ", "))") }
print("")
print("brandIcon / brandColor for MCPCatalog.swift:")
for row in table.sorted(by: { $0.asset < $1.asset }) {
    print("  brandIcon: \"\(row.asset)\", brandColor: \"#\(row.hex)\",  // \(row.source)")
}
exit(failed.isEmpty ? 0 : 1)
