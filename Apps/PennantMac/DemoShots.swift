#if DEBUG
import AppKit
import PennantClientKit
import PennantCore

/// Debug builds only: point the app at another host (the demo world from `pennant-host --seed-demo`) and, with a
/// folder, save the main window's screens as PNGs for the site and films. The app draws its own window, so no
/// screen-recording permission is needed and nothing else on the screen gets in.
///
///     PENNANT_DEBUG_HOST=127.0.0.1:7431 PENNANT_DEBUG_TOKEN_FILE=<demo root>/client-token \
///     PENNANT_DEBUG_SHOTS=<folder> Pennant.app/Contents/MacOS/Pennant
enum DemoLaunch {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The host to use instead of the one in settings, with its token.
    static var host: (endpoint: HostEndpoint, token: String)? {
        guard let address = env["PENNANT_DEBUG_HOST"], let file = env["PENNANT_DEBUG_TOKEN_FILE"],
              let token = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        let parts = address.split(separator: ":")
        let port = parts.count > 1 ? Int(parts[1]) ?? 7331 : 7331
        return (HostEndpoint(host: String(parts.first ?? "127.0.0.1"), port: port, name: "Demo host"), token)
    }

    static var shotsFolder: URL? {
        env["PENNANT_DEBUG_SHOTS"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// Window size in points; the PNGs are twice that on a Retina display.
    static var windowSize: CGSize {
        let parts = (env["PENNANT_DEBUG_SHOT_SIZE"] ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1440, height: 900)
    }

    /// Light and dark, or just one ("light" / "dark").
    static var appearances: [(suffix: String, appearance: NSAppearance.Name)] {
        switch env["PENNANT_DEBUG_SHOT_APPEARANCE"] {
        case "light": return [("", .aqua)]
        case "dark": return [("-dark", .darkAqua)]
        default: return [("", .aqua), ("-dark", .darkAqua)]
        }
    }

    /// Settings panes to photograph too (`PENNANT_DEBUG_SHOT_SETTINGS=pennant,models`), each a `SettingsView.Pane`.
    static var settingsPanes: [String] {
        (env["PENNANT_DEBUG_SHOT_SETTINGS"] ?? "").split(separator: ",").map(String.init).filter { SettingsView.Pane(rawValue: $0) != nil }
    }

    /// Sizes the main window and centres it.
    @MainActor static func prepareWindow() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let size = windowSize
        window.setContentSize(size)
        window.center()
    }

    /// A window as the app draws it (title bar and all), at the display's scale; the main window unless another is given.
    @MainActor static func capture(_ name: String, into folder: URL, window: NSWindow? = nil) {
        guard let window = window ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
#endif
