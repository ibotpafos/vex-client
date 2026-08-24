import AppKit
import QuartzCore
import SwiftUI

enum VEXServerSidebarWindow {
    static let toggleNotification = Notification.Name("VEXToggleServerSidebar")
    static let closeNotification = Notification.Name("VEXCloseServerSidebar")

    @MainActor
    static func toggle() {
        NotificationCenter.default.post(name: toggleNotification, object: nil)
    }

    @MainActor
    static func close() {
        NotificationCenter.default.post(name: closeNotification, object: nil)
    }
}

enum ServerSidebarPlacement {
    static let gap: CGFloat = 16
    static let panelWidth: CGFloat = 350
    static let openingTravel: CGFloat = 22

    static func panelSize(mainWindowFrame: NSRect, visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: panelWidth,
            height: min(mainWindowFrame.height, visibleFrame.height)
        )
    }

    static func frame(
        mainWindowFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        let rightX = mainWindowFrame.maxX + gap
        let leftX = mainWindowFrame.minX - gap - panelSize.width
        let x: CGFloat

        if rightX + panelSize.width <= visibleFrame.maxX {
            x = rightX
        } else if leftX >= visibleFrame.minX {
            x = leftX
        } else {
            x = min(
                max(rightX, visibleFrame.minX),
                max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
            )
        }

        let centeredY = mainWindowFrame.midY - panelSize.height / 2
        let y = min(
            max(centeredY, visibleFrame.minY),
            max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        )

        return NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
    }

    static func openingFrame(targetFrame: NSRect, mainWindowFrame: NSRect) -> NSRect {
        let opensToRight = targetFrame.midX >= mainWindowFrame.midX
        return targetFrame.offsetBy(
            dx: opensToRight ? -openingTravel : openingTravel,
            dy: 0
        )
    }
}

enum ServerSidebarSearch {
    static func matches(query: String, values: [String]) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let queryVariants = Set([
            normalizedQuery,
            normalized(transliterated(query))
        ])
        return values.contains { value in
            let valueVariants = [
                normalized(value),
                normalized(transliterated(value))
            ]
            return queryVariants.contains { queryVariant in
                valueVariants.contains { $0.contains(queryVariant) }
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func transliterated(_ value: String) -> String {
        value.applyingTransform(.toLatin, reverse: false) ?? value
    }
}

@MainActor
final class ServerSidebarWindowController: NSObject {
    private let appState: VEXAppState
    private let helper: VEXHelperModel
    private weak var mainWindow: NSWindow?
    private var panel: VEXServerSidebarPanelWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var panelClickMonitor: Any?

    init(appState: VEXAppState, helper: VEXHelperModel) {
        self.appState = appState
        self.helper = helper
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggle(relativeTo mainWindow: NSWindow) {
        isVisible ? close() : show(relativeTo: mainWindow)
    }

    func show(relativeTo mainWindow: NSWindow) {
        close(animated: false)
        self.mainWindow = mainWindow

        let visibleFrame = mainWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? mainWindow.frame
        let panelSize = ServerSidebarPlacement.panelSize(
            mainWindowFrame: mainWindow.frame,
            visibleFrame: visibleFrame
        )
        let rootView = ServerSidebarPanel { [weak self] in
            self?.close()
        }
        .environmentObject(appState)
        .environmentObject(helper)

        let panel = VEXServerSidebarPanelWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: rootView)
        panel.setContentSize(panelSize)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.borderWidth = 0
        panel.contentView?.layer?.cornerRadius = 16
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
        observeMainWindow(mainWindow)
        installPanelClickMonitor(panel: panel, mainWindow: mainWindow)
        let targetFrame = sidebarFrame(relativeTo: mainWindow, panel: panel)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.setFrame(targetFrame, display: false)
            panel.alphaValue = 1
        } else {
            panel.setFrame(
                ServerSidebarPlacement.openingFrame(
                    targetFrame: targetFrame,
                    mainWindowFrame: mainWindow.frame
                ),
                display: false
            )
            panel.alphaValue = 0
        }
        mainWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            animateOpen(panel, to: targetFrame)
        }
    }

    func close() {
        close(animated: true)
    }

    private func close(animated: Bool) {
        removeWindowObservers()
        guard let panel else {
            mainWindow = nil
            return
        }
        let owner = mainWindow
        self.panel = nil
        mainWindow = nil

        let finish = {
            owner?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        guard animated,
              panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            finish()
            return
        }

        let closingFrame = ServerSidebarPlacement.openingFrame(
            targetFrame: panel.frame,
            mainWindowFrame: owner?.frame ?? panel.frame
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(closingFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            finish()
        }
    }

    private func observeMainWindow(_ window: NSWindow) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification
        ]

        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.reposition()
                }
            }
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
        if let monitor = self.panelClickMonitor {
            NSEvent.removeMonitor(monitor)
            self.panelClickMonitor = nil
        }
    }

    /// The sidebar is a borderless transparent NSPanel: SwiftUI hit-testing
    /// only covers painted controls, so clicks on empty areas used to fall
    /// through to windows behind it - the whole app lost focus and appeared
    /// to vanish. Swallow every click inside the panel frame and route
    /// activation back to the main window instead.
    private func installPanelClickMonitor(panel: NSPanel, mainWindow: NSWindow) {
        panelClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak panel] event in
            guard let self, let panel,
                  event.window === panel || panel.frame.contains(event.locationInWindow == .zero ? .zero : NSEvent.mouseLocation) else {
                return event
            }
            // Keep the click inside the panel (buttons still work: this only
            // catches events AppKit would otherwise send to other windows),
            // but never let it fall through to a window behind.
            if event.window !== panel {
                return nil
            }
            return event
        }
    }

    private func reposition() {
        guard let mainWindow, let panel else { return }
        panel.setFrame(sidebarFrame(relativeTo: mainWindow, panel: panel), display: true)
    }

    private func sidebarFrame(relativeTo mainWindow: NSWindow, panel: NSWindow) -> NSRect {
        let visibleFrame = mainWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? mainWindow.frame
        return ServerSidebarPlacement.frame(
            mainWindowFrame: mainWindow.frame,
            panelSize: ServerSidebarPlacement.panelSize(
                mainWindowFrame: mainWindow.frame,
                visibleFrame: visibleFrame
            ),
            visibleFrame: visibleFrame
        )
    }

    private func animateOpen(_ panel: NSWindow, to targetFrame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }
}

private final class VEXServerSidebarPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}
