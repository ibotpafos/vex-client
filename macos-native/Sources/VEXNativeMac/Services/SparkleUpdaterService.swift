import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
protocol NativeUpdaterService: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
    func checkForUpdatesInBackground()
}

enum NativeUpdateAction: Equatable {
    case sparkleCheck
}

enum SparkleUpdaterConfiguration {
    static func isUpdaterEnabled(distributionMode: String?) -> Bool {
        !["internal", "test"].contains(
            distributionMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "production"
        )
    }

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
        guard SparkleUpdaterConfiguration.isUpdaterEnabled(
            distributionMode: bundle.object(forInfoDictionaryKey: "VEXNativeDistributionMode") as? String
        ) else {
            return DisabledNativeUpdaterService()
        }
        guard SparkleUpdaterConfiguration.isValidPublicEDKey(
            bundle.object(forInfoDictionaryKey: "SUPublicEDKey")
        ) else {
            return DisabledNativeUpdaterService()
        }
        return SparkleUpdaterService()
    }
}

@MainActor
final class SparkleUpdaterService: NSObject, ObservableObject, NativeUpdaterService {
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?
    private var backgroundCheckRequested = false
    private var backgroundCheckStarted = false

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        canCheckObservation = updaterController.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
                self?.startPendingBackgroundCheckIfPossible()
            }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        guard !backgroundCheckRequested else { return }
        backgroundCheckRequested = true
        startPendingBackgroundCheckIfPossible()
    }

    private func startPendingBackgroundCheckIfPossible() {
        guard backgroundCheckRequested,
              !backgroundCheckStarted,
              updaterController.updater.canCheckForUpdates else {
            return
        }
        backgroundCheckStarted = true
        updaterController.updater.checkForUpdatesInBackground()
    }
}

@MainActor
final class DisabledNativeUpdaterService: NativeUpdaterService {
    var automaticallyChecksForUpdates = false
    let canCheckForUpdates = false

    func checkForUpdates() {}
    func checkForUpdatesInBackground() {}
}
