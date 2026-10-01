import AppKit
import PennantClientKit
import PennantUI
import SwiftUI

/// The floating teaching panel: always on top, on every Space, and non-activating, so clicking it never takes
/// focus from the app being demonstrated. It can still become key, so the note field takes typing. The host
/// ignores clicks and keys in Pennant's own windows, so using the panel is never recorded as a step.
@MainActor
final class TeachingPanelController {
    static let shared = TeachingPanelController()
    private var panel: TeachingPanel?
    static let size = NSSize(width: 320, height: 250)

    func show(session: HostSession) {
        if panel == nil {
            let p = TeachingPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            let root = TeachingPanelView()
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                .background(PennantTheme.windowBackground)
                .hostSession(session)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PennantTheme.border))
            // A fixed size: a panel that resized itself with its content would grow off the screen's edge.
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: Self.size)
            p.contentView = host
            panel = p
        }
        guard let panel else { return }
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - Self.size.width - 20, y: screen.maxY - Self.size.height - 20, width: Self.size.width, height: Self.size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

final class TeachingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Main windows (not panels or popovers) of the app.
@MainActor
enum PennantWindows {
    static var main: [NSWindow] {
        NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }

    /// Clears the desktop for a demonstration.
    static func stepAside() {
        for w in main where w.isVisible { w.miniaturize(nil) }
    }

    /// Brings Pennant back when the demonstration ends.
    static func comeBack() {
        for w in main where w.isMiniaturized { w.deminiaturize(nil) }
        // macOS only lets an app activate itself right after the user acted in it (pressing Stop in the panel
        // counts). Ordering the window front works either way, so the review sheet is never hidden.
        NSApp.activate()
        for w in main { w.orderFrontRegardless() }
        main.first?.makeKey()
    }
}
