import XCTest

/// The iPhone's live screen, driven with real touches in the simulator against the debug touch lab (a test grid the
/// shape of a Mac display, no host): pinch zooms, a tap clicks where it touches, and trackpad mode moves a pointer.
@MainActor
final class TouchScreenUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ pointer: String) -> (XCUIApplication, XCUIElement, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["PENNANT_DEBUG_SCREEN"] = "touchlab"
        app.launchEnvironment["PENNANT_DEBUG_POINTER"] = pointer
        app.launch()
        let screen = app.descendants(matching: .any)["live-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "the live screen shows")
        return (app, screen, app.staticTexts["last-input"])
    }

    /// "click left 0.250 0.500 1" → its numbers.
    private func numbers(_ label: String) -> [Double] { label.split(separator: " ").compactMap { Double($0) } }

    func testPinchZoomsTheScreen() {
        let (_, screen, _) = launch("touch")
        XCTAssertEqual(screen.value as? String, "zoom 1.0")
        screen.pinch(withScale: 3, velocity: 3)
        let zoom = Double((screen.value as? String)?.replacingOccurrences(of: "zoom ", with: "") ?? "") ?? 0
        XCTAssertGreaterThan(zoom, 1.5, "pinching out zooms in")
    }

    func testATapClicksWhereItTouches() {
        let (_, screen, last) = launch("touch")
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6)).tap()
        XCTAssertTrue(last.label.hasPrefix("click left"), last.label)
        let n = numbers(last.label)
        XCTAssertEqual(n[0], 0.25, accuracy: 0.02)
        XCTAssertEqual(n[1], 0.6, accuracy: 0.02)
    }

    func testATapStillLandsRightWhenZoomedIn() {
        let (app, screen, last) = launch("touch")
        // The zoom button zooms about the middle: 1.5×, then the middle of the view is still the middle of the Mac,
        // and a quarter of the view right of it is a sixth of the Mac right of it.
        app.buttons["zoom-in"].tap()
        XCTAssertEqual(screen.value as? String, "zoom 1.5")
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        var n = numbers(last.label)
        XCTAssertTrue(last.label.hasPrefix("click left"), last.label)
        XCTAssertEqual(n[0], 0.5, accuracy: 0.02)
        XCTAssertEqual(n[1], 0.5, accuracy: 0.02)
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25)).tap()
        n = numbers(last.label)
        XCTAssertEqual(n[0], 0.5 + 0.25 / 1.5, accuracy: 0.02)
        XCTAssertEqual(n[1], 0.5 - 0.25 / 1.5, accuracy: 0.02)
    }

    func testATwoFingerTapIsARightClick() {
        let (_, screen, last) = launch("touch")
        screen.twoFingerTap()
        // It waits out a possible second tap (two-finger double tap zooms back out) before right-clicking.
        let rightClick = expectation(for: NSPredicate(format: "label BEGINSWITH 'click right'"), evaluatedWith: last)
        wait(for: [rightClick], timeout: 3)
        let n = numbers(last.label)
        XCTAssertEqual(n[0], 0.5, accuracy: 0.05)
        XCTAssertEqual(n[1], 0.5, accuracy: 0.05)
    }

    func testADragInTouchModeLetsGoWhereTheFingerLifts() {
        let (_, screen, last) = launch("touch")
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(last.label.hasPrefix("up left"), last.label)
        let n = numbers(last.label)
        XCTAssertEqual(n[0], 0.7, accuracy: 0.03)
        XCTAssertEqual(n[1], 0.6, accuracy: 0.03)
    }

    func testTrackpadMovesThePointerAndClicksWhereItIs() {
        let (_, screen, last) = launch("trackpad")
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        XCTAssertTrue(last.label.hasPrefix("move"), last.label)
        let moved = numbers(last.label)
        XCTAssertGreaterThan(moved[0], 0.6, "the pointer started in the middle and moved right")
        // A tap anywhere clicks where the pointer is, not where the finger is.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        let click = numbers(last.label)
        XCTAssertTrue(last.label.hasPrefix("click left"), last.label)
        XCTAssertEqual(click[0], moved[0], accuracy: 0.01)
        XCTAssertEqual(click[1], moved[1], accuracy: 0.01)
    }

    func testZoomingInAsksForJustThePartInViewAndZoomingOutForAllOfIt() {
        let (app, _, _) = launch("touch")
        let viewport = app.staticTexts["viewport"]
        XCTAssertEqual(viewport.label, "whole")
        app.buttons["zoom-in"].tap()
        app.buttons["zoom-in"].tap()
        // At 2× about the middle, the middle half is in view; it's asked for with a margin.
        let asked = expectation(for: NSPredicate(format: "label != 'whole'"), evaluatedWith: viewport)
        wait(for: [asked], timeout: 3)
        let n = numbers(viewport.label)
        XCTAssertEqual(n.count, 4, viewport.label)
        XCTAssertEqual(n[0] + n[2] / 2, 0.5, accuracy: 0.03, "centred")
        XCTAssertLessThan(n[2], 0.8, "only part of the width")
        XCTAssertGreaterThan(n[2], 0.5, "what's in view, with a margin")
        app.buttons["zoom-out"].tap()
        app.buttons["zoom-out"].tap()
        app.buttons["zoom-out"].tap()
        let whole = expectation(for: NSPredicate(format: "label == 'whole'"), evaluatedWith: viewport)
        wait(for: [whole], timeout: 3)
    }

    func testTheKeyboardTypesStraightOntoTheMac() {
        let (app, _, last) = launch("touch")
        app.buttons["keyboard"].tap()
        XCTAssertEqual(app.textFields.count, 0, "no text field in between")
        app.typeText("hi")
        XCTAssertEqual(last.label, "type i")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(last.label, "key delete")
        app.typeText("\n")
        XCTAssertEqual(last.label, "key return")
    }
}

