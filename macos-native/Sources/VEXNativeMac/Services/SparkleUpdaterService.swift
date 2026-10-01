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

/// Snapshot supplied by the app shell immediately before Sparkle is allowed to
/// replace/relaunch the process. `nil` is deliberately unsafe: a newly started
/// client must not make an updater-driven quit decision before it has learned
/// whether the privileged helper owns a tunnel.
struct NativeVPNUpdateSafetySnapshot: Equatable {
    var helperState: VpnConnectionState
    var hasManagedNetworkState: Bool
    var helperIsBusy: Bool
    var hasActiveTunnelRoute: Bool

    var permitsUpdateRelaunch: Bool {
        helperState == .disconnected
            && !hasManagedNetworkState
            && !helperIsBusy
            && !hasActiveTunnelRoute
    }
}

@MainActor
enum NativeVPNUpdateSafetyProvider {
    private static var snapshotProvider: (() -> NativeVPNUpdateSafetySnapshot?)?

    static func install(_ provider: @escaping () -> NativeVPNUpdateSafetySnapshot?) {
        snapshotProvider = provider
    }

    static func currentSnapshot() -> NativeVPNUpdateSafetySnapshot? {
        snapshotProvider?()
    }
}

enum NativeVPNUpdateSafetyPolicy {
    /// Unknown is not equivalent to disconnected. This is intentionally
    /// fail-safe so an automatic Sparkle cycle cannot terminate the app during
    /// helper startup, status loss, or a pre-existing tunnel.
    static func shouldDeferRelaunch(_ snapshot: NativeVPNUpdateSafetySnapshot?) -> Bool {
        snapshot?.permitsUpdateRelaunch != true
    }

    /// Recognize only documented/observed tunnel-style interface names. This
    /// is a conservative signal for the update gate, not a claim to detect
    /// every possible VPN implementation.
    static func hasKnownTunnelInterface(_ value: String?) -> Bool {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        for prefix in ["utun", "tun", "tap", "ppp", "ipsec"] {
            guard normalized.hasPrefix(prefix) else { continue }
            let suffix = normalized.dropFirst(prefix.count)
            if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }
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
    private var deferredInstallTask: Task<Void, Never>?

    override init() {
        super.init()
    }

    private func ensureController() -> SPUStandardUpdaterController {
        if let controller = updaterController { return controller }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
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

    deinit {
        deferredInstallTask?.cancel()
        canCheckObservation?.invalidate()
        canCheckObservation = nil
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
        // This method is only called from the delayed post-launch task or a
        // user interaction. Creating Sparkle here preserves the Tahoe launch
        // drain guard while allowing the initial automatic check to run.
        _ = ensureController()
        startPendingBackgroundCheckIfPossible()
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

extension SparkleUpdaterService: SPUUpdaterDelegate {
    /// Sparkle calls this immediately before asking the application to quit and
    /// relaunch. Holding the supplied block prevents an updater-driven quit;
    /// it does not change ordinary user-initiated quitting.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
            NativeVPNUpdateSafetyProvider.currentSnapshot()
        ) else {
            return false
        }

        deferredInstallTask?.cancel()
        deferredInstallTask = Task { @MainActor [weak self] in
            // A downloaded update may wait indefinitely while the user keeps
            // VEX connected. Polling only the in-process snapshot never sends
            // a helper command or changes network state.
            // TODO(vpn-update-safety): Exercise the deferred Sparkle handoff
            // in a disposable macOS VM with a real updater helper before
            // enabling any production automatic-install policy.
            while !Task.isCancelled {
                if !NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
                    NativeVPNUpdateSafetyProvider.currentSnapshot()
                ) {
                    installHandler()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.deferredInstallTask = nil
        }
        return true
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
