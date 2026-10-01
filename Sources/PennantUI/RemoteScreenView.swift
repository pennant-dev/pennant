#if os(iOS)
import PennantCore
import SwiftUI
import UIKit

/// The live host screen with iPhone-native gestures: one finger controls the pointer (tap, double
/// tap, press-and-hold for right click, drag for drag-and-drop), two fingers scroll the host, and
/// pinch zooms the view. Zoomed in, two fingers move around the view instead (and one finger does too while only
/// watching); double-tap with two fingers to zoom back out. Input points are mapped back through the zoom
/// transform, so clicks stay accurate while zoomed. Touches that start on the screen never scroll the page around
/// it.
public struct RemoteScreenUIView: UIViewRepresentable {
    var image: UIImage
    var interactive: Bool
    var onInput: (RemoteInput) -> Void

    public func makeUIView(context: Context) -> TouchScreenView { TouchScreenView() }

    public func updateUIView(_ view: TouchScreenView, context: Context) {
        view.show(image)
        view.interactive = interactive
        view.onInput = onInput
    }
}

public final class TouchScreenView: UIView {
    var interactive = true {
        didSet {
            for gesture in inputGestures { gesture.isEnabled = interactive }
            if !interactive { endStrandedDrag() }
        }
    }
    var onInput: ((RemoteInput) -> Void)?

    private let screen = UIImageView()
    private let gestureDelegate = TouchGestureDelegate()
    private var inputGestures: [UIGestureRecognizer] = []
    private var panGestures: [UIGestureRecognizer] = []
    /// Moving the zoomed view around, from the offset when the move began.
    private var panOrigin: CGPoint?
    private var fitRect = CGRect.zero
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero
    private var gestureScale: CGFloat = 1
    private var dragging = false
    private var dragStart: CGPoint?
    private var lastClickAt = Date.distantPast
    private var lastClickPoint = CGPoint.zero
    private var suppressPointerUntilLift = false
    private var twoFingerLast = CGPoint.zero
    private var pinchActive = false
    private var scrollActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        screen.contentMode = .scaleAspectFit
        screen.isUserInteractionEnabled = false
        addSubview(screen)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let one = UIPanGestureRecognizer(target: self, action: #selector(handlePointer(_:)))
        one.minimumNumberOfTouches = 1
        one.maximumNumberOfTouches = 1
        one.cancelsTouchesInView = false
        let two = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        two.minimumNumberOfTouches = 2
        two.maximumNumberOfTouches = 2
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.5
        // A pan only begins after the finger has moved ~10 pt, so a still tap never reaches it: taps get
        // their own recogniser. It fails on movement (then the pan takes over) and on a long press.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let resetZoomTap = UITapGestureRecognizer(target: self, action: #selector(handleResetZoom(_:)))
        resetZoomTap.numberOfTouchesRequired = 2
        resetZoomTap.numberOfTapsRequired = 2
        [pinch, one, two, press, tap, resetZoomTap].forEach { $0.delegate = gestureDelegate; addGestureRecognizer($0) }
        // Pointer and scroll stay on while only watching: zoomed in, they move the view around.
        inputGestures = [press, tap]
        panGestures = [one, two]
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: UIImage) {
        screen.image = image
        recomputeFit()
    }

    /// Only watching at full size, drags on the screen have nothing to do: let them scroll the page instead.
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if panGestures.contains(where: { $0 === gestureRecognizer }), !interactive, scale <= 1 { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        screen.frame = bounds
        recomputeFit()
    }

    // MARK: Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            gestureScale = scale
            pinchActive = true
            endStrandedDrag()
        case .changed:
            let target = min(4, max(1, gestureScale * gesture.scale))
            let factor = target / scale
            guard abs(factor - 1) > 0.001 else { return }
            let m = gesture.location(in: self)
            offset = CGPoint(x: m.x - factor * (m.x - offset.x), y: m.y - factor * (m.y - offset.y))
            scale = target
            clampOffset()
            applyZoom()
        case .ended, .cancelled, .failed:
            pinchActive = false
            if scale < 1.03 { resetZoom() }
        default:
            break
        }
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
        applyZoom()
    }

    @objc private func handleResetZoom(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, scale > 1 else { return }
        UIView.animate(withDuration: 0.2) { self.resetZoom() }
    }

    /// Moves the zoomed view with the fingers.
    private func panView(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            panOrigin = offset
        case .changed:
            guard let origin = panOrigin else { return }
            let t = gesture.translation(in: self)
            offset = CGPoint(x: origin.x + t.x, y: origin.y + t.y)
            clampOffset()
            applyZoom()
        default:
            panOrigin = nil
        }
    }

    /// UIKit scales a view about its centre; the zoom maths (and `toContent`) work about the top-left corner,
    /// so shift the translation by the centre's movement: p = offset + scale · q for every point q.
    private func applyZoom() {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        screen.transform = CGAffineTransform(translationX: offset.x + (scale - 1) * c.x, y: offset.y + (scale - 1) * c.y)
            .scaledBy(x: scale, y: scale)
    }

    /// The scaled frame never shows background inside its edges: centre the axis where the image
    /// is smaller than the view, and clamp the other so it always covers.
    private func clampOffset() {
        guard scale > 1, fitRect.width > 0 else { offset = .zero; return }
        let scaled = fitRect.applying(CGAffineTransform(scaleX: scale, y: scale))
        if scaled.width >= bounds.width {
            offset.x = max(-scaled.minX, min(bounds.width - scaled.maxX, offset.x))
        } else {
            offset.x = (bounds.width - scaled.width) / 2 - scaled.minX
        }
        if scaled.height >= bounds.height {
            offset.y = max(-scaled.minY, min(bounds.height - scaled.maxY, offset.y))
        } else {
            offset.y = (bounds.height - scaled.height) / 2 - scaled.minY
        }
    }

    // MARK: Pointer (one finger)

    @objc private func handlePointer(_ gesture: UIPanGestureRecognizer) {
        // Only watching: one finger moves the zoomed view around.
        if !interactive {
            if scale > 1, !pinchActive { panView(gesture) }
            return
        }
        // A second finger ends pointer control: the sequence belongs to pinch or scroll now.
        if gesture.numberOfTouches > 1 || pinchActive || scrollActive {
            endStrandedDrag()
            dragStart = nil
            return
        }
        if suppressPointerUntilLift {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                suppressPointerUntilLift = false
                dragging = false
                dragStart = nil
            }
            return
        }
        let point = toContent(gesture.location(in: self))
        switch gesture.state {
        case .began:
            // Where the finger first touched, not where the pan was recognised ~10 pt later.
            let loc = gesture.location(in: self), moved = gesture.translation(in: self)
            dragStart = toContent(CGPoint(x: loc.x - moved.x, y: loc.y - moved.y))
        case .changed:
            if !dragging, let start = dragStart, hypot(point.x - start.x, point.y - start.y) > 4, let p = normalise(start) {
                dragging = true
                if interactive { onInput?(.pointerDown(x: p.x, y: p.y, button: .left)) }
            }
            if dragging, interactive, let p = normalise(point) {
                onInput?(.pointerMove(x: p.x, y: p.y))
            }
        case .ended:
            defer { dragging = false; dragStart = nil }
            guard interactive, dragging, let p = normalise(point) else { return }
            onInput?(.pointerUp(x: p.x, y: p.y, button: .left))
        case .cancelled, .failed:
            if dragging, interactive, let p = normalise(point) {
                onInput?(.pointerUp(x: p.x, y: p.y, button: .left))
            }
            dragging = false
            dragStart = nil
        default:
            break
        }
    }

    /// One finger, lifted without moving: a click, or a double click when it follows the last one closely.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, interactive, !pinchActive, !scrollActive else { return }
        let point = toContent(gesture.location(in: self))
        guard let p = normalise(point) else { return }
        let now = Date()
        let near = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 12
        let count = (now.timeIntervalSince(lastClickAt) < 0.35 && near) ? 2 : 1
        lastClickAt = now
        lastClickPoint = point
        onInput?(.click(x: p.x, y: p.y, button: .left, count: count))
    }

    /// A drag that never saw its .ended (tab change, takeover handoff) must release the mouse.
    private func endStrandedDrag() {
        defer { dragging = false; dragStart = nil }
        if dragging, let p = dragStart.flatMap(normalise) {
            onInput?(.pointerUp(x: p.x, y: p.y, button: .left))
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            suppressPointerUntilLift = true
            guard interactive, let p = normalise(toContent(gesture.location(in: self))) else { return }
            onInput?(.click(x: p.x, y: p.y, button: .right, count: 1))
        case .ended, .cancelled, .failed:
            suppressPointerUntilLift = false
        default:
            break
        }
    }

    // MARK: Scroll (two fingers)

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard !pinchActive else { return }
        // Zoomed in, two fingers move the view; at full size they scroll the Mac.
        if scale > 1 || panOrigin != nil {
            if gesture.state == .began { endStrandedDrag() }
            panView(gesture)
            return
        }
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            scrollActive = true
            twoFingerLast = translation
            endStrandedDrag()
        case .changed:
            let delta = CGPoint(x: translation.x - twoFingerLast.x, y: translation.y - twoFingerLast.y)
            twoFingerLast = translation
            guard interactive else { return }
            let center = toContent(gesture.location(in: self))
            let p = normalise(center) ?? normalise(CGPoint(x: fitRect.midX, y: fitRect.midY)) ?? (0.5, 0.5)
            // Finger travel on the phone, in the Mac's pixels, so the page moves as far as the fingers did.
            let k = Double(pixelsPerPoint)
            onInput?(.scroll(x: p.x, y: p.y, deltaX: Double(delta.x) * k, deltaY: Double(-delta.y) * k))
        case .ended, .cancelled, .failed:
            scrollActive = false
        default:
            break
        }
    }

    // MARK: Coordinates

    /// A point in view space back through the zoom transform into the untransformed image space.
    private func toContent(_ p: CGPoint) -> CGPoint {
        guard scale > 1 else { return p }
        return CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    private func recomputeFit() {
        guard let size = screen.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { fitRect = .zero; return }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        fitRect = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        if scale > 1 { clampOffset(); applyZoom() }
    }

    /// Mac screen pixels per phone point at the current zoom.
    private var pixelsPerPoint: CGFloat {
        guard let size = screen.image?.size, fitRect.width > 0 else { return 1 }
        return size.width * (screen.image?.scale ?? 1) / (fitRect.width * scale)
    }

    private func normalise(_ p: CGPoint) -> (x: Double, y: Double)? {
        guard fitRect.width > 0, fitRect.height > 0 else { return nil }
        let x = Double((p.x - fitRect.minX) / fitRect.width)
        let y = Double((p.y - fitRect.minY) / fitRect.height)
        guard (0 ... 1).contains(x), (0 ... 1).contains(y) else { return nil }
        return (x, y)
    }
}

/// Lets the one-finger pointer run alongside a developing pinch or scroll (it yields as soon as
/// the second finger registers) while keeping pinch, scroll, and long-press mutually exclusive,
/// so a single touch sequence never fires two actions at once.
private final class TouchGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    /// A scroll view around the screen (the Computer tab) waits for the screen's own gestures, so a drag, pinch or
    /// two-finger move that starts on the screen goes to the screen instead of scrolling the page.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let outer = otherGestureRecognizer.view as? UIScrollView, let screen = gestureRecognizer.view else { return false }
        return screen.isDescendant(of: outer) && otherGestureRecognizer === outer.panGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let pair: Set<Int> = [Self.kind(gestureRecognizer), Self.kind(otherGestureRecognizer)]
        return pair == [1, 2] || pair == [2, 3]
    }

    /// 1 pinch, 2 pointer pan (one finger), 3 scroll pan (two fingers), 4 long press, 5 tap.
    private static func kind(_ gesture: UIGestureRecognizer) -> Int {
        if gesture is UIPinchGestureRecognizer { return 1 }
        if let pan = gesture as? UIPanGestureRecognizer { return pan.maximumNumberOfTouches == 2 ? 3 : 2 }
        if gesture is UILongPressGestureRecognizer { return 4 }
        if gesture is UITapGestureRecognizer { return 5 }
        return 0
    }
}
#endif
