import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
protocol NativeUpdaterService: AnyObject {
    var isEnabled: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func startUpdater()
    func checkForUpdates()
    func checkForUpdatesInBackground()
}

enum NativeUpdateAction: Equatable {
    case sparkleCheck
}

enum SparkleUpdaterConfiguration {
    static func isValidPublicEDKey(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: trimmed) else { return false }
        return decoded.count == 32
    }
}

@MainActor
enum NativeUpdaterServiceFactory {
    static func make(bundle: Bundle = .main) -> NativeUpdaterService {
        guard SparkleUpdaterConfiguration.isValidPublicEDKey(
            bundle.object(forInfoDictionaryKey: "SUPublicEDKey")
        ) else {
            return DisabledNativeUpdaterService()
        }
        return SparkleUpdaterService()
    }
}

/// Wraps Sparkle's `SPUStandardUpdaterController`.
///
/// The controller (and its KVO observation) is created **lazily**, only when the
/// user explicitly triggers an update check. Constructing it at app launch on
/// macOS 26 (Tahoe) triggers a deterministic `EXC_BAD_ACCESS` (over-release in
/// the `-[NSApplication run]` autorelease pool drain) inside Sparkle 2.x, so we
/// must avoid touching Sparkle during startup entirely.
@MainActor
final class SparkleUpdaterService: NSObject, ObservableObject, NativeUpdaterService {
    @Published private(set) var canCheckForUpdates = false

    let isEnabled = true

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
    private var backgroundCheckRequested = false
    private var backgroundCheckStarted = false

    override init() {
        super.init()
    }

    private func ensureController() -> SPUStandardUpdaterController {
        if let controller = updaterController { return controller }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
                self?.startPendingBackgroundCheckIfPossible()
            }
        }
        return controller
    }

    deinit {
        canCheckObservation?.invalidate()
        canCheckObservation = nil
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    func startUpdater() {
        _ = ensureController()
    }

    func checkForUpdates() {
        let controller = ensureController()
        // Sparkle's standard user driver shows its own UI; invoke on the next
        // run loop turn so we never construct/tear down Sparkle objects during
        // the launch-time autorelease drain.
        Task { @MainActor in
            controller.checkForUpdates(nil)
            startPendingBackgroundCheckIfPossible()
        }
    }

    func checkForUpdatesInBackground() {
        guard !backgroundCheckRequested else { return }
        backgroundCheckRequested = true
        // Controller may not exist yet (lazy init); if it does, run now.
        if updaterController != nil {
            startPendingBackgroundCheckIfPossible()
        }
    }

    private func startPendingBackgroundCheckIfPossible() {
        guard backgroundCheckRequested,
              !backgroundCheckStarted,
              let updater = updaterController?.updater,
              updater.canCheckForUpdates else {
            return
        }
        backgroundCheckStarted = true
        updater.checkForUpdatesInBackground()
    }
}

@MainActor
final class DisabledNativeUpdaterService: NativeUpdaterService {
    let isEnabled = false
    var automaticallyChecksForUpdates = false
    let canCheckForUpdates = false

    func startUpdater() {}
    func checkForUpdates() {}
    func checkForUpdatesInBackground() {}
}
