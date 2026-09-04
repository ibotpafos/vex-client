import Foundation

/// Presentation-only grouping. Connection requests always use an original location ID.
struct VEXCountryGroup: Identifiable {
    let id: String
    let locations: [VpnLocation]
    let representative: VpnLocation
    let isSelected: Bool

    var availableNodeCount: Int {
        locations.filter(Self.isAvailable).reduce(0) { $0 + max(0, $1.healthyNodes) }
    }

    var cardLocation: VpnLocation {
        var card = representative
        card.healthyNodes = availableNodeCount
        card.status = availableNodeCount > 0 ? "healthy" : "unavailable"
        if !Self.isAvailable(representative) { card.latencyMs = nil }
        return card
    }

    static func isAvailable(_ location: VpnLocation) -> Bool {
        let status = location.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let availability = location.availability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return location.healthyNodes > 0
            && ["active", "online", "healthy", "degraded"].contains(status)
            && !["maintenance", "unavailable", "retired"].contains(availability)
    }

    static func make(_ locations: [VpnLocation], selectedID: String, limit: Int = 6) -> [Self] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let unique = locations.filter { seen.insert($0.id).inserted }
        let grouped = Dictionary(grouping: unique) { location in
            let code = location.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let valid = code.utf8.count == 2 && code.utf8.allSatisfy { (65...90).contains($0) }
            return valid ? "country:\(code)" : "location:\(location.id)"
        }
        return grouped.map { key, members in
            let sorted = members.sorted { left, right in
                if isAvailable(left) != isAvailable(right) { return isAvailable(left) }
                let a = left.latencyMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? .infinity
                let b = right.latencyMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? .infinity
                return a == b ? left.id < right.id : a < b
            }
            let selected = sorted.first { $0.id == selectedID }
            var representative = selected ?? sorted[0]
            representative.countryCode = representative.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return Self(id: key, locations: sorted, representative: representative, isSelected: selected != nil)
        }
        .sorted {
            if $0.isSelected != $1.isSelected { return $0.isSelected }
            return $0.id < $1.id
        }
        .prefix(limit).map { $0 }
    }
}
