import Combine
import Foundation
import UserNotifications

enum CustomerNotificationPermissionStatus: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var permitsDelivery: Bool {
        self == .authorized || self == .provisional || self == .ephemeral
    }
}

struct CustomerNotificationAuthorizationOptions: OptionSet {
    let rawValue: Int

    static let alert = Self(rawValue: 1 << 0)
    static let sound = Self(rawValue: 1 << 1)
}

struct CustomerNotificationRequest: Equatable {
    let identifier: String
    let title: String
    let body: String
}

@MainActor
protocol CustomerNotificationBackend: AnyObject {
    func notificationSettings() async -> CustomerNotificationPermissionStatus
    func requestAuthorization(options: CustomerNotificationAuthorizationOptions) async throws -> Bool
    func add(_ request: CustomerNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

/// Local foreground notices only. This service does not register APNs tokens,
/// schedule background work, or retain event contents beyond a request in flight.
@MainActor
final class CustomerNotificationService: ObservableObject {
    static let enabledDefaultsKey = "native.customerNotificationsEnabled"
    private static let maximumTrackedRequests = 256

    @Published private(set) var isEnabled: Bool
    @Published private(set) var permissionStatus: CustomerNotificationPermissionStatus = .notDetermined
    @Published private(set) var isBusy = false
    @Published private(set) var userVisibleError: String?

    var authorizationSummary: String {
        switch permissionStatus {
        case .notDetermined: return "Разрешение ещё не запрошено"
        case .denied: return "Уведомления запрещены в macOS"
        case .authorized: return "Разрешение получено"
        case .provisional: return "Временное разрешение получено"
        case .ephemeral: return "Временное разрешение получено"
        }
    }

    var errorMessage: String? { userVisibleError }

    private let defaults: UserDefaults
    private let previewMode: Bool
    private let backendFactory: (() -> CustomerNotificationBackend)?
    private var backend: CustomerNotificationBackend?
    private var generation = 0
    private var requestEpoch = 0
    private var requestSequence = 0
    // Request identifiers contain only a transient local epoch/sequence, never
    // a customer event ID. Keeping this bounded also bounds logout cleanup.
    private var requestIdentifiers: [String] = []

    init(
        defaults: UserDefaults = .standard,
        previewMode: Bool = false,
        backendFactory: (() -> CustomerNotificationBackend)? = nil
    ) {
        self.defaults = defaults
        self.previewMode = previewMode
        self.backendFactory = backendFactory
        // Opt-in is deliberately false until the user takes an explicit UI action.
        self.isEnabled = !previewMode && defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func refreshAuthorization() async {
        guard !previewMode else { return }
        let requestGeneration = generation
        let status = await notificationBackend().notificationSettings()
        guard generation == requestGeneration else { return }
        reconcileAuthorizationStatus(status)
    }

    func setEnabled(_ enabled: Bool) async {
        // Preview/smoke instances are entirely side-effect free: neither
        // direction may persist a preference or resolve the backend.
        guard !previewMode else {
            generation += 1
            isEnabled = false
            isBusy = false
            userVisibleError = nil
            return
        }
        generation += 1
        let requestGeneration = generation
        userVisibleError = nil

        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledDefaultsKey)
            // A previous authorization sheet cannot mutate the new disabled
            // intent, and its defer must not leave the Settings toggle busy.
            isBusy = false
            clearTrackedNotifications()
            return
        }

        isBusy = true
        defer {
            if generation == requestGeneration {
                isBusy = false
            }
        }
        do {
            // TODO(notification-acceptance): Validate the explicit Settings
            // opt-in, macOS permission sheet, and one privacy-reduced notice
            // on a disposable user profile with its macOS/user notification
            // settings enabled; this cannot be accepted by the injectable
            // offline backend.
            let granted = try await notificationBackend().requestAuthorization(options: [.alert, .sound])
            guard generation == requestGeneration else { return }
            let status = await notificationBackend().notificationSettings()
            guard generation == requestGeneration else { return }
            permissionStatus = status
            isEnabled = granted && status.permitsDelivery
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if !isEnabled {
                userVisibleError = "Разрешение на уведомления не выдано."
            }
        } catch {
            guard generation == requestGeneration else { return }
            isEnabled = false
            defaults.set(false, forKey: Self.enabledDefaultsKey)
            userVisibleError = "Не удалось запросить разрешение на уведомления."
        }
    }

    func deliver(_ payloads: [CustomerNotificationPayload]) async {
        guard !previewMode, isEnabled, !payloads.isEmpty else { return }
        let requestGeneration = generation
        let status = await notificationBackend().notificationSettings()
        guard generation == requestGeneration, isEnabled else { return }
        guard !reconcileAuthorizationStatus(status) else { return }

        for payload in payloads where generation == requestGeneration && isEnabled {
            guard !payload.title.isEmpty, !payload.body.isEmpty else { continue }
            let identifier = makeRequestIdentifier()
            // The identifier is the sole persistent-in-memory link to delivery;
            // title/body are handed directly to the backend and never stored.
            trackRequestIdentifier(identifier)
            do {
                try await notificationBackend().add(.init(
                    identifier: identifier,
                    title: payload.title,
                    body: payload.body
                ))
                // An in-flight request can be evicted from the bounded ledger
                // before add returns. It is then stale just like a reset, and
                // must be removed rather than surviving the next logout.
                guard generation == requestGeneration,
                      isEnabled,
                      requestIdentifiers.contains(identifier) else {
                    removeNotifications([identifier])
                    continue
                }
            } catch {
                guard generation == requestGeneration else { return }
                requestIdentifiers.removeAll { $0 == identifier }
                userVisibleError = "Не удалось показать уведомление."
            }
        }
    }

    func resetSession() {
        generation += 1
        requestEpoch &+= 1
        isBusy = false
        userVisibleError = nil
        clearTrackedNotifications()
    }

    private func notificationBackend() -> CustomerNotificationBackend {
        if let backend { return backend }
        let created = backendFactory?() ?? UserNotificationCenterBackend()
        backend = created
        return created
    }

    /// Applies a settings snapshot already obtained by the caller.  Keeping this
    /// synchronous avoids a second notification-center IPC request between the
    /// check and the delivery decision.
    ///
    /// Returns true when notifications must not be delivered for `status`.
    @discardableResult
    private func reconcileAuthorizationStatus(_ status: CustomerNotificationPermissionStatus) -> Bool {
        permissionStatus = status
        guard !status.permitsDelivery else { return false }

        if status == .denied {
            // A denied setting invalidates any delivery that was awaiting the
            // settings reply and removes only this service's tracked notices.
            generation += 1
            isEnabled = false
            defaults.set(false, forKey: Self.enabledDefaultsKey)
            isBusy = false
            clearTrackedNotifications()
        } else if isEnabled {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledDefaultsKey)
        }
        return true
    }

    private func clearTrackedNotifications() {
        let identifiers = requestIdentifiers
        requestIdentifiers.removeAll(keepingCapacity: true)
        removeNotifications(identifiers)
    }

    private func removeNotifications(_ identifiers: [String]) {
        guard !identifiers.isEmpty, let backend else { return }
        backend.removePendingNotificationRequests(withIdentifiers: identifiers)
        backend.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func makeRequestIdentifier() -> String {
        requestSequence &+= 1
        return "vex.customer.notice.\(requestEpoch).\(requestSequence)"
    }

    private func trackRequestIdentifier(_ identifier: String) {
        requestIdentifiers.append(identifier)
        guard requestIdentifiers.count > Self.maximumTrackedRequests else { return }
        let expired = requestIdentifiers.removeFirst()
        // Once an identifier leaves the bounded ledger, remove both forms so
        // it cannot survive into a later session without being trackable.
        removeNotifications([expired])
    }
}

@MainActor
private final class UserNotificationCenterBackend: NSObject, CustomerNotificationBackend, UNUserNotificationCenterDelegate {
    // The delegate is attached only when this lazy backend is first used by an
    // explicit opt-in or read-only status action; init/preview never touches
    // UNUserNotificationCenter.
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Foreground delivery remains user-controlled by macOS settings. Do
        // not use a badge or model unread state in this client.
        completionHandler([.banner, .list, .sound])
    }

    func notificationSettings() async -> CustomerNotificationPermissionStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .denied
        }
    }

    func requestAuthorization(options: CustomerNotificationAuthorizationOptions) async throws -> Bool {
        var nativeOptions: UNAuthorizationOptions = []
        if options.contains(.alert) { nativeOptions.insert(.alert) }
        if options.contains(.sound) { nativeOptions.insert(.sound) }
        return try await center.requestAuthorization(options: nativeOptions)
    }

    func add(_ request: CustomerNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
