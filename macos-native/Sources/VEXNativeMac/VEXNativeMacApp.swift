import AppKit
import Darwin
import SwiftUI

@MainActor
enum FocusPulseMainWindowConfiguration {
    static func apply(to window: NSWindow) {
        // Preserve the exact full-content geometry used by the custom chrome.
        // WindowDragSurface explicitly consumes and activates uncovered client
        // background clicks, so this borderless window does not become
        // click-through.
        window.styleMask = [.borderless, .resizable, .miniaturizable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            window.standardWindowButton(buttonType)?.isHidden = true
        }
        // AppKit moves uncovered client background directly; WindowDragSurface
        // remains the explicit first-click/drag path under SwiftUI content.
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
    }
}

@main
struct VEXNativeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var helper = VEXHelperModel()
    @StateObject private var appState = VEXAppState()

    init() {
        #if DEBUG
        if let request = VEXPreviewRenderer.request() {
            do {
                try VEXPreviewRenderer.render(request)
                FileHandle.standardOutput.write(Data("rendered=\(request.outputURL.path)\n".utf8))
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("preview render failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(2)
            }
        }
        #endif

        guard CommandLine.arguments.contains("--helper-status-probe") else { return }
        do {
            let response = try sendUnixSocketCommand(
                "status",
                socketPath: "/var/run/vex-helper.sock",
                timeoutSeconds: 3
            )
            FileHandle.standardOutput.write(Data(response.utf8))
            Darwin.exit(response.hasPrefix("state=") && response.contains("operation_in_progress=") ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("helper probe failed: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    var body: some Scene {
        Window("VEX", id: "main") {
            VEXLaunchContainer(skipAnimation: Self.isFocusPulsePreviewLaunch) {
                if Self.isFocusPulsePreviewLaunch {
                    return
                }
                appDelegate.configure(helper: helper, appState: appState)
                appState.prepareAutomaticUpdatesForStartup()
                await helper.start()
                await appState.start(helperStatus: helper.status)
            }
                .environmentObject(helper)
                .environmentObject(appState)
                .frame(minWidth: 920, minHeight: 580)
        }
        .defaultSize(width: 920, height: 580)
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appState.checkForNativeUpdates()
                }
                .disabled(!appState.canCheckForNativeUpdates)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    VEXSettingsWindow.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Серверы") {
                Button("Открыть список серверов") {
                    VEXServerSidebarWindow.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("VPN") {
                Button("Refresh Status") {
                    Task { await helper.refreshStatus() }
                }
                .keyboardShortcut("r")

                Divider()

                Button("Connect") {
                    Task { await appState.connectVPN(using: helper) }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Disconnect") {
                    Task { await appState.disconnectVPN(using: helper) }
                }
                .keyboardShortcut("d")
            }
        }

    }

    private static var isFocusPulsePreviewLaunch: Bool {
        VEXPreviewMode.suppressesRuntime
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let focusPulseWindowSize = NSSize(width: 920, height: 580)
    private var helper: VEXHelperModel?
    private var appState: VEXAppState?
    private var statusController: VEXStatusItemController?
    private var serverSidebarController: ServerSidebarWindowController?
    private var serverSidebarObservers: [NSObjectProtocol] = []
    private var mainWindowConfigurationAttempts = 0
    private var terminationInProgress = false
    private var mainWindowActivationMonitor: Any?

    func configure(helper: VEXHelperModel, appState: VEXAppState) {
        self.helper = helper
        self.appState = appState
        if statusController == nil {
            statusController = VEXStatusItemController(helper: helper, appState: appState)
        }
        if serverSidebarController == nil {
            serverSidebarController = ServerSidebarWindowController(appState: appState, helper: helper)
            installServerSidebarObservers()
        }
        statusController?.refresh()
    }

    private func installServerSidebarObservers() {
        let center = NotificationCenter.default
        serverSidebarObservers = [
            center.addObserver(
                forName: VEXServerSidebarWindow.toggleNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let mainWindow = self.mainAppWindow else { return }
                    self.serverSidebarController?.toggle(relativeTo: mainWindow)
                }
            },
            center.addObserver(
                forName: VEXServerSidebarWindow.closeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.serverSidebarController?.close()
                }
            }
        ]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DeepLinkRegistrationService.registerPreferredHandlers()
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(
            options: [.activateAllWindows]
        )
        NSApp.activate()
        DispatchQueue.main.async {
            self.configureMainWindow()
        }
    }

    private func configureMainWindow() {
        guard let window = mainAppWindow else {
            mainWindowConfigurationAttempts += 1
            guard mainWindowConfigurationAttempts < 80 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.configureMainWindow()
            }
            return
        }
        mainWindowConfigurationAttempts = 0
        FocusPulseMainWindowConfiguration.apply(to: window)
        window.isOpaque = false
        // Match the root SwiftUI surface with a nontransparent backing pixel.
        // WindowServer can otherwise route clicks through visually transparent
        // gaps at the top/bottom of a borderless window.
        window.backgroundColor = NSColor(
            red: 0.008,
            green: 0.039,
            blue: 0.043,
            alpha: 1
        )
        window.hasShadow = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 16
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.cornerRadius = 16
        window.contentView?.superview?.layer?.masksToBounds = true
        window.delegate = self
        installMainWindowActivationMonitor(for: window)
        window.center()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func installMainWindowActivationMonitor(for window: NSWindow) {
        if let mainWindowActivationMonitor {
            NSEvent.removeMonitor(mainWindowActivationMonitor)
        }
        mainWindowActivationMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self, weak window] event in
            guard let self, let window, event.window === window else {
                return event
            }
            activateMainWindow(window)
            return event
        }
    }

    private func activateMainWindow(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(
            options: [.activateAllWindows]
        )
        NSApp.activate()
        if let window = mainAppWindow {
            window.level = .normal
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        } else {
            configureMainWindow()
        }
    }

    private var mainAppWindow: NSWindow? {
        NSApp.windows.first { window in
            window.title == "VEX"
                && window.contentViewController != nil
                && window.frame.width >= 800
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        serverSidebarController?.close()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let helper else {
            return .terminateNow
        }
        guard !terminationInProgress else {
            return .terminateLater
        }
        terminationInProgress = true
        Task { @MainActor in
            await helper.shutdownForAppTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverSidebarController?.close()
        serverSidebarObservers.forEach(NotificationCenter.default.removeObserver)
        serverSidebarObservers.removeAll()
        if let mainWindowActivationMonitor {
            NSEvent.removeMonitor(mainWindowActivationMonitor)
            self.mainWindowActivationMonitor = nil
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let appState else { return }
        showMainWindow()
        for url in urls {
            Task { @MainActor in
                await appState.handleDeepLink(url)
                self.showMainWindow()
            }
        }
    }
}
