import Foundation

/// Serialized, side-effect-injected orchestration for the durable PSK rotation inbox.
/// The caller owns authentication, tunnel state and all network/helper actions; an
/// event remains queued whenever that caller's captured scope is no longer current.
@MainActor
final class NativePSKEventConsumer {
    enum Failure: Error { case stagedCleanupPending }
    struct Dependencies {
        /// Must answer false after an account/session/device/tunnel-state change.
        let scopeIsCurrent: () -> Bool
        let fetchCurrent: () async throws -> PSKRotationCurrentResponse
        /// Validates the original server-signed envelope and its event binding.
        let validate: (PSKRotationCurrentResponse, NativePushPSKEvent) throws -> Void
        let acknowledge: (PSKRotationCurrentResponse) async throws -> PSKRotationACKResponse
        /// Performs the post-cutover VPN transition. It must not return until safe.
        let activate: (PSKRotationCurrentResponse, NativePushPSKEvent) async throws -> Void
        let didFail: ((Error) -> Void)?

        init(scopeIsCurrent: @escaping () -> Bool, fetchCurrent: @escaping () async throws -> PSKRotationCurrentResponse, validate: @escaping (PSKRotationCurrentResponse, NativePushPSKEvent) throws -> Void, acknowledge: @escaping (PSKRotationCurrentResponse) async throws -> PSKRotationACKResponse, activate: @escaping (PSKRotationCurrentResponse, NativePushPSKEvent) async throws -> Void, didFail: ((Error) -> Void)? = nil) {
            self.scopeIsCurrent = scopeIsCurrent; self.fetchCurrent = fetchCurrent; self.validate = validate; self.acknowledge = acknowledge; self.activate = activate; self.didFail = didFail
        }
    }

    private let queue: NativePushPSKEventQueue
    private let store: NativePSKStagedProfileStore
    private var isProcessing = false
    private let cleanupStage: ((NativePushPSKEventOwner, String, String) throws -> Void)?

    init(
        queue: NativePushPSKEventQueue,
        store: NativePSKStagedProfileStore,
        cleanupStage: ((NativePushPSKEventOwner, String, String) throws -> Void)? = nil
    ) {
        self.queue = queue
        self.store = store
        self.cleanupStage = cleanupStage
    }

    /// Processes a snapshot serially. Errors and stale scope are deliberately silent:
    /// their durable metadata is retained for a future authenticated retry.
    func process(owner: NativePushPSKEventOwner, managedDeviceID: String, dependencies: Dependencies) async {
        guard !isProcessing, dependencies.scopeIsCurrent(), !managedDeviceID.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }

        let events: [NativePushPSKEvent]
        do {
            events = try queue.events(owner: owner)
        } catch {
            if dependencies.scopeIsCurrent() { dependencies.didFail?(error) }
            return
        }
        for event in events {
            guard dependencies.scopeIsCurrent() else { return }
            // A single owner inbox can contain stale device metadata; leave it intact
            // but do not let it block a later event for the active managed device.
            guard event.deviceID == managedDeviceID else { continue }
            do {
                switch event.kind {
                case .profile_updated:
                    try await stage(event: event, owner: owner, managedDeviceID: managedDeviceID, dependencies: dependencies)
                case .cutover_ready:
                    try await cutOver(event: event, owner: owner, managedDeviceID: managedDeviceID, dependencies: dependencies)
                }
            } catch {
                // Do not discard the event/stage on validation, transport, or busy failure.
                // Continue so an out-of-order or unrelated later event can make progress.
                guard dependencies.scopeIsCurrent() else { return }
                dependencies.didFail?(error)
                continue
            }
        }
    }

    private func stage(
        event: NativePushPSKEvent,
        owner: NativePushPSKEventOwner,
        managedDeviceID: String,
        dependencies: Dependencies
    ) async throws {
        guard dependencies.scopeIsCurrent(), eventMatches(event, deviceID: managedDeviceID) else { return }
        let original: PSKRotationCurrentResponse
        if let existing = try store.load(owner: owner, managedDeviceID: managedDeviceID, rotationID: event.rotationID),
           envelopeMatches(existing.envelope, event: event, deviceID: managedDeviceID) {
            original = existing.envelope
        } else {
            guard dependencies.scopeIsCurrent() else { return }
            original = try await dependencies.fetchCurrent()
            guard dependencies.scopeIsCurrent() else { return }
        }
        guard dependencies.scopeIsCurrent(), envelopeMatches(original, event: event, deviceID: managedDeviceID) else { return }
        try dependencies.validate(original, event)
        guard dependencies.scopeIsCurrent() else { return }
        try store.stage(original, owner: owner, managedDeviceID: managedDeviceID)
        guard dependencies.scopeIsCurrent() else { return }
        guard let reloaded = try store.load(owner: owner, managedDeviceID: managedDeviceID, rotationID: event.rotationID),
              reloaded.envelope == original,
              envelopeMatches(reloaded.envelope, event: event, deviceID: managedDeviceID) else { return }
        try dependencies.validate(reloaded.envelope, event)
        guard dependencies.scopeIsCurrent() else { return }
        let ack = try await dependencies.acknowledge(reloaded.envelope)
        guard dependencies.scopeIsCurrent(), ack.accepted, ack.rotationID == event.rotationID else { return }
        guard dependencies.scopeIsCurrent() else { return }
        _ = try queue.remove(eventID: event.eventID, owner: owner)
    }

    private func cutOver(
        event: NativePushPSKEvent,
        owner: NativePushPSKEventOwner,
        managedDeviceID: String,
        dependencies: Dependencies
    ) async throws {
        guard dependencies.scopeIsCurrent(), eventMatches(event, deviceID: managedDeviceID),
              let staged = try store.load(owner: owner, managedDeviceID: managedDeviceID, rotationID: event.rotationID),
              envelopeMatches(staged.envelope, event: event, deviceID: managedDeviceID) else { return }
        try dependencies.validate(staged.envelope, event)
        guard dependencies.scopeIsCurrent() else { return }
        try await dependencies.activate(staged.envelope, event)
        guard dependencies.scopeIsCurrent() else { return }
        // Once activation succeeds, remove its trigger first. If exact-stage purge fails,
        // a later retry cannot activate the same profile again.
        guard dependencies.scopeIsCurrent() else { return }
        _ = try queue.remove(eventID: event.eventID, owner: owner)
        // TODO(PSK consumer): reconcile owned orphan stages during authenticated account
        // lifecycle cleanup; do not invent cross-file transaction guarantees here.
        guard dependencies.scopeIsCurrent() else { return }
        if let cleanupStage {
            do { try cleanupStage(owner, managedDeviceID, event.rotationID) }
        catch { throw Failure.stagedCleanupPending }
        } else {
            try store.purge(owner: owner, managedDeviceID: managedDeviceID, rotationID: event.rotationID)
        }
    }

    private func eventMatches(_ event: NativePushPSKEvent, deviceID: String) -> Bool {
        event.deviceID == deviceID && event.profileVersion > 0
    }

    private func envelopeMatches(_ envelope: PSKRotationCurrentResponse, event: NativePushPSKEvent, deviceID: String) -> Bool {
        !envelope.activate && envelope.rotationID == event.rotationID &&
        envelope.profileVersion == event.profileVersion && envelope.profile.version == event.profileVersion &&
        envelope.profile.deviceId == deviceID
    }
}
