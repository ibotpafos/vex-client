import AppKit
import Combine
import SwiftUI

@main
struct VEXNativeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var helper = VEXHelperModel()
    @StateObject private var appState = VEXAppState()

    var body: some Scene {
        Window("VEX", id: "main") {
            ContentView()
                .environmentObject(helper)
                .environmentObject(appState)
                .frame(minWidth: 760, idealWidth: 860, minHeight: 720, idealHeight: 760)
                .task {
                    appDelegate.configure(helper: helper, appState: appState)
                    await helper.start()
                    await appState.start(helperStatus: helper.status)
                }
        }
        .defaultSize(width: 860, height: 760)
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

            CommandMenu("VPN") {
                Button("Refresh Status") {
                    Task { await helper.refreshStatus() }
                }
                .keyboardShortcut("r")

                Divider()

                Button("Connect") {
                    Task { await appState.connectVPN(using: helper) }
                }
                .keyboardShortcut("k")

                Button("Disconnect") {
                    Task { await appState.disconnectVPN(using: helper) }
                }
                .keyboardShortcut("d")
            }
        }

    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var helper: VEXHelperModel?
    private var appState: VEXAppState?
    private var statusController: VEXStatusItemController?
    private var mainWindowConfigurationAttempts = 0

    func configure(helper: VEXHelperModel, appState: VEXAppState) {
        self.helper = helper
        self.appState = appState
        if statusController == nil {
            statusController = VEXStatusItemController(helper: helper, appState: appState)
        }
        statusController?.refresh()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DeepLinkRegistrationService.registerPreferredHandlers()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            self.configureMainWindow()
        }
    }

    private func configureMainWindow() {
        guard let window = mainAppWindow else {
            mainWindowConfigurationAttempts += 1
            guard mainWindowConfigurationAttempts < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.configureMainWindow()
            }
            return
        }
        mainWindowConfigurationAttempts = 0
        let contentSize = NSSize(width: 860, height: 760)
        window.title = "VEX"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.toolbarStyle = .unified
        if #unavailable(macOS 15.0) {
            window.toolbar?.showsBaselineSeparator = false
        }
        window.backgroundColor = NSColor(
            red: 0.008,
            green: 0.039,
            blue: 0.043,
            alpha: 1
        )
        window.isMovableByWindowBackground = true
        window.setContentSize(contentSize)
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 720))).size
        window.styleMask.insert(.resizable)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainAppWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            configureMainWindow()
        }
    }

    private var mainAppWindow: NSWindow? {
        NSApp.windows.first { window in
            window.canBecomeMain && window.contentViewController != nil
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let helper else {
            return .terminateNow
        }
        Task { @MainActor in
            await helper.detachOwnerWatchdog(quiet: true)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

@MainActor
final class VEXStatusItemController: NSObject {
    private let helper: VEXHelperModel
    private let appState: VEXAppState
    private let item: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(helper: VEXHelperModel, appState: VEXAppState) {
        self.helper = helper
        self.appState = appState
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "VEX")
            button.title = " VEX"
        }
        refresh()
        observeState()
    }

    func refresh() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: statusTitle, action: nil, keyEquivalent: ""))
        if let detailTitle {
            menu.addItem(NSMenuItem(title: detailTitle, action: nil, keyEquivalent: ""))
        }
        if let locationTitle {
            menu.addItem(NSMenuItem(title: locationTitle, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Показать VEX", action: #selector(showWindow)))
        menu.addItem(menuItem(vpnActionTitle, action: vpnActionSelector, enabled: !helper.isBusy))
        menu.addItem(menuItem("Настройки", action: #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Выйти из VEX", action: #selector(quit)))
        item.menu = menu
    }

    private var statusTitle: String {
        switch helper.status.state {
        case .connected:
            return "VEX: подключено"
        case .connecting:
            return "VEX: подключение"
        case .disconnecting:
            return "VEX: отключение"
        case .disconnected:
            return "VEX: отключено"
        }
    }

    private var detailTitle: String? {
        switch helper.status.state {
        case .connected:
            let rx = ByteCountFormatter.string(fromByteCount: Int64(helper.status.rxBytes), countStyle: .file)
            let tx = ByteCountFormatter.string(fromByteCount: Int64(helper.status.txBytes), countStyle: .file)
            return "RX \(rx) · TX \(tx)"
        case .connecting, .disconnecting:
            return "Операция выполняется"
        case .disconnected:
            return VEXUserFacingText.status(appState.statusMessage)
        }
    }

    private var locationTitle: String? {
        guard let location = appState.selectedLocation?.displayName.nilIfEmpty else {
            return nil
        }
        return "Сервер: \(location)"
    }

    private var vpnActionTitle: String {
        switch helper.status.state {
        case .connected:
            return "Отключить VPN"
        case .connecting:
            return "Отменить подключение"
        case .disconnecting, .disconnected:
            return "Подключить VPN"
        }
    }

    private var vpnActionSelector: Selector {
        switch helper.status.state {
        case .connected, .connecting:
            return #selector(disconnect)
        case .disconnecting, .disconnected:
            return #selector(connect)
        }
    }

    private func menuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
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

    @objc private func showWindow() {
        showMainWindow()
    }

    @objc private func showSettings() {
        showMainWindow(section: .settings)
    }

    private func showMainWindow(section: AppSection? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        if let section {
            VEXSettingsWindow.open(section: section)
        }
    }

    @objc private func connect() {
        Task {
            await appState.connectVPN(using: helper)
            refresh()
        }
    }

    @objc private func disconnect() {
        Task {
            await appState.disconnectVPN(using: helper)
            refresh()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
