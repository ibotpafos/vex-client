import Foundation
import Combine

/// An in-memory APNs registration request. The caller obtains the token from
/// Apple's callback; this type deliberately does not interact with UNUserNotificationCenter.
struct NativePushRegistrationRequest: Equatable {
    let provider: String
    let token: String
    /// Managed server-side VpnDevice.id. This is not the local installation UUID.
    let deviceID: String
    let accountID: String
    let accessToken: String
    let sessionGeneration: Int
}

@MainActor
protocol NativePushRegistrationRegistrar: AnyObject {
    func registerNativePush(_ request: NativePushRegistrationRequest) async throws
    /// Removes only this exact provider/device/token tuple. Implementations must use server CAS.
    func unregisterNativePush(_ request: NativePushRegistrationRequest) async throws
}

extension NativePushRegistrationRegistrar {
    /// Compatibility stub for test-only legacy registrars; the production registrar overrides it.
    func unregisterNativePush(_ request: NativePushRegistrationRequest) async throws { throw URLError(.unsupportedURL) }
}

enum NativePushRegistrationStatus: Equatable {
    case disabled
    case idle
    case queued
    case registered
    case failed
}

/// Registers an APNs device token only after an explicit caller opt-in.
///
/// All state, including the token, remains in memory. Session changes invalidate
/// queued and in-flight completions by epoch; task cancellation is only an
/// optimization and is never the authorization check.
@MainActor
final class NativePushRegistrationService: ObservableObject {
    private let registrar: NativePushRegistrationRegistrar
    private let maximumTokenBytes: Int
    private var enabled = false
    private var request: NativePushRegistrationRequest?
    private var completedRequest: NativePushRegistrationRequest?
    private var epoch = 0
    private var work: Task<Void, Never>?
    /// An exact old tuple awaiting best-effort server cleanup; never a wildcard.
    private var cleanupRequest: NativePushRegistrationRequest?
    private var inFlightRequest: NativePushRegistrationRequest?

    @Published private(set) var status: NativePushRegistrationStatus = .disabled

    init(registrar: NativePushRegistrationRegistrar, maximumTokenBytes: Int = 512) {
        self.registrar = registrar
        self.maximumTokenBytes = max(1, maximumTokenBytes)
    }

    /// Opt-in is deliberately disabled by default. Disabling clears all sensitive
    /// in-memory state and makes pending or late work inert.
    func setRegistrationEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            status = .idle
            startWorkerIfNeeded()
        } else {
            captureCleanupForCurrentWork()
            request = nil
            completedRequest = nil
            epoch &+= 1
            status = .disabled
            startWorkerIfNeeded()
        }
    }

    /// Captures an Apple-supplied token and immutable authenticated-session data.
    /// Empty or oversized tokens and incomplete authentication values are ignored.
    func registerAppleDeviceToken(
        _ tokenData: Data,
        accountID: String,
        deviceID: String,
        accessToken: String,
        sessionGeneration: Int
    ) {
        guard enabled,
              let request = makeRequest(
                tokenData: tokenData,
                accountID: accountID,
                deviceID: deviceID,
                accessToken: accessToken,
                sessionGeneration: sessionGeneration
              ) else { return }
        if completedRequest == request {
            // A callback for the last successfully registered tuple is still a
            // newer intent than any queued refreshed-token tuple. Supersede it.
            self.request = request
            status = .registered
            return
        }
        if self.request == request, status == .queued {
            // Repeated callbacks for an in-flight tuple must not create a second
            // registrar write; the first task already owns this exact intent.
            return
        }
        self.request = request
        schedule(request)
    }

    /// Performs exactly one explicitly requested retry for the still-current tuple.
    /// There is intentionally no background retry loop.
    func retryCurrentRegistration() {
        guard enabled, let request, completedRequest != request else { return }
        schedule(request)
    }

    /// Call on logout, authentication reset, or account/device/session replacement.
    /// Do not cancel an in-flight URLSession write: cancellation cannot roll back a
    /// server mutation. The worker serializes its completion before exact cleanup.
    func clearAuthenticatedSession() {
        enabled = false
        captureCleanupForCurrentWork()
        request = nil
        completedRequest = nil
        epoch &+= 1
        status = .disabled
        startWorkerIfNeeded()
    }

    private func makeRequest(
        tokenData: Data,
        accountID: String,
        deviceID: String,
        accessToken: String,
        sessionGeneration: Int
    ) -> NativePushRegistrationRequest? {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenData.isEmpty,
              tokenData.count <= maximumTokenBytes,
              !accountID.isEmpty,
              !deviceID.isEmpty,
              !accessToken.isEmpty,
              sessionGeneration >= 0 else { return nil }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        return NativePushRegistrationRequest(
            provider: "apns",
            token: token,
            deviceID: deviceID,
            accountID: accountID,
            accessToken: accessToken,
            sessionGeneration: sessionGeneration
        )
    }

    private func schedule(_ request: NativePushRegistrationRequest) {
        self.request = request
        status = .queued
        startWorkerIfNeeded()
    }

    private func captureCleanupForCurrentWork() {
        // Prefer the last confirmed server tuple, otherwise retain the exact
        // request whose transport may already have reached the server.
        cleanupRequest = completedRequest ?? inFlightRequest ?? cleanupRequest
    }

    private func startWorkerIfNeeded() {
        guard work == nil else { return }
        work = Task { @MainActor [weak self] in
            // This boundary makes disable-before-delivery deterministic without
            // relying on cancellation to undo a server write.
            await Task.yield()
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        defer { work = nil }
        while true {
            if let stale = cleanupRequest {
                cleanupRequest = nil
                // Best effort only: a 401/revoked session must leave local push
                // disabled; never retry in a background loop or resurrect state.
                try? await registrar.unregisterNativePush(stale)
                continue
            }
            guard enabled, let candidate = request, completedRequest != candidate else { return }
            inFlightRequest = candidate
            // Once a different POST actually starts, a prior acknowledgement
            // cannot stand in for it if a late callback changes intent.
            if completedRequest != candidate { completedRequest = nil }
            let deliveryEpoch = epoch
            do {
                // TODO(cycle-15): transport timeout after server POST is only
                // bounded locally; cross-process ordering needs a durable server revision.
                try await registrar.registerNativePush(candidate)
                inFlightRequest = nil
                if isCurrent(candidate, epoch: deliveryEpoch) {
                    completedRequest = candidate
                    status = .registered
                } else {
                    // The registrar can report CancellationError after its POST;
                    // no completion may be assumed to mean no server write.
                    cleanupRequest = candidate
                }
            } catch {
                inFlightRequest = nil
                if isCurrent(candidate, epoch: deliveryEpoch) {
                    status = .failed
                    return
                }
                cleanupRequest = candidate
            }
        }
    }

    private func isCurrent(_ candidate: NativePushRegistrationRequest, epoch: Int) -> Bool {
        enabled && self.epoch == epoch && request == candidate
    }
}
