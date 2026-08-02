import AppKit
import Combine
import SwiftUI

@MainActor
final class VEXStatusItemController: NSObject {
    private let helper: VEXHelperModel
    private let appState: VEXAppState
    private let item: NSStatusItem
    private var panel: VEXTrayPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    init(helper: VEXHelperModel, appState: VEXAppState) {
        self.helper = helper
        self.appState = appState
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = Self.statusItemImage()
            button.imagePosition = .imageOnly
            button.title = ""
            button.contentTintColor = .white
            button.target = self
            button.action = #selector(togglePanel)
            // preventWindowOrdering must run in the mouse-down event that
            // triggered the status item. Calling it from mouse-up can leave the
            // next click on the main window unable to order that window front.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "Открыть VEX"
        }
        item.menu = nil

        observeState()
        refresh()
    }

    private static func statusItemImage() -> NSImage {
        let image = NSImage(
            size: NSSize(width: 57, height: 18),
            flipped: false
        ) { _ in
            let symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 15,
                weight: .semibold
            ).applying(
                NSImage.SymbolConfiguration(paletteColors: [.white])
            )
            let symbol = NSImage(
                systemSymbolName: "shield.lefthalf.filled",
                accessibilityDescription: "VEX"
            )?.withSymbolConfiguration(symbolConfiguration)
            symbol?.draw(
                in: NSRect(x: 0, y: 1, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )

            ("VEX" as NSString).draw(
                at: NSPoint(x: 21, y: 2),
                withAttributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
                ]
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    func refresh() {
        guard let button = item.button else { return }
        button.appearsDisabled = false
        button.contentTintColor = .white
        button.toolTip = "\(statusTitle) · \(locationTitle)"
        panel?.contentView?.needsDisplay = true
    }

    @objc private func togglePanel() {
        NSApp.preventWindowOrdering()
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = item.button,
              let buttonWindow = button.window else {
            return
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = buttonWindow.convertToScreen(buttonFrameInWindow)
        let screenFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let finalFrame = VEXTrayLayout.panelFrame(
            below: buttonFrame,
            inside: screenFrame,
            size: panel.frame.size
        )
        let initialFrame = finalFrame.offsetBy(dx: 0, dy: 18)

        removeEventMonitors()
        panel.alphaValue = 0
        panel.setFrame(initialFrame, display: false)
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.popUpMenu.rawValue + 1
        )
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard self?.panel?.isVisible == true else { return }
            self?.installEventMonitors()
        }
    }

    private func hidePanel(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        removeEventMonitors()

        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        let hiddenFrame = panel.frame.offsetBy(dx: 0, dy: 12)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(hiddenFrame, display: true)
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    private func makePanel() -> VEXTrayPanel {
        let panel = VEXTrayPanel(
            helper: helper,
            appState: appState,
            onOpenApp: { [weak self] in self?.showMainWindow() },
            onOpenSettings: { [weak self] in self?.showMainWindow(section: .settings) },
            onQuit: { NSApp.terminate(nil) }
        )
        panel.onRequestClose = { [weak self] in
            self?.hidePanel()
        }
        return panel
    }

    private func installEventMonitors() {
        guard globalEventMonitor == nil, localEventMonitor == nil else { return }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanelIfPointerIsOutside()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                hidePanel()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if let panel, event.windowNumber == panel.windowNumber {
                    return event
                }
                if let statusWindowNumber = item.button?.window?.windowNumber,
                   event.windowNumber == statusWindowNumber {
                    return event
                }
                hidePanelIfPointerIsOutside()
            }
            return event
        }
    }

    private func hidePanelIfPointerIsOutside() {
        let pointer = NSEvent.mouseLocation
        if let panel,
           panel.frame.insetBy(dx: -8, dy: -8).contains(pointer) {
            return
        }
        guard statusItemFrame?.contains(pointer) != true else { return }
        hidePanel()
    }

    private var statusItemFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func removeEventMonitors() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func observeState() {
        helper.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSoon() }
            .store(in: &cancellables)
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSoon() }
            .store(in: &cancellables)
    }

    private func refreshSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    private func showMainWindow(section: AppSection? = nil) {
        hidePanel(animated: false)
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(
            options: [.activateAllWindows]
        )
        NSApp.activate()

        let mainWindow = NSApp.windows.first { window in
            window.contentViewController != nil && window.frame.width >= 800
        }
        mainWindow?.level = .normal
        mainWindow?.orderFrontRegardless()
        mainWindow?.makeKeyAndOrderFront(nil)

        if let section {
            VEXSettingsWindow.open(section: section)
        }
    }

    private var statusTitle: String {
        switch helper.status.state {
        case .connected:
            return "VEX подключён"
        case .connecting:
            return "VEX подключается"
        case .disconnecting:
            return "VEX отключается"
        case .disconnected:
            return "VEX отключён"
        }
    }

    private var locationTitle: String {
        let location = appState.selectedLocation?.displayName ?? appState.selectedLocationId.uppercased()
        return location.isEmpty ? "Сервер не выбран" : location
    }

}

@MainActor
final class VEXTrayPanel: NSPanel {
    var onRequestClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(
        helper: VEXHelperModel,
        appState: VEXAppState,
        onOpenApp: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        let rootView = VEXTrayPanelView(
            helper: helper,
            appState: appState,
            onOpenApp: onOpenApp,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
        let hostingView = NSHostingView(rootView: rootView)

        super.init(
            contentRect: NSRect(origin: .zero, size: VEXTrayLayout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        contentView = hostingView
        let window: NSPanel = self
        window.level = NSWindow.Level(
            rawValue: NSWindow.Level.popUpMenu.rawValue + 1
        )
        window.backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        animationBehavior = .none
        collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 22
        contentView?.layer?.masksToBounds = true
    }

    override func cancelOperation(_ sender: Any?) {
        onRequestClose?()
    }
}
