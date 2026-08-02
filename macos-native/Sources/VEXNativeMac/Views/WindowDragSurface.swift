import AppKit
import SwiftUI

/// Receives only pointer events that reach the uncovered client background.
/// Controls remain above this surface and keep their normal interactions.
struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSurfaceView {
        DragSurfaceView()
    }

    func updateNSView(_ nsView: DragSurfaceView, context: Context) {}
}

final class DragSurfaceView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.performDrag(with: event)
    }
}
