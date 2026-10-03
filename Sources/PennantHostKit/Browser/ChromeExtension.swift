import CryptoKit
import Foundation

/// Pennant's Chrome extension on disk. Chrome loads it from the data folder rather than from Pennant.app, so moving or
/// updating the app never pulls it out from under Chrome; each copy is stamped with a fingerprint of its files, which
/// tells the host when the extension Chrome is running is out of date.
enum ChromeExtension {
    static let folderName = "chrome-extension"
    /// The line in background.js that the copy's stamp replaces.
    static let buildLine = "const BUILD = 'source';"

    /// The extension inside Pennant.app, or the repository's copy for a development build.
    static func bundled(from start: URL = Bundle.main.bundleURL) -> URL? {
        let fm = FileManager.default
        var url = start
        for _ in 0 ..< 8 {
            for candidate in [url.appendingPathComponent("Contents/Resources/PennantChrome"), url.appendingPathComponent("Extensions/PennantChrome")]
            where fm.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Changes with any edit to the extension's files.
    static func fingerprint(of folder: URL) throws -> String {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        var files: [(String, URL)] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let relative = String(url.path.dropFirst(folder.path.count))
            if !url.lastPathComponent.hasPrefix(".") { files.append((relative, url)) }
        }
        var hash = SHA256()
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            hash.update(data: Data(relative.utf8))
            hash.update(data: try Data(contentsOf: url))
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Puts the extension in `root`'s folder for it, stamped with its build, unless that copy is already current.
    static func install(from source: URL, into root: URL) throws -> (folder: URL, build: String) {
        let fm = FileManager.default
        let build = try fingerprint(of: source)
        let target = root.appendingPathComponent(folderName, isDirectory: true)
        if installedBuild(at: target) == build { return (target, build) }
        let staging = root.appendingPathComponent(folderName + "-new", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: staging)
        let script = staging.appendingPathComponent("background.js")
        let text = try String(contentsOf: script, encoding: .utf8)
        guard text.contains(buildLine) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: script.path]) }
        try text.replacingOccurrences(of: buildLine, with: stamp(build)).write(to: script, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
        return (target, build)
    }

    /// The build a copy was stamped with, read back from its background.js.
    static func installedBuild(at folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("background.js"), encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("const BUILD = '") }) else { return nil }
        return line.split(separator: "'").dropFirst().first.map(String.init)
    }

    private static func stamp(_ build: String) -> String { "const BUILD = '\(build)';" }
}
