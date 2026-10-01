import Foundation

/// Foreground SSE activity notices, NOT APNs or a count of unread messages.
/// Never copy event.data, account details, or server reasons into a notification.
struct CustomerNotificationPayload: Equatable {
    let identifier: String
    let domain: String
    let title: String
    let body: String
}

struct CustomerNotificationPolicy {
    private var rememberedIDs: [String] = []
    private var seenIDs: Set<String> = []
    private static let maximumRememberedIDs = 256

    mutating func reset() {
        rememberedIDs.removeAll(keepingCapacity: true)
        seenIDs.removeAll(keepingCapacity: true)
    }

    /// Resync is a snapshot, not a fresh message: it must never spam notices.
    /// Dedupe is bounded to the most recent 256 relevant IDs in this session.
    mutating func consume(event: CustomerRealtimeEvent, metadata: CustomerRealtimeMetadata) -> [CustomerNotificationPayload] {
        let id = event.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.type == "customer.change", !id.isEmpty, id.count <= 512 else { return [] }
        let domains = Array(Set(metadata.domains.filter { $0 == "support" || $0 == "releases" })).sorted()
        guard !domains.isEmpty, !seenIDs.contains(id) else { return [] }
        seenIDs.insert(id)
        rememberedIDs.append(id)
        if rememberedIDs.count > Self.maximumRememberedIDs {
            seenIDs.remove(rememberedIDs.removeFirst())
        }
        return domains.map { domain in
            CustomerNotificationPayload(
                identifier: "vex.activity." + domain + "." + id,
                domain: domain,
                title: domain == "support" ? "Поддержка VEX" : "Обновления VEX",
                body: domain == "support"
                    ? "Есть изменения в поддержке. Откройте клиент для просмотра."
                    : "Есть изменения в доступных релизах. Откройте клиент для просмотра."
            )
        }
    }
    // The app wires this into startCustomerRealtime and resets it on account
    // boundaries. Delivery remains explicit opt-in and permission-gated;
    // macOS permission/banner acceptance is recorded separately from this policy.
}
