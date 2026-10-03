import AppKit
import SwiftUI

/// Pennant's own cursor: a picture of a pointer in a transparent window that floats above every app and Space and lets
/// clicks pass straight through, moved to wherever Pennant is working. The owner's real pointer stays theirs; this one
/// only shows where Pennant is, even when the app it's working in is behind other windows.
///
/// Pennant's own screenshots leave it out (see `ScreenCapturer.mainDisplayFilter`), so the model never mistakes it for
/// something on screen.
@MainActor
public final class PennantCursor {
    public static let shared = PennantCursor()

    private var panel: NSPanel?
    private let model = CursorModel()
    private var hideTimer: Timer?
    /// Where the arrow's tip sits inside the panel (top-left origin), and the panel's size.
    private static let tip = CGPoint(x: 18, y: 18)
    private static let size = CGSize(width: 64, height: 64)
    /// How long the cursor stays after Pennant's last action.
    static let idleSeconds: TimeInterval = 5

    /// Shows the cursor at a display point (top-left origin of the main display), gliding from where it last was;
    /// `click` adds a ripple there.
    public func show(at point: CGPoint, click: Bool = false, label: String? = nil) {
        guard let screen = NSScreen.screens.first else { return }
        let panel = self.panel ?? makePanel()
        // Display points (top-left origin) to AppKit screen coordinates (bottom-left origin), tip on the point.
        let origin = CGPoint(x: point.x - Self.tip.x, y: screen.frame.height - point.y - (Self.size.height - Self.tip.y))
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5
        model.label = label
        if wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrameOrigin(origin)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
        if click { model.ripple() }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    /// Fades the cursor out.
    public func hide() {
        hideTimer?.invalidate()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: {
            Task { @MainActor in if panel.alphaValue < 0.05 { panel.orderOut(nil) } }
        })
    }

    private func makePanel() -> NSPanel {
        // The host runs without a Dock icon or menu bar; an accessory app may still show this kind of window.
        if NSApp.activationPolicy() == .prohibited { NSApp.setActivationPolicy(.accessory) }
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: CursorView(model: model))
        self.panel = panel
        return panel
    }
}

/// What the cursor view shows.
@MainActor
@Observable
final class CursorModel {
    var label: String?
    var rippleID = 0
    func ripple() { rippleID += 1 }
}

/// A pointer in Pennant's violet with a white edge and a soft glow, so it reads on light and dark windows alike and
/// never looks like the owner's own black-and-white one.
struct CursorView: View {
    var model: CursorModel
    @State private var rippling = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(Color(red: 0.42, green: 0.25, blue: 0.85).opacity(rippling ? 0 : 0.6), lineWidth: 2)
                .frame(width: rippling ? 34 : 6, height: rippling ? 34 : 6)
                .position(x: 18, y: 18)
            Arrow()
                .fill(Color(red: 0.42, green: 0.25, blue: 0.85))
                .overlay(Arrow().stroke(.white, lineWidth: 1.5))
                .frame(width: 16, height: 22)
                .shadow(color: Color(red: 0.42, green: 0.25, blue: 0.85).opacity(0.55), radius: 6)
                .offset(x: 18, y: 18)
        }
        .frame(width: 64, height: 64, alignment: .topLeading)
        .onChange(of: model.rippleID) { _, _ in
            // Back to a dot at once, then out, so every click ripples.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { rippling = false }
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.45)) { rippling = true } }
        }
    }
}

/// A pointer's outline, tip at the top-left corner.
struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: h * 0.86))
        p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.64))
        p.addLine(to: CGPoint(x: w * 0.52, y: h))
        p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.93))
        p.addLine(to: CGPoint(x: w * 0.48, y: h * 0.58))
        p.addLine(to: CGPoint(x: w, y: h * 0.58))
        p.closeSubpath()
        return p
    }
}
