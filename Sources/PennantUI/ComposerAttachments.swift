import PennantCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file waiting to go out with the next message: uploading, ready (stored on the host), or failed.
public struct ComposerAttachment: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case uploading
        case ready(Attachment)
        case failed(String)
    }

    public let id = UUID()
    public var fileName: String
    public var mimeType: String
    /// A small preview for images.
    public var thumbnail: Data?
    public var state: State

    public var ready: Attachment? { if case .ready(let a) = state { return a }; return nil }
    public var isUploading: Bool { state == .uploading }
}

/// Turns picked files and pasted images into upload-ready data: images are downscaled to at most 2048 px on the
/// long side (models see them smaller anyway) and re-encoded as JPEG unless they are small PNGs.
enum AttachmentPrep {
    static let maxImageSide = 2048
    static let maxBytes = 20 * 1024 * 1024

    struct Prepared {
        var data: Data
        var fileName: String
        var mimeType: String
        var thumbnail: Data?
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        var description: String {
            switch self {
            case .unreadable(let name): return "Couldn’t read \(name)."
            case .tooLarge(let name): return "\(name) is larger than 20 MB."
            }
        }
    }

    static func prepare(fileURL url: URL) throws -> Prepared {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url.lastPathComponent) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return try prepare(data: data, fileName: url.lastPathComponent, type: type)
    }

    static func prepare(data: Data, fileName: String, type: UTType) throws -> Prepared {
        if type.conforms(to: .image), let image = downscaled(data) {
            let base = (fileName as NSString).deletingPathExtension
            let fits = (longSide(data) ?? Int.max) <= maxImageSide
            // Already small enough in a format every model reads: send it as it is.
            if fits, type.conforms(to: .jpeg), data.count < 4_000_000 {
                return Prepared(data: data, fileName: fileName, mimeType: "image/jpeg", thumbnail: image.thumbnail)
            }
            if fits, type.conforms(to: .png), data.count < 1_500_000 {
                return Prepared(data: data, fileName: fileName, mimeType: "image/png", thumbnail: image.thumbnail)
            }
            return Prepared(data: image.jpeg, fileName: base + ".jpg", mimeType: "image/jpeg", thumbnail: image.thumbnail)
        }
        guard data.count <= maxBytes else { throw Failure.tooLarge(fileName) }
        return Prepared(data: data, fileName: fileName, mimeType: type.preferredMIMEType ?? "application/octet-stream", thumbnail: nil)
    }

    /// JPEG at most `maxImageSide` on the long side, and a 160 px thumbnail.
    private static func downscaled(_ data: Data) -> (jpeg: Data, thumbnail: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        func image(_ side: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ] as CFDictionary)
        }
        guard let full = image(maxImageSide), let small = image(160),
              let jpeg = encode(full, quality: 0.85), let thumb = encode(small, quality: 0.7) else { return nil }
        return (jpeg, thumb)
    }

    private static func longSide(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(w, h)
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    #if os(macOS)
    /// An image on the clipboard (a screenshot copied with ⌃⇧⌘4, say), as PNG data.
    static func pasteboardImage() -> Data? {
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) { return rep.representation(using: .png, properties: [:]) }
        return nil
    }
    #endif
}

/// The pending attachments above the message field: a thumbnail or file icon, the name, progress, and a remove button.
struct AttachmentStrip: View {
    @Binding var attachments: [ComposerAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in chip(item) }
            }
            .padding(.horizontal, 4)
        }
    }

    private func chip(_ item: ComposerAttachment) -> some View {
        HStack(spacing: 8) {
            preview(item)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName).font(.zoomed(.caption).weight(.medium)).foregroundStyle(PennantTheme.ink).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .uploading: Text("Uploading…").font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkSecondary)
                case .ready(let a): Text(ByteCountFormatter.string(fromByteCount: Int64(a.byteCount), countStyle: .file)).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.inkTertiary)
                case .failed(let why): Text(why).font(.zoomed(.caption2)).foregroundStyle(PennantTheme.danger).lineLimit(1)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
            if item.isUploading {
                ProgressView().controlSize(.mini)
            } else {
                Button { attachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(PennantTheme.inkTertiary)
                    .accessibilityLabel("Remove \(item.fileName)")
            }
        }
        .padding(6)
        .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func preview(_ item: ComposerAttachment) -> some View {
        if let data = item.thumbnail, let image = Self.image(data) {
            image.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                PennantTheme.fieldBackground
                Image(systemName: item.mimeType.contains("pdf") ? "doc.richtext" : "doc").foregroundStyle(PennantTheme.inkSecondary)
            }
        }
    }

    static func image(_ data: Data) -> Image? {
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}
