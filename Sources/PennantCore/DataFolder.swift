import Foundation

/// Where Pennant keeps its data on the Mac: `~/Library/Application Support/Pennant`. It was `…/Ayes` before the
/// second rename and `…/Cove` before the first; the first Pennant app or host to start moves the real folder here
/// and leaves the old names as links, so skills and scripts that still spell out an old path keep working.
public enum DataFolder {
    public static let name = "Pennant"
    /// Older names, newest first.
    public static let legacyNames = ["Ayes", "Cove"]

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    public static var url: URL { applicationSupport.appendingPathComponent(name, isDirectory: true) }

    /// Moves whichever old folder is still real (not a link) to `Pennant` once, and links every old name to it. Safe
    /// to call on every start and from the app and the host at once. A bare `Pennant` holding only what an app
    /// creates before the host runs (logs, a token) is set aside so the real data can take its place. Returns what
    /// it did, for the log, or nil when there was nothing to do.
    @discardableResult
    public static func migrateLegacy(in base: URL = applicationSupport) -> String? {
        let fm = FileManager.default
        let new = base.appendingPathComponent(name, isDirectory: true)
        func isLink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
        var notes: [String] = []
        // The newest old folder that is still a real directory holds the data.
        if let source = legacyNames.map({ base.appendingPathComponent($0, isDirectory: true) }).first(where: { fm.fileExists(atPath: $0.path) && !isLink($0) }) {
            var clear = true
            if fm.fileExists(atPath: new.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: new.path)) ?? []
                let disposable: Set<String> = ["logs", "client-token", ".DS_Store"]
                if Set(contents).isSubset(of: disposable) {
                    let aside = base.appendingPathComponent("\(name) (before migration \(Int(Date().timeIntervalSince1970)))", isDirectory: true)
                    do { try fm.moveItem(at: new, to: aside) } catch { return "Could not set aside the empty \(name) folder: \(error)" }
                } else {
                    clear = false
                    notes.append("Both \(source.lastPathComponent) and \(name) hold data; left both in place (using \(name)).")
                }
            }
            if clear {
                do {
                    try fm.moveItem(at: source, to: new)
                    notes.append("Moved the data folder from \(source.lastPathComponent) to \(name).")
                } catch {
                    return "Could not move the data folder from \(source.lastPathComponent) to \(name): \(error)"
                }
            }
        }
        // Every old name points straight here (a missing one is created; a link to an older name is redone).
        guard fm.fileExists(atPath: new.path) else { return notes.isEmpty ? nil : notes.joined(separator: " ") }
        for old in legacyNames {
            let url = base.appendingPathComponent(old, isDirectory: true)
            let target = try? fm.destinationOfSymbolicLink(atPath: url.path)
            if target == name { continue }
            if target != nil || !fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                if (try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: name)) != nil, target != nil || !notes.isEmpty {
                    notes.append("\(old) now links to \(name).")
                }
            }
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
