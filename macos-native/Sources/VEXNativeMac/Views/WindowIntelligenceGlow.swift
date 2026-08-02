import AppKit
import SwiftUI

/// Installs a transparent child window around the main NSWindow. This is the
/// smallest AppKit boundary that can render beyond the native title bar.
struct WindowIntelligenceGlow: NSViewRepresentable {
    let isActive: Bool

    func makeNSView(context: Context) -> WindowGlowAttachmentView {
        WindowGlowAttachmentView(isActive: isActive)
    }

    func updateNSView(_ nsView: WindowGlowAttachmentView, context: Context) {
        nsView.update(isActive: isActive)
    }

    static func dismantleNSView(
        _ nsView: WindowGlowAttachmentView,
        coordinator: Void
    ) {
        nsView.removeWindowGlow()
    }
}

@MainActor
final class WindowGlowAttachmentView: NSView {
    private var isActive: Bool
    private var glowHost: PassthroughHostingView<WindowIntelligenceGlowContent>?
    private weak var mainWindow: NSWindow?
    private var glowWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var pendingFrameSync: Task<Void, Never>?

    init(isActive: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            if let self,
               let mainWindow = self.mainWindow,
               mainWindow !== self.window {
                self.removeWindowGlow()
            }
            self?.installWindowGlowIfNeeded()
        }
    }

    func update(isActive: Bool) {
        self.isActive = isActive
        installWindowGlowIfNeeded()
        glowHost?.rootView = makeContent()
        glowWindow?.alphaValue = isActive ? 1 : 0
        scheduleGlowFrameSync()
    }

    func removeWindowGlow() {
        pendingFrameSync?.cancel()
        pendingFrameSync = nil

        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        if let glowWindow {
            mainWindow?.removeChildWindow(glowWindow)
            glowWindow.orderOut(nil)
            glowWindow.close()
        }

        glowHost = nil
        glowWindow = nil
        mainWindow = nil
    }

    private func installWindowGlowIfNeeded() {
        guard glowHost == nil,
              let window else {
            return
        }

        let overlay = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        overlay.level = window.level
        overlay.alphaValue = isActive ? 1 : 0

        let host = PassthroughHostingView(rootView: makeContent())
        host.frame = overlay.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.contentView = host

        mainWindow = window
        glowWindow = overlay
        glowHost = host
        syncGlowFrame()
        window.addChildWindow(overlay, ordered: .below)
        observeWindowGeometry(window)
    }

    private func observeWindowGeometry(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let observer = center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleGlowFrameSync()
                }
            }
            windowObservers.append(observer)
        }
    }

    private func scheduleGlowFrameSync() {
        pendingFrameSync?.cancel()
        pendingFrameSync = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            pendingFrameSync = nil
            syncGlowFrame()
        }
    }

    private func syncGlowFrame() {
        guard let mainWindow, let glowWindow else { return }
        let targetFrame = mainWindow.frame.insetBy(dx: -10, dy: -10)
        guard glowWindow.frame != targetFrame else { return }
        glowWindow.setFrame(targetFrame, display: false)
    }

    private func makeContent() -> WindowIntelligenceGlowContent {
        WindowIntelligenceGlowContent(isActive: isActive)
    }
}

@MainActor
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct WindowIntelligenceGlowContent: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 45.0,
                paused: !isActive || accessibilityReduceMotion
            )
        ) { timeline in
            let time = isActive && !accessibilityReduceMotion
                ? timeline.date.timeIntervalSinceReferenceDate
                : 0

            Canvas(rendersAsynchronously: true) { context, size in
                guard isActive else { return }
                let rect = CGRect(origin: .zero, size: size)
                    .insetBy(dx: 18, dy: 18)
                let perimeter = RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .path(in: rect)

                // One short rounded segment reads as an intentional travelling
                // highlight instead of a rainbow outline around the window.
                let snake = wrappedSegment(
                    perimeter,
                    start: normalized(time * 0.052),
                    length: 0.16
                )

                var bloom = context
                bloom.addFilter(.blur(radius: 13))
                bloom.stroke(
                    snake,
                    with: .color(Color.vexCyan.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                )

                var softCore = context
                softCore.addFilter(.blur(radius: 4))
                softCore.stroke(
                    snake,
                    with: .color(Color.vexCyanLight.opacity(0.88)),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )

                context.stroke(
                    snake,
                    with: .color(Color.white.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
                )
            }
            .opacity(isActive ? 1 : 0)
        }
        .background(Color.clear)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private func wrappedSegment(
        _ path: Path,
        start: Double,
        length: Double
    ) -> Path {
        let end = start + length
        guard end > 1 else {
            return path.trimmedPath(from: start, to: end)
        }

        var result = Path()
        result.addPath(path.trimmedPath(from: start, to: 1))
        result.addPath(path.trimmedPath(from: 0, to: end - 1))
        return result
    }
}
