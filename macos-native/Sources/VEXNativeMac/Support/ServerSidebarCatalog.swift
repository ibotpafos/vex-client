import Foundation

enum ServerSidebarFilter: String, CaseIterable, Identifiable {
    case all
    case fastest
    case favorites
    case available

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все"
        case .fastest: return "Быстрые"
        case .favorites: return "Избранные"
        case .available: return "Доступные"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "server.rack"
        case .fastest: return "bolt.fill"
        case .favorites: return "star.fill"
        case .available: return "checkmark.circle.fill"
        }
    }
}

enum ServerSidebarFavorites {
    static func decode(_ storedValue: String) -> Set<String> {
        Set(
            storedValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    static func encode(_ favoriteIDs: Set<String>) -> String {
        favoriteIDs.sorted().joined(separator: ",")
    }

    static func toggling(_ locationID: String, in favoriteIDs: Set<String>) -> Set<String> {
        let normalizedID = locationID.lowercased()
        if favoriteIDs.contains(normalizedID) {
            return favoriteIDs.subtracting([normalizedID])
        }
        return favoriteIDs.union([normalizedID])
    }
}

struct ServerSidebarCountryGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let flagEmoji: String
    let locations: [VpnLocation]
}

enum ServerSidebarCatalog {
    static func filtered(
        locations: [VpnLocation],
        query: String,
        filter: ServerSidebarFilter,
        favoriteIDs: Set<String>
    ) -> [VpnLocation] {
        let searched = locations.filter { location in
            ServerSidebarSearch.matches(
                query: query,
                values: [
                    location.id,
                    location.countryCode,
                    location.city,
                    location.displayName,
                    location.localizedName,
                    location.status,
                ]
            )
        }

        let scoped: [VpnLocation]
        switch filter {
        case .all:
            scoped = searched
        case .fastest:
            scoped = searched.filter { isAvailable($0) && $0.latencyMs != nil }
        case .favorites:
            scoped = searched.filter { favoriteIDs.contains($0.id.lowercased()) }
        case .available:
            scoped = searched.filter(isAvailable)
        }

        return scoped.sorted { lhs, rhs in
            if filter != .fastest {
                let lhsFavorite = favoriteIDs.contains(lhs.id.lowercased())
                let rhsFavorite = favoriteIDs.contains(rhs.id.lowercased())
                if lhsFavorite != rhsFavorite {
                    return lhsFavorite
                }
            }

            let lhsLatency = lhs.latencyMs ?? .greatestFiniteMagnitude
            let rhsLatency = rhs.latencyMs ?? .greatestFiniteMagnitude
            if lhsLatency != rhsLatency {
                return lhsLatency < rhsLatency
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func groups(_ locations: [VpnLocation]) -> [ServerSidebarCountryGroup] {
        var countryOrder: [String] = []
        var locationsByCountry: [String: [VpnLocation]] = [:]

        for location in locations {
            let countryCode = location.countryCode.uppercased()
            if locationsByCountry[countryCode] == nil {
                countryOrder.append(countryCode)
            }
            locationsByCountry[countryCode, default: []].append(location)
        }

        return countryOrder.compactMap { countryCode in
            guard let countryLocations = locationsByCountry[countryCode],
                  let first = countryLocations.first
            else {
                return nil
            }
            return ServerSidebarCountryGroup(
                id: countryCode,
                title: first.localizedName,
                flagEmoji: first.flagEmoji ?? "",
                locations: countryLocations
            )
        }
    }

    static func isAvailable(_ location: VpnLocation) -> Bool {
        let unavailableStatuses = Set(["maintenance", "offline", "unavailable", "disabled"])
        return location.healthyNodes > 0
            && location.availability.lowercased() != "unavailable"
            && !unavailableStatuses.contains(location.status.lowercased())
    }
}

enum ServerSidebarOperationState: Equatable {
    case idle
    case selected(String)
    case preparingRoute
    case connecting
    case verifying
    case failed(String)
    case verified(String)

    var isBusy: Bool {
        switch self {
        case .preparingRoute, .connecting, .verifying:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .idle:
            return ""
        case .selected(let message):
            return message
        case .preparingRoute:
            return "Выбираем маршрут"
        case .connecting:
            return "Подключаем сервер"
        case .verifying:
            return "Проверяем защиту"
        case .failed(let message):
            return message
        case .verified(let message):
            return message
        }
    }

    var subtitle: String {
        switch self {
        case .idle:
            return ""
        case .selected:
            return "Сервер сохранён и готов к использованию."
        case .preparingRoute:
            return "Подбираем профиль и обновляем маршрут."
        case .connecting:
            return "Переподключаем tunnel без лишнего шума в UI."
        case .verifying:
            return "Ждём handshake и подтверждение защищённого маршрута."
        case .failed:
            return "Можно повторить загрузку серверов или выбрать другую локацию."
        case .verified:
            return "Подключение подтверждено, маршрут активен."
        }
    }
}
