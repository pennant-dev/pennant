#if os(iOS)
import PennantCore
import SwiftUI
import UIKit

/// The live host screen with iPhone-native gestures. Touch mode: one finger controls the pointer where it touches
/// (tap, double tap, press-and-hold for right click, drag for drag-and-drop). Trackpad mode: one finger moves a
/// pointer drawn on the screen, a tap clicks where it is, two fingers tap for a right click, and touch-and-hold then
/// move drags. In both, two fingers scroll the host and pinch zooms the view; zoomed in, two fingers move around the
/// view instead (and one finger does too while only watching), and a two-finger double tap zooms back out. Input
/// points are mapped back through the zoom, so clicks stay accurate while zoomed, and a ring shows where each click
/// landed. Touches that start on the screen never scroll the page around it.
public struct RemoteScreenUIView: UIViewRepresentable {
    var image: UIImage
    /// The part of the display `image` shows (nil: all of it).
    var imageRegion: ScreenRegion?
    var interactive: Bool
    var mode: RemotePointerMode
    var zoomRequest: ScreenZoomRequest?
    /// The part of the display in view once a zoom or pan settles (nil: all of it), for streaming just that part.
    var onViewport: ((ScreenRegion?) -> Void)?
    var onInput: (RemoteInput) -> Void

    public func makeUIView(context: Context) -> TouchScreenView { TouchScreenView() }

    public func updateUIView(_ view: TouchScreenView, context: Context) {
        view.onViewport = onViewport
        view.show(image, region: imageRegion)
        view.interactive = interactive
        view.mode = mode
        view.onInput = onInput
        if let zoomRequest { view.apply(zoomRequest) }
    }
}

public final class TouchScreenView: UIView {
    var interactive = true {
        didSet {
            for gesture in inputGestures { gesture.isEnabled = interactive }
            if !interactive { endStrandedDrag() }
            placeCursor()
        }
    }
    var mode = RemotePointerMode.touch {
        didSet {
            guard mode != oldValue else { return }
            endStrandedDrag()
            placeCursor()
        }
    }
    var onInput: ((RemoteInput) -> Void)?
    var onViewport: ((ScreenRegion?) -> Void)?

    private let screen = UIImageView()
    /// A region frame drawn over the last full frame where it belongs, at its own (higher) resolution. It sits inside
    /// `screen`, so it zooms and moves with it.
    private let detail = UIImageView()
    private var detailRegion: ScreenRegion?
    /// The region last asked for, so small pans inside it don't restart the stream.
    private var requestedRegion: ScreenRegion?
    /// A ring where the last click landed.
    private let marker = UIView()
    /// Trackpad mode's pointer, drawn at once (the Mac's own pointer in the stream lags a few frames behind).
    private let cursorView = UIImageView(image: UIImage(systemName: "cursorarrow", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)))
    /// Where the trackpad pointer is, in unzoomed view coordinates.
    private var cursor: CGPoint?
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
    /// The trackpad finger's last position, for moving the pointer by how far it went since.
    private var trackpadLast: CGPoint?
    private var lastClickAt = Date.distantPast
    private var lastClickPoint = CGPoint.zero
    private var suppressPointerUntilLift = false
    private var twoFingerLast = CGPoint.zero
    private var pinchActive = false
    private var scrollActive = false
    /// What a two-finger touch is, decided by its first clear movement: fingers spreading or closing zoom, fingers
    /// moving together scroll the Mac (or move the zoomed view). Until then neither acts, so a pinch never turns
    /// into a scroll because the scroll was recognised first.
    private enum TwoFingers { case undecided, zoom, scroll }
    private var twoFingers = TwoFingers.undecided
    private var pinchGesture: UIPinchGestureRecognizer?
    private var scrollGesture: UIPanGestureRecognizer?
    private var lastZoomRequest: UUID?
    /// The steps the zoom buttons move between.
    private static let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4]

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Without this the view only ever sees the first finger, and pinch and two-finger scroll never happen.
        isMultipleTouchEnabled = true
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityIdentifier = "live-screen"
        accessibilityLabel = "Mac screen"
        accessibilityValue = "zoom 1.0"
        screen.contentMode = .scaleAspectFit
        screen.isUserInteractionEnabled = false
        addSubview(screen)
        detail.contentMode = .scaleToFill
        detail.isHidden = true
        screen.addSubview(detail)

        marker.isUserInteractionEnabled = false
        marker.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        marker.layer.cornerRadius = 13
        marker.layer.borderWidth = 2.5
        marker.layer.borderColor = UIColor.systemYellow.cgColor
        marker.alpha = 0
        addSubview(marker)

        cursorView.isUserInteractionEnabled = false
        cursorView.tintColor = .white
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.9
        cursorView.layer.shadowRadius = 1.5
        cursorView.layer.shadowOffset = .zero
        cursorView.isHidden = true
        addSubview(cursorView)

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
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.require(toFail: resetZoomTap)
        [pinch, one, two, press, tap, resetZoomTap, rightTap].forEach { $0.delegate = gestureDelegate; addGestureRecognizer($0) }
        pinchGesture = pinch
        scrollGesture = two
        // Pointer and scroll stay on while only watching: zoomed in, they move the view around.
        inputGestures = [press, tap, rightTap]
        panGestures = [one, two]
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A full frame replaces the picture; a region frame goes over it where it belongs (once there is a full frame to
    /// place it on).
    func show(_ image: UIImage, region: ScreenRegion?) {
        guard let region else {
            if screen.image !== image { screen.image = image }
            detail.isHidden = true
            detailRegion = nil
            recomputeFit()
            return
        }
        guard screen.image != nil else { return }
        detail.image = image
        detailRegion = region
        detail.isHidden = false
        placeDetail()
    }

    private func placeDetail() {
        guard let r = detailRegion, fitRect.width > 0 else { return }
        detail.frame = CGRect(x: fitRect.minX + r.x * fitRect.width, y: fitRect.minY + r.y * fitRect.height, width: r.width * fitRect.width, height: r.height * fitRect.height)
    }

    /// Once a zoom or pan settles: the part of the display in view, grown a little, when zoomed in; else nil. Asked
    /// for again only when the view leaves what was asked for, or needs it sharper.
    private func reportViewport() {
        guard fitRect.width > 0, let onViewport else { return }
        guard scale > 1.2 else {
            if requestedRegion != nil { requestedRegion = nil; onViewport(nil) }
            return
        }
        let topLeft = toContent(.zero), bottomRight = toContent(CGPoint(x: bounds.width, y: bounds.height))
        let x0 = max(0, (topLeft.x - fitRect.minX) / fitRect.width), y0 = max(0, (topLeft.y - fitRect.minY) / fitRect.height)
        let x1 = min(1, (bottomRight.x - fitRect.minX) / fitRect.width), y1 = min(1, (bottomRight.y - fitRect.minY) / fitRect.height)
        guard x1 > x0, y1 > y0 else { return }
        let visible = ScreenRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let asked = requestedRegion, asked.contains(visible), visible.width > asked.width * 0.6 { return }
        let wanted = visible.grown(by: 0.15)
        requestedRegion = wanted
        onViewport(wanted)
    }

    /// Only watching at full size, drags on the screen have nothing to do: let them scroll the page instead.
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if panGestures.contains(where: { $0 === gestureRecognizer }), !interactive, scale <= 1 { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frame: the frame is undefined while the zoom transform is set.
        screen.bounds = CGRect(origin: .zero, size: bounds.size)
        screen.center = CGPoint(x: bounds.midX, y: bounds.midY)
        recomputeFit()
    }

    // MARK: Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            gestureScale = scale
        case .changed:
            if twoFingers == .undecided, abs(gesture.scale - 1) > 0.08 {
                twoFingers = .zoom
                pinchActive = true
                endStrandedDrag()
                // Carry on from the current zoom, not from where the fingers started.
                gestureScale = scale / gesture.scale
            }
            guard twoFingers == .zoom else { return }
            let target = min(4, max(1, gestureScale * gesture.scale))
            let factor = target / scale
            guard abs(factor - 1) > 0.001 else { return }
            let m = gesture.location(in: self)
            offset = CGPoint(x: m.x - factor * (m.x - offset.x), y: m.y - factor * (m.y - offset.y))
            scale = target
            clampOffset()
            applyZoom()
        case .ended, .cancelled, .failed:
            if twoFingers == .zoom, scale < 1.03 { resetZoom() }
            pinchActive = false
            twoFingersEnded()
            reportViewport()
        default:
            break
        }
    }

    /// Once both two-finger gestures are over, the next touch decides afresh.
    private func twoFingersEnded() {
        let live: Set<UIGestureRecognizer.State> = [.began, .changed]
        if !live.contains(pinchGesture?.state ?? .possible), !live.contains(scrollGesture?.state ?? .possible) { twoFingers = .undecided }
    }

    /// The zoom buttons: the next step in or out, about the middle of the view.
    func apply(_ request: ScreenZoomRequest) {
        guard request.id != lastZoomRequest else { return }
        lastZoomRequest = request.id
        let target = request.zoomIn ? (Self.zoomSteps.first { $0 > scale + 0.01 } ?? scale) : (Self.zoomSteps.last { $0 < scale - 0.01 } ?? 1)
        guard target != scale else { return }
        endStrandedDrag()
        UIView.animate(withDuration: 0.2) {
            if target <= 1 { self.resetZoom(); return }
            let m = CGPoint(x: self.bounds.midX, y: self.bounds.midY), factor = target / self.scale
            self.offset = CGPoint(x: m.x - factor * (m.x - self.offset.x), y: m.y - factor * (m.y - self.offset.y))
            self.scale = target
            self.clampOffset()
            self.applyZoom()
        } completion: { _ in self.reportViewport() }
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
        applyZoom()
    }

    @objc private func handleResetZoom(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, scale > 1 else { return }
        UIView.animate(withDuration: 0.2) { self.resetZoom() } completion: { _ in self.reportViewport() }
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
            reportViewport()
        }
    }

    /// UIKit scales a view about its centre; the zoom maths (and `toContent`) work about the top-left corner,
    /// so shift the translation by the centre's movement: p = offset + scale · q for every point q.
    private func applyZoom() {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        screen.transform = CGAffineTransform(translationX: offset.x + (scale - 1) * c.x, y: offset.y + (scale - 1) * c.y)
            .scaledBy(x: scale, y: scale)
        accessibilityValue = String(format: "zoom %.1f", scale)
        placeCursor()
    }

    /// The scaled frame never shows background inside its edges: centre the axis where the image
    /// is smaller than the view, and clamp the other so it always covers.
    private func clampOffset() {
        guard scale > 1, fitRect.width > 0 else { offset = .zero; return }
        let scaled = fitRect.applying(CGAffineTransform(scaleX: scale, y: scale))
        // Between showing the image's far edge at the view's far edge (most negative) and its near edge at the
        // view's near edge.
        if scaled.width >= bounds.width {
            offset.x = min(-scaled.minX, max(bounds.width - scaled.maxX, offset.x))
        } else {
            offset.x = (bounds.width - scaled.width) / 2 - scaled.minX
        }
        if scaled.height >= bounds.height {
            offset.y = min(-scaled.minY, max(bounds.height - scaled.maxY, offset.y))
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
        if gesture.numberOfTouches > 1 || pinchActive || scrollActive || twoFingers != .undecided {
            endStrandedDrag()
            dragStart = nil
            trackpadLast = nil
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
        if mode == .trackpad { movePointer(gesture); return }
        let point = toContent(gesture.location(in: self))
        switch gesture.state {
        case .began:
            // Where the finger first touched, not where the pan was recognised ~10 pt later.
            let loc = gesture.location(in: self), moved = gesture.translation(in: self)
            dragStart = toContent(CGPoint(x: loc.x - moved.x, y: loc.y - moved.y))
        case .changed:
            if !dragging, let start = dragStart, hypot(point.x - start.x, point.y - start.y) > 4, let p = normalise(start) {
                dragging = true
                onInput?(.pointerDown(x: p.x, y: p.y, button: .left))
            }
            if dragging, let p = normalise(point) {
                onInput?(.pointerMove(x: p.x, y: p.y))
            }
        case .ended:
            defer { dragging = false; dragStart = nil }
            guard dragging, let p = normalise(point) else { return }
            onInput?(.pointerUp(x: p.x, y: p.y, button: .left))
        case .cancelled, .failed:
            if dragging, let p = normalise(point) {
                onInput?(.pointerUp(x: p.x, y: p.y, button: .left))
            }
            dragging = false
            dragStart = nil
        default:
            break
        }
    }

    /// Trackpad mode: the finger moves the pointer by how far it moved, finer when zoomed in.
    private func movePointer(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            trackpadLast = t
        case .changed:
            guard let last = trackpadLast else { trackpadLast = t; return }
            trackpadLast = t
            nudgeCursor(by: CGPoint(x: t.x - last.x, y: t.y - last.y))
        default:
            trackpadLast = nil
        }
    }

    private func nudgeCursor(by delta: CGPoint) {
        let current = cursor ?? CGPoint(x: fitRect.midX, y: fitRect.midY)
        let moved = CGPoint(x: current.x + delta.x / scale, y: current.y + delta.y / scale)
        cursor = CGPoint(x: min(max(moved.x, fitRect.minX), fitRect.maxX - 0.5), y: min(max(moved.y, fitRect.minY), fitRect.maxY - 0.5))
        placeCursor()
        if let c = cursor, let p = normalise(c) { onInput?(.pointerMove(x: p.x, y: p.y)) }
    }

    /// One finger, lifted without moving: a click (where it touched, or at the trackpad pointer), or a double click
    /// when it follows the last one closely.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, interactive, !pinchActive, !scrollActive else { return }
        let point = mode == .trackpad ? (cursor ?? CGPoint(x: fitRect.midX, y: fitRect.midY)) : toContent(gesture.location(in: self))
        guard let p = normalise(point) else { return }
        let now = Date()
        let near = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 12
        let count = (now.timeIntervalSince(lastClickAt) < 0.35 && near) ? 2 : 1
        lastClickAt = now
        lastClickPoint = point
        if mode == .trackpad, cursor == nil { cursor = point; placeCursor() }
        showMarker(at: point)
        onInput?(.click(x: p.x, y: p.y, button: .left, count: count))
    }

    /// Two fingers, one tap: a right click (at the trackpad pointer, or between the fingers).
    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, interactive, !pinchActive, !scrollActive else { return }
        let point = mode == .trackpad ? (cursor ?? CGPoint(x: fitRect.midX, y: fitRect.midY)) : toContent(gesture.location(in: self))
        guard let p = normalise(point) else { return }
        showMarker(at: point)
        onInput?(.click(x: p.x, y: p.y, button: .right, count: 1))
    }

    /// A drag that never saw its end (tab change, takeover handoff) must release the mouse.
    private func endStrandedDrag() {
        defer { dragging = false; dragStart = nil; trackpadLast = nil }
        guard dragging else { return }
        if let p = (mode == .trackpad ? cursor : dragStart).flatMap(normalise) {
            onInput?(.pointerUp(x: p.x, y: p.y, button: .left))
        }
    }

    /// Touch mode: hold for a right click. Trackpad mode: hold, then move to drag, and lift to drop.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if mode == .trackpad {
            switch gesture.state {
            case .began:
                suppressPointerUntilLift = true
                trackpadLast = gesture.location(in: self)
                let at = cursor ?? CGPoint(x: fitRect.midX, y: fitRect.midY)
                cursor = at
                placeCursor()
                guard interactive, let p = normalise(at) else { return }
                dragging = true
                showMarker(at: at)
                onInput?(.pointerDown(x: p.x, y: p.y, button: .left))
            case .changed:
                let loc = gesture.location(in: self)
                if let last = trackpadLast { nudgeCursor(by: CGPoint(x: loc.x - last.x, y: loc.y - last.y)) }
                trackpadLast = loc
            case .ended, .cancelled, .failed:
                suppressPointerUntilLift = false
                trackpadLast = nil
                if dragging, let p = cursor.flatMap(normalise) { onInput?(.pointerUp(x: p.x, y: p.y, button: .left)) }
                dragging = false
            default:
                break
            }
            return
        }
        switch gesture.state {
        case .began:
            suppressPointerUntilLift = true
            let point = toContent(gesture.location(in: self))
            guard interactive, let p = normalise(point) else { return }
            showMarker(at: point)
            onInput?(.click(x: p.x, y: p.y, button: .right, count: 1))
        case .ended, .cancelled, .failed:
            suppressPointerUntilLift = false
        default:
            break
        }
    }

    // MARK: Scroll (two fingers)

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            twoFingerLast = translation
        case .changed:
            if twoFingers == .undecided, hypot(translation.x, translation.y) > 12 {
                twoFingers = .scroll
                scrollActive = true
                endStrandedDrag()
                twoFingerLast = translation
                // Zoomed in, the view moves from here on, without jumping by the distance it took to decide.
                panOrigin = CGPoint(x: offset.x - translation.x, y: offset.y - translation.y)
            }
            guard twoFingers == .scroll else { return }
            // Zoomed in, two fingers move the view; at full size they scroll the Mac.
            if scale > 1, let origin = panOrigin {
                offset = CGPoint(x: origin.x + translation.x, y: origin.y + translation.y)
                clampOffset()
                applyZoom()
                return
            }
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
            panOrigin = nil
            twoFingersEnded()
            reportViewport()
        default:
            break
        }
    }

    // MARK: Pointer and click marks

    /// The trackpad pointer, drawn where it is (through the zoom); hidden in touch mode and while only watching.
    private func placeCursor() {
        let show = mode == .trackpad && interactive && fitRect.width > 0
        if show, cursor == nil { cursor = CGPoint(x: fitRect.midX, y: fitRect.midY) }
        cursorView.isHidden = !show
        guard show, let c = cursor else { return }
        let p = toView(c)
        let size = cursorView.intrinsicContentSize
        // The arrow's tip sits a little inside the symbol's top-left corner.
        cursorView.frame = CGRect(x: p.x - size.width * 0.18, y: p.y - size.height * 0.1, width: size.width, height: size.height)
    }

    /// A ring that fades where a click landed, so it's clear what the Mac was told.
    private func showMarker(at content: CGPoint) {
        let p = toView(content)
        marker.layer.removeAllAnimations()
        marker.center = p
        marker.alpha = 1
        marker.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.45, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.marker.alpha = 0
            self.marker.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        }
    }

    // MARK: Coordinates

    /// A point in view space back through the zoom transform into the untransformed image space.
    private func toContent(_ p: CGPoint) -> CGPoint {
        guard scale > 1 else { return p }
        return CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    /// A point in the untransformed image space where it shows on screen.
    private func toView(_ q: CGPoint) -> CGPoint {
        guard scale > 1 else { return q }
        return CGPoint(x: offset.x + scale * q.x, y: offset.y + scale * q.y)
    }

    private func recomputeFit() {
        guard let size = screen.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { fitRect = .zero; return }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        let fit = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        guard fit != fitRect else { return }
        // Keep the trackpad pointer on the same spot of the Mac's screen when the view's size changes.
        if let c = cursor, fitRect.width > 0 {
            cursor = CGPoint(x: fit.minX + (c.x - fitRect.minX) / fitRect.width * fit.width, y: fit.minY + (c.y - fitRect.minY) / fitRect.height * fit.height)
        }
        fitRect = fit
        placeDetail()
        if scale > 1 { clampOffset(); applyZoom() } else { placeCursor() }
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

/// Lets the one-finger pointer run alongside a developing pinch or scroll (it yields as soon as the second finger
/// registers), and pinch alongside two-finger pan so the screen can tell them apart by the first movement; long
/// press stays exclusive, so a single touch sequence never fires two actions at once.
private final class TouchGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    /// A scroll view around the screen (the Computer tab) waits for the screen's own gestures, so a drag, pinch or
    /// two-finger move that starts on the screen goes to the screen instead of scrolling the page.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let outer = otherGestureRecognizer.view as? UIScrollView, let screen = gestureRecognizer.view else { return false }
        return screen.isDescendant(of: outer) && otherGestureRecognizer === outer.panGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let pair: Set<Int> = [Self.kind(gestureRecognizer), Self.kind(otherGestureRecognizer)]
        // Pinch and two-finger pan both watch every two-finger touch; the screen decides which one acts.
        return pair == [1, 2] || pair == [2, 3] || pair == [1, 3]
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
