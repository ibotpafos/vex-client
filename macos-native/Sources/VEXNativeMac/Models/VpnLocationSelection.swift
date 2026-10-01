import Foundation

enum VpnLocationSelection {
    static func targetID(locations: [VpnLocation], selectedID: String, automatic: Bool) -> String? {
        let selectable = locations.filter(\.isSelectable)
        if automatic {
            return selectable.sorted(by: precedes).first?.id
        }
        return selectable.first { $0.id == selectedID }?.id
    }

    static func fallback(locations: [VpnLocation], excluding id: String) -> VpnLocation? {
        let excluded = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return locations.filter {
            $0.isSelectable && $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != excluded
        }.sorted(by: precedes).first
    }

    private static func precedes(_ left: VpnLocation, _ right: VpnLocation) -> Bool {
        let a = usableLatency(left.latencyMs), b = usableLatency(right.latencyMs)
        if a != b { return a < b }
        if left.healthyNodes != right.healthyNodes { return left.healthyNodes > right.healthyNodes }
        return left.id < right.id
    }

    private static func usableLatency(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return .greatestFiniteMagnitude }
        return value
    }
}

enum NativeLocationSelectionError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Нет доступного сервера. Обновите список или выберите другой сервер; действующее подключение не изменено."
    }
}
