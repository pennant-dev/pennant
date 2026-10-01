import PennantCore
import Foundation

/// Where the host keeps its data. Everything lives under Application Support so backup is one directory.
public struct HostPaths: Sendable {
    public let root: URL
    public var databaseURL: URL { root.appendingPathComponent(Self.databaseName) }
    static let databaseName = "pennant.sqlite"
    static let sealedSecretsName = "secrets.pennant"

    /// Files named before Pennant had its name, and their names now: the database with its journal files, and an
    /// export's sealed secrets.
    static let renamedFiles = ["cove.sqlite": databaseName, "cove.sqlite-wal": databaseName + "-wal", "cove.sqlite-shm": databaseName + "-shm",
                               "secrets.cove": sealedSecretsName]

    /// Gives those files their names now in `folder` (a data folder, or an import being staged), unless a file
    /// already has the new name.
    static func adoptRenamedFiles(in folder: URL) {
        let fm = FileManager.default
        for (old, new) in renamedFiles {
            let from = folder.appendingPathComponent(old), to = folder.appendingPathComponent(new)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
        }
    }
    public var artifactsURL: URL { root.appendingPathComponent("artifacts", isDirectory: true) }
    public var configURL: URL { root.appendingPathComponent("config.json") }
    public var logURL: URL { root.appendingPathComponent("logs/host.log") }
    public var skillsURL: URL { root.appendingPathComponent("skills", isDirectory: true) }

    public init(root: URL) {
        self.root = root
    }

    public static func `default`() -> HostPaths {
        HostPaths(root: DataFolder.url)
    }

    public static func temporary(name: String = UUID().uuidString) -> HostPaths {
        HostPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("pennant-\(name)", isDirectory: true))
    }

    public func ensureDirectories() throws {
        for url in [root, artifactsURL, skillsURL, logURL.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

public enum ConfigLoader {
    public static func load(from url: URL) -> HostConfig {
        guard let data = try? Data(contentsOf: url), var config = try? JSONCodec.decode(HostConfig.self, from: data) else {
            return HostConfig()
        }
        // Configs written before limits paused instead of failed still carry the old, tight allowance.
        if config.defaultBudget == .legacy { config.defaultBudget = TaskBudget() }
        return config
    }

    public static func save(_ config: HostConfig, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCodec.prettyEncoder.encode(config).write(to: url, options: .atomic)
    }
}
