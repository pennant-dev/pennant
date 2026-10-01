import AppKit
import PennantUI
import SwiftUI

/// View › Zoom In, Zoom Out and Actual Size (⌘+, ⌘−, ⌘0): the text across Pennant's windows and sheets, larger or
/// smaller, remembered across launches (`PennantZoom`). Layouts and column widths stay as they are; the text and the
/// symbols set with it grow inside them.
struct ZoomCommands: Commands {
    private let zoom = PennantZoom.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { zoom.zoomIn() }.keyboardShortcut("+", modifiers: .command).disabled(!zoom.canZoomIn)
            Button("Zoom Out") { zoom.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(!zoom.canZoomOut)
            Button("Actual Size") { zoom.actualSize() }.keyboardShortcut("0", modifiers: .command).disabled(zoom.isActualSize)
            Divider()
        }
    }

    /// ⌘= zooms in too: on most keyboards + needs Shift, and browsers take both.
    @MainActor static func acceptCommandEquals() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "=" else { return event }
            MainActor.assumeIsolated { PennantZoom.shared.zoomIn() }
            return nil
        }
    }
}
