import PennantCore
import Foundation
import UniformTypeIdentifiers

/// Hands a file on the Mac to the user. The bytes are copied into the artifact store (kind `file`) and the
/// runtime posts an assistant message carrying a `.file` part in the conversation the tool ran in, so the
/// file shows up in the chat with Save, Open, and Preview. Not consequential (it only copies) and it never
/// touches the desktop lease.
public struct FileShareTool: Tool {
    /// Larger files are refused with advice to zip or split them.
    public static let maxBytes = 50 * 1024 * 1024

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "share_file",
            description: "Hand a file to the user: it appears in the conversation as an attachment they can save, open, or preview. Use it whenever you produce or find a file the user should have (a report, export, document, image, archive); naming a path is not enough for them to see it. Files up to 50 MB; zip or split larger ones. Credential files (private keys, certificates, .env files, keychains) are refused.",
            inputSchema: JSONSchema.object([
                "path": JSONSchema.string("Path of the file to share. Absolute, or relative to the working directory; `~` is expanded."),
                "caption": JSONSchema.string("One line about what the file is or why it matters, shown under its name."),
            ], required: ["path"]),
            isConsequential: false,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let path = PathResolver.resolve(try arguments.requireString("path"), base: context.config.workingDirectory)
        let caption = String((arguments.string("caption") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "")
        let resolved = try Self.checkShareable(path)
        let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let name = (path as NSString).lastPathComponent
        let mimeType = Self.mimeType(forFileName: name)
        let record = ArtifactRecord(kind: "file", mimeType: mimeType, byteCount: data.count, fileName: name, taskID: context.taskID, agentID: context.agentID, caption: caption)
        try await context.store.putArtifact(record, data: data)
        let ref = FileRef(artifactID: record.id, fileName: name, mimeType: mimeType, byteCount: data.count, caption: caption)
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("share_file needs a running task to post the file into.") }
        try await hooks.shareFile(context.taskID, ref)
        return .text(ToolCallID("pending"), name: spec.name, "Shared \(name) (\(Self.formatBytes(data.count))) with the user.")
    }

    // MARK: Rules

    /// Directories whose contents are never shared, relative to the home directory or absolute.
    static let refusedDirectories = ["~/Library/Keychains", "/Library/Keychains", "/System/Library/Keychains", "~/.ssh", "~/.gnupg", "~/.aws"]
    static let refusedExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "kdbx", "asc", "gpg"]
    static let refusedPrefixes = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".env"]
    static let refusedNames: Set<String> = [".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "credentials.json"]

    /// Validates the path and returns the symlink-resolved path to read. Throws a `ToolError` with the reason.
    static func checkShareable(_ path: String) throws -> String {
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        if let reason = credentialReason(path: path, name: name) { throw ToolError.denied(reason) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved != path, let reason = credentialReason(path: resolved, name: (resolved as NSString).lastPathComponent) { throw ToolError.denied(reason) }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDirectory) else { throw ToolError.failed("No file at \(path).") }
        if isDirectory.boolValue { throw ToolError.failed("\(path) is a directory. Zip it (for example `zip -r name.zip folder`) and share the archive.") }
        let attributes = try fm.attributesOfItem(atPath: resolved)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { throw ToolError.failed("\(path) is not a regular file.") }
        let size = (attributes[.size] as? Int) ?? 0
        if size > maxBytes {
            throw ToolError.failed("\(name) is \(formatBytes(size)), over the \(formatBytes(maxBytes)) limit. Zip it, or split it into parts (`split -b 45m`) and share those.")
        }
        guard fm.isReadableFile(atPath: resolved) else { throw ToolError.failed("Cannot read \(path).") }
        return resolved
    }

    static func credentialReason(path: String, name: String) -> String? {
        let lower = name.lowercased()
        let standardized = (path as NSString).standardizingPath
        for dir in refusedDirectories {
            let expanded = (dir as NSString).expandingTildeInPath
            if standardized == expanded || standardized.hasPrefix(expanded + "/") {
                return "Refused: \(name) is inside \(dir), which holds credentials. Keys, certificates, and keychains are never shared."
            }
        }
        let ext = (lower as NSString).pathExtension
        if refusedExtensions.contains(ext) || lower.contains(".keychain") || refusedNames.contains(lower) || refusedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return "Refused: \(name) looks like a credential file (private keys, certificates, .env files, and keychains are never shared). If the user needs its contents, tell them where it is instead."
        }
        return nil
    }

    // MARK: Helpers

    public static func mimeType(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType else { return "application/octet-stream" }
        return mime
    }

    /// Locale-independent size text used in tool results and in the model-facing `[shared file: …]` line.
    public static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// How a shared file reads to the model once its bytes are out of reach: never the contents.
    public static func modelLine(_ ref: FileRef) -> String {
        "[shared file: \(ref.fileName), \(formatBytes(ref.byteCount))]"
    }
}
