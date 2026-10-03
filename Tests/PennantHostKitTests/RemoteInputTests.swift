import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// The owner's pointer from the iPhone's live screen: refused until they take control, then applied through the live
/// path (no settling pause, drags while a button is down) in the order it arrives.
final class RemoteInputTests: XCTestCase {
    func testTheOwnersPointerTakesTheLivePathOnceTheyHaveControl() async throws {
        let paths = HostPaths.temporary()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let desktop = FakeDesktop()
        let s = try HostService(paths: paths, config: config, desktop: desktop, humanInput: NullHumanInput(), provider: ScriptedProvider([]))
        try await s.start(startAPI: false)
        let phone = ConnectedClient(id: ClientID("phone"), displayName: "iPhone", platform: "iOS")

        guard case .error(let code, _) = await s.handle(.remoteInput(.click(x: 0.5, y: 0.5, button: .left, count: 1)), from: phone) else {
            return XCTFail("input before taking control was applied")
        }
        XCTAssertEqual(code, "no_control")

        _ = await s.handle(.takeoverDesktop, from: phone)
        let inputs: [RemoteInput] = [.pointerDown(x: 0.25, y: 0.5, button: .left), .pointerMove(x: 0.5, y: 0.5), .pointerUp(x: 0.75, y: 0.5, button: .left),
                                     .click(x: 0.1, y: 0.1, button: .right, count: 1)]
        for input in inputs {
            guard case .ok = await s.handle(.remoteInput(input), from: phone) else { return XCTFail("\(input) was refused") }
        }
        XCTAssertEqual(desktop.actions.filter { $0.hasPrefix("live-") },
                       ["live-down-left(400,500)", "live-move(800,500)", "live-up-left(1200,500)", "live-click-rightx1(160,100)"])
        await s.stop()
    }
}

/// Capturing part of the display: where it is in points, at its full resolution unless that's wider than asked.
final class RegionCaptureTests: XCTestCase {
    func testARegionIsCapturedAtItsOwnResolution() {
        // A quarter of a 1728×1117-point Retina display: 864×558 points, so 1728 pixels wide.
        let quarter = ScreenCapturer.regionCapture(ScreenRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5), maxWidth: 1920, displayWidth: 1728, displayHeight: 1117, pixelScale: 2)
        XCTAssertEqual(quarter.rect.origin.x, 864, accuracy: 0.5)
        XCTAssertEqual(quarter.rect.origin.y, 558.5, accuracy: 0.5)
        XCTAssertEqual(quarter.width, 1728)
        XCTAssertEqual(quarter.height, 1117)
        // Most of the display: held to the width asked for, the shape kept.
        let most = ScreenCapturer.regionCapture(ScreenRegion(x: 0, y: 0, width: 0.8, height: 0.8), maxWidth: 1920, displayWidth: 1728, displayHeight: 1117, pixelScale: 2)
        XCTAssertEqual(most.width, 1920)
        XCTAssertEqual(Double(most.height), 1920 * 1117.0 / 1728.0, accuracy: 1)
    }
}
