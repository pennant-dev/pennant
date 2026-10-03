import CoreGraphics
import CoreMedia
import CoreVideo
import PennantCore
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

/// Geometry of a capture: enough to map screenshot pixels back to display points.
public struct CaptureGeometry: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var displayWidth: Int
    public var displayHeight: Int

    public init(width: Int, height: Int, displayWidth: Int, displayHeight: Int) {
        self.width = width
        self.height = height
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    public init(_ capture: CapturedScreen) {
        self.init(width: capture.width, height: capture.height, displayWidth: capture.displayWidth, displayHeight: capture.displayHeight)
    }

    /// Display points per screenshot pixel.
    public var scale: Double {
        guard width > 0 else { return 1 }
        return Double(displayWidth) / Double(width)
    }

    public func toDisplay(x: Double, y: Double) -> (x: Double, y: Double) {
        guard width > 0, height > 0 else { return (x, y) }
        return (x * Double(displayWidth) / Double(width), y * Double(displayHeight) / Double(height))
    }

    public func toScreenshot(x: Double, y: Double) -> (x: Double, y: Double) {
        guard displayWidth > 0, displayHeight > 0 else { return (x, y) }
        return (x * Double(width) / Double(displayWidth), y * Double(height) / Double(displayHeight))
    }
}

/// JPEG encoding through ImageIO.
enum JPEGEncoder {
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DesktopError.captureFailed("JPEG encoder unavailable")
        }
        let options = [kCGImageDestinationLossyCompressionQuality: max(0.1, min(1.0, quality))] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw DesktopError.captureFailed("JPEG encoding failed") }
        return data as Data
    }
}

/// Single-shot capture and display geometry helpers built on ScreenCaptureKit.
enum ScreenCapturer {
    static func mainDisplaySizePoints() -> (width: Int, height: Int) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return (Int(bounds.width), Int(bounds.height))
    }

    /// Cursor location in display points, top-left origin.
    static func cursorLocation() -> (x: Double, y: Double) {
        guard let event = CGEvent(source: nil) else { return (0, 0) }
        return (Double(event.location.x), Double(event.location.y))
    }

    /// Resolve the main display's SCDisplay and a filter covering it. Pennant's own cursor is left out of what the
    /// model sees (`withPennantCursor` false) and kept in what the owner watches.
    static func mainDisplayFilter(withPennantCursor: Bool = false) async throws -> (filter: SCContentFilter, displayWidth: Int, displayHeight: Int, pixelScale: Double) {
        guard CGPreflightScreenCaptureAccess() else { throw DesktopError.permissionMissing("Screen Recording") }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw DesktopError.captureFailed(error.localizedDescription)
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw DesktopError.captureFailed("No display available")
        }
        let own = withPennantCursor ? [] : content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        return (filter, display.width, display.height, Double(filter.pointPixelScale))
    }

    /// Where a region is on the display, in points, and the pixel size to capture it at: its full resolution, no
    /// wider than `maxWidth`.
    static func regionCapture(_ region: ScreenRegion, maxWidth: Int, displayWidth: Int, displayHeight: Int, pixelScale: Double) -> (rect: CGRect, width: Int, height: Int) {
        let rect = CGRect(x: region.x * Double(displayWidth), y: region.y * Double(displayHeight),
                          width: max(1, region.width * Double(displayWidth)), height: max(1, region.height * Double(displayHeight)))
        let fullPixels = Int((rect.width * max(1, pixelScale)).rounded())
        let width = max(16, min(maxWidth > 0 ? maxWidth : fullPixels, fullPixels))
        let height = max(16, Int((Double(width) * rect.height / rect.width).rounded()))
        return (rect, width, height)
    }

    /// Output pixel size for a capture no wider than `maxWidth`, preserving aspect ratio.
    static func outputSize(maxWidth: Int, displayWidth: Int, displayHeight: Int, pixelScale: Double) -> (width: Int, height: Int) {
        let fullPixels = Int(Double(displayWidth) * max(1, pixelScale))
        let width = max(16, min(maxWidth > 0 ? maxWidth : fullPixels, fullPixels))
        let height = max(16, Int((Double(width) * Double(displayHeight) / Double(max(1, displayWidth))).rounded()))
        return (width, height)
    }

    /// One app's window, even behind others: its largest normal window, or the one whose title has `title` in it.
    static func captureWindow(pid: pid_t, title: String?, maxWidth: Int, jpegQuality: Double = 0.7) async throws -> (jpeg: Data, width: Int, height: Int, frame: CGRect, title: String) {
        guard CGPreflightScreenCaptureAccess() else { throw DesktopError.permissionMissing("Screen Recording") }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw DesktopError.captureFailed(error.localizedDescription)
        }
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 }
        let named = title.flatMap { t in windows.first { ($0.title ?? "").localizedCaseInsensitiveContains(t) } }
        guard let window = named ?? windows.filter(\.isOnScreen).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            ?? windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw DesktopError.captureFailed(title.map { "No window titled “\($0)”" } ?? "That app has no window to look at")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(max(1, filter.pointPixelScale))
        let full = Int(window.frame.width * scale)
        let width = max(16, min(maxWidth > 0 ? maxWidth : full, full))
        let height = max(16, Int((Double(width) * window.frame.height / max(1, window.frame.width)).rounded()))
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw DesktopError.captureFailed(error.localizedDescription)
        }
        return (try JPEGEncoder.encode(image, quality: jpegQuality), image.width, image.height, window.frame, window.title ?? "")
    }

    static func capture(maxWidth: Int, jpegQuality: Double = 0.7) async throws -> CapturedScreen {
        let (filter, displayWidth, displayHeight, pixelScale) = try await mainDisplayFilter()
        let size = outputSize(maxWidth: maxWidth, displayWidth: displayWidth, displayHeight: displayHeight, pixelScale: pixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw DesktopError.captureFailed(error.localizedDescription)
        }
        let jpeg = try JPEGEncoder.encode(image, quality: jpegQuality)
        let cursor = cursorLocation()
        let sx = Double(image.width) / Double(max(1, displayWidth))
        let sy = Double(image.height) / Double(max(1, displayHeight))
        return CapturedScreen(
            jpeg: jpeg,
            width: image.width,
            height: image.height,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            cursorX: cursor.x * sx,
            cursorY: cursor.y * sy
        )
    }
}

/// A running SCStream that turns frames into JPEG `CapturedScreen`s. One per subscriber.
final class ScreenStreamSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: ScreenStreamOptions
    private let onFrame: @Sendable (CapturedScreen) -> Void
    private let onEnd: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.pennant.screenstream", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private var displayWidth = 0
    private var displayHeight = 0

    init(options: ScreenStreamOptions, onFrame: @escaping @Sendable (CapturedScreen) -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.options = options
        self.onFrame = onFrame
        self.onEnd = onEnd
    }

    func start() {
        Task { [self] in
            do {
                // The owner's live view shows Pennant's cursor too: that's where they see it working.
                let (filter, dw, dh, pixelScale) = try await ScreenCapturer.mainDisplayFilter(withPennantCursor: true)
                let configuration = SCStreamConfiguration()
                if let region = options.region {
                    // Only the part a zoomed-in phone shows, at the display's own resolution: sharp, and smaller.
                    let capture = ScreenCapturer.regionCapture(region, maxWidth: options.maxWidth, displayWidth: dw, displayHeight: dh, pixelScale: pixelScale)
                    configuration.sourceRect = capture.rect
                    configuration.width = capture.width
                    configuration.height = capture.height
                } else {
                    let size = ScreenCapturer.outputSize(maxWidth: options.maxWidth, displayWidth: dw, displayHeight: dh, pixelScale: pixelScale)
                    configuration.width = size.width
                    configuration.height = size.height
                }
                configuration.showsCursor = true
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.queueDepth = 3
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(30, options.framesPerSecond))))
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                guard attach(stream, displayWidth: dw, displayHeight: dh) else { return }
                try await stream.startCapture()
                // A stop that lands while startCapture is in flight finds nothing running yet, so its stopCapture does
                // nothing and the stream would capture and encode for good (28 of them on 2026-09-28, after a client
                // resubscribed on every desktop hand-over). Check again now that it is running.
                if isStopped {
                    try? await stream.stopCapture()
                    return
                }
                log.debug("Screen stream started at \(configuration.width)x\(configuration.height)\(options.region == nil ? "" : " (a region)"), \(options.framesPerSecond) fps", category: "desktop")
            } catch {
                log.warn("Screen stream failed to start: \(error)", category: "desktop")
                stop()
            }
        }
    }

    /// Stores the stream unless the session was stopped while starting. Synchronous so the lock is never held across an await.
    private func attach(_ stream: SCStream, displayWidth: Int, displayHeight: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return false }
        self.stream = stream
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        return true
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let running = stream
        stream = nil
        lock.unlock()
        onEnd()
        if let running {
            Task { try? await running.stopCapture() }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // A frame after stop() means the capture outlived it: end it here rather than encode frames nobody reads.
        if isStopped {
            stream.stopCapture { _ in }
            return
        }
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let statusRaw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let cgImage, let jpeg = try? JPEGEncoder.encode(cgImage, quality: options.jpegQuality) else { return }
        lock.lock()
        let dw = displayWidth, dh = displayHeight
        let active = !stopped
        lock.unlock()
        guard active else { return }
        let cursor = ScreenCapturer.cursorLocation()
        if let region = options.region {
            onFrame(CapturedScreen(jpeg: jpeg, width: cgImage.width, height: cgImage.height, displayWidth: dw, displayHeight: dh, region: region))
            return
        }
        let sx = Double(cgImage.width) / Double(max(1, dw))
        let sy = Double(cgImage.height) / Double(max(1, dh))
        onFrame(CapturedScreen(jpeg: jpeg, width: cgImage.width, height: cgImage.height, displayWidth: dw, displayHeight: dh, cursorX: cursor.x * sx, cursorY: cursor.y * sy))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.warn("Screen stream stopped: \(error.localizedDescription)", category: "desktop")
        stop()
    }
}
