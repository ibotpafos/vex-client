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
    func registerNativePush(_ request: NativePushRegistrationRequest) async throws -> NativePushRegistrationReceipt
    /// Removes only this exact provider/device/token tuple and server receipt.
    func unregisterNativePush(_ request: NativePushRegistrationRequest, receipt: NativePushRegistrationReceipt) async throws
}

extension NativePushRegistrationRegistrar {
    /// Compatibility stub for test-only legacy registrars; the production registrar overrides it.
    func unregisterNativePush(_ request: NativePushRegistrationRequest, receipt: NativePushRegistrationReceipt) async throws { throw URLError(.unsupportedURL) }
}

enum VEXPushReceiptError: Error { case invalidRevision }

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
    private var completed: (request: NativePushRegistrationRequest, receipt: NativePushRegistrationReceipt)?
    private var epoch = 0
    private var work: Task<Void, Never>?
    /// A confirmed server receipt awaiting best-effort exact CAS cleanup; never a wildcard.
    private var cleanup: (request: NativePushRegistrationRequest, receipt: NativePushRegistrationReceipt)?

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
            completed = nil
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
        if completed?.request == request {
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
        guard enabled, let request, completed?.request != request else { return }
        schedule(request)
    }

    /// Call on logout, authentication reset, or account/device/session replacement.
    /// Do not cancel an in-flight URLSession write: cancellation cannot roll back a
    /// server mutation. The worker serializes its completion before exact cleanup.
    func clearAuthenticatedSession() {
        enabled = false
        captureCleanupForCurrentWork()
        request = nil
        completed = nil
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
        cleanup = completed ?? cleanup
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
            if let stale = cleanup {
                cleanup = nil
                // Best effort only: a 401/revoked session must leave local push
                // disabled; never retry in a background loop or resurrect state.
                try? await registrar.unregisterNativePush(stale.request, receipt: stale.receipt)
                continue
            }
            guard enabled, let candidate = request, completed?.request != candidate else { return }
            // Once a different POST actually starts, a prior acknowledgement
            // cannot stand in for it if a late callback changes intent.
            if completed?.request != candidate { completed = nil }
            let deliveryEpoch = epoch
            do {
                // TODO(cycle-16): a transport failure without a receipt cannot safely clean up;
                // durable operation IDs/session intent and server reconciliation are still needed
                // for arbitrary late POST ordering across process restarts.
                let receipt = try await registrar.registerNativePush(candidate)
                guard receipt.revision > 0 else { throw VEXPushReceiptError.invalidRevision }
                if isCurrent(candidate, epoch: deliveryEpoch) {
                    completed = (candidate, receipt)
                    status = .registered
                } else {
                    // The registrar can report CancellationError after its POST;
                    // no completion may be assumed to mean no server write.
                    cleanup = (candidate, receipt)
                }
            } catch {
                // No receipt means no safe CAS delete. TODO: server-side orphan reconciliation.
                if isCurrent(candidate, epoch: deliveryEpoch) {
                    status = .failed
                    return
                }
            }
        }
    }

    private func isCurrent(_ candidate: NativePushRegistrationRequest, epoch: Int) -> Bool {
        enabled && self.epoch == epoch && request == candidate
    }
}
