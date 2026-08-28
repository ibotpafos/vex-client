import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
protocol NativeUpdaterService: AnyObject {
    var isEnabled: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func prepareAutomaticUpdatesAfterLaunch()
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
/// The controller (and its KVO observation) is created lazily. Automatic update
/// startup is delayed until AppKit has completed its first launch cycles;
/// constructing `SPUStandardUpdaterController` synchronously from SwiftUI app
/// initialization triggers an Objective-C over-release in macOS 26's launch
/// autorelease-pool drain. The delayed path keeps Sparkle automatic checks and
/// installation enabled without putting Sparkle in that unsafe launch window.
@MainActor
final class SparkleUpdaterService: ObservableObject, NativeUpdaterService {
    @Published private(set) var canCheckForUpdates = false

    let isEnabled = true

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
    private var backgroundCheckRequested = false
    private var backgroundCheckStarted = false
    private var automaticStartupTask: Task<Void, Never>?
    private static let automaticStartupDelayNanoseconds: UInt64 = 15_000_000_000
    static let automaticStartupEvidenceKey = "vex.sparkle.lastAutomaticStartup"

    deinit {
        automaticStartupTask?.cancel()
        canCheckObservation?.invalidate()
    }

    private func ensureController() -> SPUStandardUpdaterController {
        if let controller = updaterController { return controller }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        // Sparkle requires an explicit start when constructed with
        // startingUpdater: false - without it checkForUpdates is a no-op.
        // Safe here: this runs from a user action or post-launch cycle,
        // never inside the launch-time autorelease drain that crashed Tahoe.
        do {
            try controller.updater.start()
        } catch {
            statusFallbackForMisconfiguredSparkle(error)
        }
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
                self?.startPendingBackgroundCheckIfPossible()
            }
        }
        return controller
    }

    private func statusFallbackForMisconfiguredSparkle(_ error: Error) {
        // Surface configuration problems instead of failing silently.
        NSLog("VEX Sparkle: updater failed to start: \(error.localizedDescription)")
    }

    func prepareAutomaticUpdatesAfterLaunch() {
        guard automaticStartupTask == nil, updaterController == nil else { return }
        guard automaticallyChecksForUpdates else { return }
        automaticStartupTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.automaticStartupDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.automaticallyChecksForUpdates else { return }
            self.startUpdater()
            self.checkForUpdatesInBackground()
            UserDefaults.standard.set(
                Date().timeIntervalSince1970,
                forKey: Self.automaticStartupEvidenceKey
            )
            NSLog("VEX Sparkle: automatic updater started after launch stabilization")
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            // Before the lazy controller exists, honor the persisted Sparkle
            // default so the settings toggle reflects reality.
            if let controller = updaterController {
                return controller.updater.automaticallyChecksForUpdates
            }
            return UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        }
        set {
            // Constructing the controller on first toggle is safe here: this
            // runs from a user action in Settings, never the launch drain.
            ensureController().updater.automaticallyChecksForUpdates = newValue
        }
    }

    func startUpdater() {
        _ = ensureController()
    }

    func checkForUpdates() {
        let controller = ensureController()
        // Two pitfalls handled here:
        // 1) Right after start() Sparkle is still in its startup cycle
        //    (sessionInProgress) - a check issued then is rejected with
        //    "-checkForUpdates called but .sessionInProgress == YES".
        // 2) checkForUpdates(nil) must run on the next runloop turn so we
        //    never construct/tear down Sparkle objects during launch drain.
        Task { @MainActor in
            // Wait until the startup cycle releases the session.
            for _ in 0..<50 { // ~5s max
                if controller.updater.canCheckForUpdates { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard controller.updater.canCheckForUpdates else { return }
            controller.checkForUpdates(nil)
        }
    }

    func checkForUpdatesInBackground() {
        backgroundCheckRequested = true
        if updaterController != nil {
            startPendingBackgroundCheckIfPossible()
        }
    }

    private func startPendingBackgroundCheckIfPossible() {
        guard backgroundCheckRequested,
              let updater = updaterController?.updater,
              updater.canCheckForUpdates else {
            return
        }
        // Only the first successful start performs the background check;
        // afterwards Sparkle's own scheduler takes over.
        guard !backgroundCheckStarted else { return }
        backgroundCheckStarted = true
        updater.checkForUpdatesInBackground()
    }
}

@MainActor
final class DisabledNativeUpdaterService: NativeUpdaterService {
    let isEnabled = false
    var automaticallyChecksForUpdates = false
    let canCheckForUpdates = false

    func prepareAutomaticUpdatesAfterLaunch() {}
    func startUpdater() {}
    func checkForUpdates() {}
    func checkForUpdatesInBackground() {}
}
