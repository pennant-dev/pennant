import AppKit
import CoreGraphics
import PennantCore
import Foundation

/// Observes real (non-synthetic) mouse and keyboard activity so the runtime can pause agent desktop
/// actions when the human starts using the machine. Listen-only; it never blocks or alters events.
public actor HumanInputMonitor: HumanInputObserving {
    private let tap = InputTap()

    public init() {}

    public func lastHumanInputAt() async -> Date? { tap.lastHumanInputAt }
    public func start() async { tap.start() }
    public func stop() async { tap.stop() }
}

/// The event tap lives on its own thread with a run loop. Falls back to NSEvent global monitors when
/// the tap cannot be created (Accessibility or Input Monitoring not granted).
final class InputTap: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAt: Date?
    private var running = false
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var globalMonitor: Any?

    var lastHumanInputAt: Date? { lock.withLock { lastAt } }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        let thread = Thread { [self] in runTapLoop() }
        thread.name = "dev.pennant.inputtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        let port = port
        let runLoop = runLoop
        let monitor = globalMonitor
        self.port = nil
        self.runLoop = nil
        self.globalMonitor = nil
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        if let monitor {
            DispatchQueue.main.async { NSEvent.removeMonitor(monitor) }
        }
    }

    private static let fullMask: CGEventMask = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private static let mouseMask: CGEventMask = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private func runTapLoop() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: Self.fullMask, callback: callback, userInfo: refcon)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: Self.mouseMask, callback: callback, userInfo: refcon)
        guard let port = created else {
            log.warn("Could not create input event tap; falling back to NSEvent global monitor", category: "desktop")
            installFallback()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.lock()
        let stillRunning = running
        self.port = port
        self.runLoop = runLoop
        lock.unlock()
        guard stillRunning else { CFMachPortInvalidate(port); return }
        CFRunLoopRun()
    }

    private func installFallback() {
        DispatchQueue.main.async { [self] in
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [self] event in
                if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == DesktopController.syntheticMarker { return }
                lock.withLock { lastAt = Date() }
            }
            lock.withLock { globalMonitor = monitor }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == DesktopController.syntheticMarker { return }
        lock.withLock { lastAt = Date() }
    }
}
