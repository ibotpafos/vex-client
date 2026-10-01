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
        invalidateWork()
        if enabled {
            status = .idle
        } else {
            request = nil
            completedRequest = nil
            status = .disabled
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
            invalidateWork()
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
    func clearAuthenticatedSession() {
        enabled = false
        request = nil
        completedRequest = nil
        invalidateWork()
        status = .disabled
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
        invalidateWork()
        let scheduledEpoch = epoch
        status = .queued
        work = Task { @MainActor [weak self] in
            // Yield creates a deterministic queue boundary: an immediate logout,
            // disable, or session replacement prevents the registrar from starting.
            await Task.yield()
            await self?.deliverIfCurrent(request, epoch: scheduledEpoch)
        }
    }

    private func deliverIfCurrent(_ candidate: NativePushRegistrationRequest, epoch: Int) async {
        guard isCurrent(candidate, epoch: epoch), completedRequest != candidate else { return }
        do {
            try await registrar.registerNativePush(candidate)
            guard isCurrent(candidate, epoch: epoch) else { return }
            completedRequest = candidate
            status = .registered
        } catch {
            guard isCurrent(candidate, epoch: epoch) else { return }
            status = .failed
        }
    }

    private func isCurrent(_ candidate: NativePushRegistrationRequest, epoch: Int) -> Bool {
        enabled && self.epoch == epoch && request == candidate
    }

    private func invalidateWork() {
        epoch &+= 1
        work?.cancel()
        work = nil
    }
}
