import PennantClientKit
import PennantCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// A file the agent shared into the conversation (or the user attached): an icon chosen by type, or a
/// thumbnail for images, the name, size, and caption, then Save / Open / Preview. The bytes are fetched
/// lazily on first appearance and cached per artifact in `ArtifactCache`.
///
/// macOS: Save opens `NSSavePanel` with the name pre-filled; Open writes a per-artifact temporary copy under
/// `<tmp>/Pennant/<artifact id>/<name>` once and hands it to the default app. iOS: Save presents the share sheet
/// (`ShareLink`) on that temporary copy, which includes Save to Files. Text-like files under 200 KB get a
/// Preview disclosure showing the first 60 lines monospaced.
public struct FileAttachmentView: View {
    @Environment(\.hostSession) private var session
    var ref: FileRef
    @State private var previewOpen = false
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    #if !os(macOS)
    @State private var shareURL: URL?
    #endif

    public init(ref: FileRef) { self.ref = ref }

    private static let previewByteLimit = 200 * 1024
    private static let previewLineLimit = 60

    private var state: ArtifactCache.FileState? { ArtifactCache.shared.file(for: ref.artifactID) }
    private var data: Data? { ArtifactCache.shared.fileData(for: ref.artifactID) }
    private var kind: FileKind { FileKind(ref) }
    private var canPreview: Bool { kind.previewable && ref.byteCount <= Self.previewByteLimit }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(ref.fileName)
                        .font(.zoomed(.callout).weight(.medium))
                        .foregroundStyle(PennantTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Chip(kind.label(for: ref))
                        Text(sizeText).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
                    }
                    if !ref.caption.isEmpty {
                        Text(ref.caption)
                            .font(.zoomed(.caption))
                            .foregroundStyle(PennantTheme.inkSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            actions
            if previewOpen { preview }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
        .onAppear { ArtifactCache.shared.loadFile(ref.artifactID, using: session) }
        #if !os(macOS)
        .onChange(of: data != nil, initial: true) { _, loaded in shareURL = loaded ? temporaryCopy() : nil }
        #endif
    }

    // MARK: Pieces

    @ViewBuilder private var icon: some View {
        if kind == .image, let data, let image = PlatformImage(data: data) {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous).stroke(PennantTheme.border))
        } else {
            Image(systemName: kind.symbol)
                .font(.zoomed(.title2))
                .foregroundStyle(PennantTheme.inkSecondary)
                .frame(width: 44, height: 44)
                .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            #if os(macOS)
            Button("Save…") { save() }
                .buttonStyle(.pennantCompact)
                .fixedSize()
                .disabled(data == nil)
            Button("Open") { open() }
                .buttonStyle(.pennantGhostCompact)
                .fixedSize()
                .disabled(data == nil)
            #else
            if let shareURL {
                ShareLink(item: shareURL) { Text("Save…") }
                    .buttonStyle(.pennantCompact)
                    .fixedSize()
            } else {
                Button("Save…") {}
                    .buttonStyle(.pennantCompact)
                    .fixedSize()
                    .disabled(true)
            }
            #endif
            if canPreview {
                Button(previewOpen ? "Hide preview" : "Preview") {
                    withAnimation(.easeInOut(duration: 0.15)) { previewOpen.toggle() }
                }
                .buttonStyle(.pennantGhostCompact)
                .fixedSize()
                .disabled(data == nil)
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        if let note {
            Text(note).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkSecondary).lineLimit(1).truncationMode(.middle)
        } else {
            switch state {
            case .loading?, nil:
                ProgressView().controlSize(.small)
            case .failed?:
                // Narrow cards (iPhone, a slim window) drop the label and keep the retry control.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text("Unavailable").font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1).fixedSize()
                        retryButton { Text("Retry") }
                    }
                    retryButton { Image(systemName: "arrow.clockwise") }
                }
            case .loaded?:
                EmptyView()
            }
        }
    }

    private func retryButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button { ArtifactCache.shared.reloadFile(ref.artifactID, using: session) } label: { label() }
            .buttonStyle(.pennantGhostCompact)
            .fixedSize()
            .help("The file could not be fetched from the host. Try again.")
    }

    @ViewBuilder private var preview: some View {
        if let text = previewText {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.zoomed(.caption, design: .monospaced))
                    .foregroundStyle(PennantTheme.ink)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        } else {
            Text("No text preview for this file.").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    private var previewText: String? {
        guard let data, let whole = String(data: data, encoding: .utf8) else { return nil }
        let lines = whole.split(separator: "\n", omittingEmptySubsequences: false)
        var text = lines.prefix(Self.previewLineLimit).joined(separator: "\n")
        if lines.count > Self.previewLineLimit { text += "\n… \(lines.count - Self.previewLineLimit) more lines" }
        return text
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(ref.byteCount), countStyle: .file)
    }

    // MARK: Actions

    #if os(macOS)
    private func save() {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ref.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let ext = (ref.fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
        } catch {
            show("Could not save: \(error.localizedDescription)")
        }
    }

    private func open() {
        guard let url = temporaryCopy() else { return }
        if !NSWorkspace.shared.open(url) { show("No app opens this file") }
    }
    #endif

    /// Writes the bytes to `<tmp>/Pennant/<artifact id>/<name>` once (rewritten only if the size differs).
    private func temporaryCopy() -> URL? {
        guard let data else { return nil }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("Pennant", isDirectory: true).appendingPathComponent(ref.artifactID.rawValue, isDirectory: true)
        var name = ref.fileName.replacingOccurrences(of: "/", with: "-")
        if name.isEmpty || name == "." || name == ".." { name = "file" }
        let url = directory.appendingPathComponent(name)
        let existing = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        if existing != data.count {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                show("Could not write a temporary copy: \(error.localizedDescription)")
                return nil
            }
        }
        return url
    }

    private func show(_ text: String) {
        note = text
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { note = nil }
        }
    }
}

/// Coarse file category used for the icon, the chip, and whether a text preview makes sense.
enum FileKind: Equatable {
    case image, pdf, table, archive, text, other

    private static let tableExtensions: Set<String> = ["csv", "tsv", "xlsx", "xls", "numbers"]
    private static let archiveExtensions: Set<String> = ["zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "dmg"]
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "json", "yaml", "yml", "xml", "html", "htm", "toml", "ini", "cfg", "conf", "sql",
        "swift", "py", "js", "ts", "tsx", "jsx", "sh", "zsh", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "css", "scss", "plist",
    ]
    private static let textMIMEs: Set<String> = [
        "application/json", "application/xml", "application/x-yaml", "application/yaml", "application/javascript", "application/x-sh", "application/toml", "application/x-plist",
    ]

    init(_ ref: FileRef) {
        let mime = ref.mimeType.lowercased()
        let ext = (ref.fileName as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") { self = .image }
        else if mime == "application/pdf" || ext == "pdf" { self = .pdf }
        else if Self.tableExtensions.contains(ext) || mime == "text/csv" || mime == "text/tab-separated-values" || mime.contains("spreadsheet") || mime == "application/vnd.ms-excel" { self = .table }
        else if Self.archiveExtensions.contains(ext) || mime == "application/zip" || mime == "application/gzip" || mime.hasPrefix("application/x-") && (mime.contains("tar") || mime.contains("compress") || mime.contains("zip")) { self = .archive }
        else if mime.hasPrefix("text/") || Self.textMIMEs.contains(mime) || Self.textExtensions.contains(ext) { self = .text }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .table: return "tablecells"
        case .archive: return "archivebox"
        case .text: return "doc.text"
        case .other: return "doc"
        }
    }

    /// Text-based kinds get a monospaced preview; spreadsheets only when they are plain CSV/TSV.
    var previewable: Bool { self == .text || self == .table }

    func label(for ref: FileRef) -> String {
        let ext = (ref.fileName as NSString).pathExtension
        if !ext.isEmpty { return ext.uppercased() }
        switch self {
        case .image: return "IMAGE"
        case .pdf: return "PDF"
        case .table: return "TABLE"
        case .archive: return "ARCHIVE"
        case .text: return "TEXT"
        case .other: return "FILE"
        }
    }
}
