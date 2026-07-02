import Foundation

struct BillingSummaryCache {
    private let store: AppSensitiveFileStore
    private let key = "billing-summary-cache-v1"
    private let schemaVersion = 1

    init(store: AppSensitiveFileStore = AppSensitiveFileStore()) {
        self.store = store
    }

    func load(userId: String) -> BillingSummary? {
        let normalizedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserId.isEmpty,
              let data = store.data(for: key),
              let cache = try? JSONDecoder().decode(BillingSummaryCacheStore.self, from: data),
              let entry = cache.entries[normalizedUserId],
              entry.schemaVersion == schemaVersion,
              entry.userId == normalizedUserId else {
            return nil
        }
        return entry.summary
    }

    func save(userId: String, summary: BillingSummary) {
        let normalizedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserId.isEmpty else { return }

        var cache = BillingSummaryCacheStore(entries: [:])
        if let data = store.data(for: key),
           let decoded = try? JSONDecoder().decode(BillingSummaryCacheStore.self, from: data) {
            cache = decoded
        }
        cache.entries[normalizedUserId] = BillingSummaryCacheEntry(
            savedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            schemaVersion: schemaVersion,
            summary: summary,
            userId: normalizedUserId
        )
        if let data = try? JSONEncoder().encode(cache) {
            try? store.setData(data, for: key)
        }
    }
}

private struct BillingSummaryCacheStore: Codable {
    var entries: [String: BillingSummaryCacheEntry]
}

private struct BillingSummaryCacheEntry: Codable {
    var savedAtMs: Int64
    var schemaVersion: Int
    var summary: BillingSummary
    var userId: String
}
