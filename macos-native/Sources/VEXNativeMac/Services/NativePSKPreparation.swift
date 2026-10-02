import CryptoKit
import Foundation

/// Explicit prepare -> metadata event -> existing signed stage/ACK consumer.
/// No helper, key generation, preferences or network implementation lives here.
@MainActor
enum NativePSKPreparation {
    enum Failure: Error { case invalidContext, scopeChanged, invalidReceipt }
    struct Context: Equatable {
        let accountID: String
        let installationID: String
        let deviceID: String
        let profileVersion: Int
        let locationID: String
        let routingMode: VpnRoutingMode
        let bypassRegion: String?
        let routingPolicyVersion: String

        /// Stable across transport retries; another owner/version/routing intent cannot replay it.
        var idempotencyKey: String {
            let tuple = [accountID, installationID, deviceID, String(profileVersion), locationID,
                         routingMode.rawValue, bypassRegion ?? "", routingPolicyVersion]
            let bytes = try! JSONEncoder().encode(tuple)
            return "mac-psk-routing-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Dependencies {
        let scopeIsCurrent: () -> Bool
        let prepare: (Context, String) async throws -> PSKRotationPreparationReceipt
        let enqueue: (NativePushPSKEvent) throws -> Void
        let processStagedEvents: () async -> Void
    }

    static func prepare(context: Context, dependencies: Dependencies, now: () -> Date = Date.init) async throws {
        guard !context.accountID.isEmpty, UUID(uuidString: context.installationID) != nil,
              NativePSKIdentifier.device(context.deviceID), context.profileVersion > 0,
              context.profileVersion < Int.max, !context.locationID.isEmpty,
              (context.routingMode == .fullTunnel && context.bypassRegion == nil) ||
              (context.routingMode == .allExceptRu && context.bypassRegion == "ru") else { throw Failure.invalidContext }
        guard dependencies.scopeIsCurrent(), !Task.isCancelled else { throw Failure.scopeChanged }
        let receipt = try await dependencies.prepare(context, context.idempotencyKey)
        guard dependencies.scopeIsCurrent(), !Task.isCancelled else { throw Failure.scopeChanged }
        let deadline = ISO8601DateFormatter().date(from: receipt.deadlineAt)
            ?? ISO8601DateFormatter.fractionalPSKDate(from: receipt.deadlineAt)
        let digest = receipt.profileDigest
        guard NativePSKIdentifier.rotation(receipt.rotationID),
              receipt.profileVersion == context.profileVersion + 1,
              digest.hasPrefix("sha256:"), digest.utf8.count == 71,
              digest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }),
              let deadline, deadline > now(), deadline.timeIntervalSince(now()) <= 15 * 60 else { throw Failure.invalidReceipt }
        let event = NativePushPSKEvent(kind: .profile_updated,
            eventID: "psk-rotation:\(receipt.rotationID):profile_updated", rotationID: receipt.rotationID,
            deviceID: context.deviceID, profileVersion: receipt.profileVersion, deadlineAt: deadline)
        try dependencies.enqueue(event)
        guard dependencies.scopeIsCurrent(), !Task.isCancelled else { throw Failure.scopeChanged }
        // Existing consumer re-fetches and verifies the pinned signature/digest/key,
        // re-reads the durable stage and only then ACKs. A receipt alone never activates.
        await dependencies.processStagedEvents()
    }
}

private extension ISO8601DateFormatter {
    static func fractionalPSKDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
