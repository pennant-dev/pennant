import PennantClientKit
import PennantCore
import SwiftUI
import UniformTypeIdentifiers

/// Brand files agents must use: collections ("Acme brand") with written guidance, and the logos, fonts and
/// photos in them. Agents find these with `find_assets`.
public struct LibraryView: View {
    @Environment(\.hostSession) private var session
    @State private var index = LibraryIndex()
    @State private var selected: String?
    @State private var notesDraft = ""
    @State private var notesDirty = false
    @State private var importing = false
    @State private var editing: LibraryAsset?
    @State private var newCollection = false
    @State private var newCollectionName = ""
    @State private var confirmDeleteCollection = false
    @State private var dropTargeted = false
    @State private var busy = false
    @State private var error: String?

    public init() {}

    private var collection: LibraryCollection? { index.collections.first { $0.name == selected } }
    private var assets: [LibraryAsset] { index.assets.filter { $0.collection == selected }.sorted { $0.createdAt < $1.createdAt } }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(PennantTheme.divider).frame(height: 1)
            if index.collections.isEmpty {
                EmptyState(title: "No brand files yet", message: "Add your logo, colours, fonts and photos. Agents use them for every image, slide and document they make for you.") {
                    Button("Create a collection") { newCollectionName = "Brand"; newCollection = true }.buttonStyle(.pennantPrimary)
                }
            } else if let collection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        guidance(collection)
                        grid
                    }
                    .padding(16)
                    .frame(maxWidth: 900, alignment: .leading)
                }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: PennantTheme.radiusLarge).strokeBorder(PennantTheme.brand, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(8)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in upload([url]) } }
                        }
                    }
                    return true
                }
            }
            if let error {
                Text(error).font(.zoomed(.caption)).foregroundStyle(PennantTheme.danger).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .background(PennantTheme.panelBackground)
        .task { await reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .font, .pdf, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { upload(urls) }
        }
        .sheet(item: $editing) { asset in
            LibraryAssetEditor(asset: asset) { updated in
                apply { try await session.updateLibraryAsset(updated) }
            } onDelete: {
                apply { try await session.deleteLibraryAsset(id: asset.id) }
            }
        }
        .alert("New collection", isPresented: $newCollection) {
            TextField("Acme brand", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                apply(select: name) { try await session.saveLibraryCollection(LibraryCollection(name: name)) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this collection?", isPresented: $confirmDeleteCollection) {
            Button("Delete \"\(selected ?? "")\" and its files", role: .destructive) {
                if let name = selected { apply(select: nil) { try await session.deleteLibraryCollection(name: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !index.collections.isEmpty {
                ChipRow(selection: Binding(get: { selected ?? "" }, set: { select($0) }),
                        options: index.collections.map { c in
                            ChoiceOption(c.name, title: "\(c.name)  \(index.assets.filter { $0.collection == c.name }.count)", symbol: "folder")
                        })
            } else {
                Spacer()
            }
            Button { newCollectionName = ""; newCollection = true } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.pennantIcon)
                .help("New collection")
            Button { importing = true } label: { Label(busy ? "Uploading…" : "Add files", systemImage: "plus") }
                .buttonStyle(.pennantPrimaryCompact)
                .disabled(selected == nil || busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func guidance(_ collection: LibraryCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("How to use this brand")
                Spacer()
                if notesDirty {
                    Button("Save") {
                        apply { try await session.saveLibraryCollection(LibraryCollection(name: collection.name, notes: notesDraft)) }
                        notesDirty = false
                    }
                    .buttonStyle(.pennantPrimaryCompact)
                }
                Menu {
                    Button("Delete collection…", role: .destructive) { confirmDeleteCollection = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.pennantIcon).fixedSize()
            }
            PennantTextField(placeholder: "Colours (#1E3A8A navy, #22C55E accent), fonts (Inter), where the logo goes (top-left, never stretched), tone of voice…", text: Binding(get: { notesDraft }, set: { notesDraft = $0; notesDirty = $0 != collection.notes }), lines: 3 ... 10)
            Text("Agents read this with the file list every time they make something for you.")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Files")
            if assets.isEmpty {
                Text("Drop files here or use Add files: logo variants (light and dark), icon, fonts, photos.")
                    .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(assets) { asset in
                        Button { editing = asset } label: { LibraryTile(asset: asset) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func select(_ name: String?) {
        selected = name
        notesDraft = index.collections.first { $0.name == name }?.notes ?? ""
        notesDirty = false
    }

    private func reload() async {
        guard let fresh = try? await session.listLibrary() else { return }
        index = fresh
        if selected == nil || !fresh.collections.contains(where: { $0.name == selected }) { select(fresh.collections.first?.name) }
    }

    private func apply(select name: String?? = .none, _ op: @escaping () async throws -> LibraryIndex) {
        error = nil
        Task {
            do {
                index = try await op()
                if case .some(let n) = name { select(n) }
                else if selected == nil { select(index.collections.first?.name) }
            } catch {
                self.error = HostSessionError.message(error)
            }
        }
    }

    private func upload(_ urls: [URL]) {
        guard let collection = selected else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { error = "Couldn’t read \(url.lastPathComponent)."; continue }
                let type = UTType(filenameExtension: url.pathExtension) ?? .data
                do {
                    index = try await session.uploadLibraryAsset(data, collection: collection, fileName: url.lastPathComponent, mimeType: type.preferredMIMEType ?? "application/octet-stream")
                } catch {
                    self.error = HostSessionError.message(error)
                }
            }
        }
    }
}

/// One file in the grid: a preview for images, a type badge otherwise.
struct LibraryTile: View {
    var asset: LibraryAsset
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LibraryPreview(asset: asset)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background { CheckerBackground(dark: asset.isLightArtwork) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PennantTheme.border))
            Text(asset.name).font(.zoomed(.callout).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1)
            Text(detail).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = [asset.fileName.split(separator: ".").last.map { $0.uppercased() } ?? "FILE"]
        if let w = asset.width, let h = asset.height { parts.append("\(w)×\(h)") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(asset.byteCount), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

struct LibraryPreview: View {
    @Environment(\.hostSession) private var session
    var asset: LibraryAsset
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fit).padding(10)
            } else if asset.isImage {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: asset.mimeType.contains("font") ? "textformat" : asset.mimeType.contains("pdf") ? "doc.richtext" : "doc")
                    .font(.zoomed(.largeTitle)).foregroundStyle(PennantTheme.inkTertiary)
            }
        }
        .task(id: asset.id) {
            guard asset.isImage, image == nil, let data = try? await session.libraryPreview(id: asset.id) else { return }
            image = PlatformImage(data: data)
        }
    }
}

/// A checkerboard that shows transparency; dark for white artwork ("logo-white") so it stays visible.
struct CheckerBackground: View {
    var dark = false
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark ? Color(hex: "#1A1A1E") : PennantTheme.cardElevated))
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(dark ? Color(hex: "#26262B") : PennantTheme.cardBackground))
                }
            }
        }
    }
}

extension LibraryAsset {
    /// White or reversed artwork, going by its name, previewed on dark.
    var isLightArtwork: Bool {
        let words = "\(name) \(fileName) \(notes)".lowercased()
        return ["white", "reversed", "inverse", "for dark", "on dark"].contains { words.contains($0) }
    }
}

struct LibraryAssetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var asset: LibraryAsset
    var onSave: (LibraryAsset) -> Void
    var onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                LibraryPreview(asset: asset)
                    .frame(width: 160, height: 160)
                    .background { CheckerBackground(dark: asset.isLightArtwork) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 10) {
                    PennantTextField("Name", placeholder: "Primary logo, white, for dark backgrounds", text: $asset.name)
                    Text(asset.path).font(.zoomed(.caption).monospaced()).foregroundStyle(PennantTheme.inkTertiary).textSelection(.enabled).lineLimit(2)
                }
            }
            PennantTextField("When to use it", placeholder: "Top-left of every slide at 64 px tall. Never on photos.", text: $asset.notes, lines: 2 ... 6)
            HStack {
                Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.pennantGhost)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pennantSecondary)
                Button("Save") { onSave(asset); dismiss() }.buttonStyle(.pennantPrimary)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .confirmationDialog("Delete \(asset.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete(); dismiss() }
        }
    }
}
