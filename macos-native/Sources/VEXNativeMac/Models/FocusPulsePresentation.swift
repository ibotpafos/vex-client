import Foundation

enum FocusPulseServerStatus: Equatable {
    case unknown
    case checking
    case available
    case degraded
    case unavailable

    var title: String {
        switch self {
        case .unknown:
            return "Статус серверов неизвестен"
        case .checking:
            return "Проверяем серверы"
        case .available:
            return "Серверы работают"
        case .degraded:
            return "Часть серверов недоступна"
        case .unavailable:
            return "Серверы недоступны"
        }
    }
}

enum FocusPulsePresentation {
    static let animationPreviewLocations: [VpnLocation] = [
        VpnLocation(
            id: "de",
            countryCode: "DE",
            city: "Germany",
            flagEmoji: "🇩🇪",
            availability: "available",
            status: "healthy",
            healthyNodes: 1,
            latencyMs: 12
        ),
        VpnLocation(
            id: "fi",
            countryCode: "FI",
            city: "Finland",
            flagEmoji: "🇫🇮",
            availability: "available",
            status: "healthy",
            healthyNodes: 1,
            latencyMs: 8
        ),
        VpnLocation(
            id: "nl",
            countryCode: "NL",
            city: "Amsterdam",
            flagEmoji: "🇳🇱",
            availability: "available",
            status: "healthy",
            healthyNodes: 2,
            latencyMs: 18
        ),
        VpnLocation(
            id: "us",
            countryCode: "US",
            city: "New York",
            flagEmoji: "🇺🇸",
            availability: "available",
            status: "healthy",
            healthyNodes: 2,
            latencyMs: 72
        ),
    ]

    static func shouldAnimateConnection(
        status: VpnConnectionState,
        isBusy: Bool
    ) -> Bool {
        status == .connecting || status == .disconnecting || isBusy
    }

    static func serverStatus(
        locations: [VpnLocation],
        isAuthenticated: Bool,
        isLoading: Bool
    ) -> FocusPulseServerStatus {
        guard isAuthenticated else { return .unknown }
        guard !locations.isEmpty else {
            return isLoading ? .checking : .unavailable
        }

        let healthyStatuses = Set(["active", "online", "healthy"])
        let healthyCount = locations.filter { location in
            let status = location.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let availability = location.availability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return location.healthyNodes > 0
                && healthyStatuses.contains(status)
                && !["maintenance", "unavailable", "retired"].contains(availability)
        }.count

        if healthyCount == locations.count {
            return .available
        }
        if healthyCount > 0 {
            return .degraded
        }
        return .unavailable
    }

    static func connectionTitle(
        status: VpnConnectionState,
        requiresHelperInstall: Bool
    ) -> String {
        if requiresHelperInstall {
            return "Нужна установка"
        }

        switch status {
        case .connected:
            return "Подключено"
        case .connecting:
            return "Подключаемся"
        case .disconnecting:
            return "Отключаемся"
        case .disconnected:
            return "Не подключено"
        }
    }

    static func connectionDetail(
        status: VpnConnectionState,
        requiresHelperInstall: Bool
    ) -> String {
        if requiresHelperInstall {
            return "Установите системный компонент VEX"
        }

        switch status {
        case .connected:
            return "Интернет-трафик защищен"
        case .connecting:
            return "Устанавливаем защищенный туннель"
        case .disconnecting:
            return "Завершаем защищенную сессию"
        case .disconnected:
            return "Нажмите, чтобы подключить VPN"
        }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let units: [(divisor: Double, suffix: String)] = [
            (1_073_741_824, "ГБ"),
            (1_048_576, "МБ"),
            (1_024, "КБ"),
        ]

        guard let unit = units.first(where: { Double(bytes) >= $0.divisor }) else {
            return "\(bytes) Б"
        }

        let value = Double(bytes) / unit.divisor
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = value < 10 ? 1 : 0
        formatter.maximumFractionDigits = 1
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        return "\(number) \(unit.suffix)"
    }

    static func nodeCountText(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        if mod100 >= 11 && mod100 <= 14 {
            return "\(count) узлов"
        }
        switch mod10 {
        case 1: return "\(count) узел"
        case 2...4: return "\(count) узла"
        default: return "\(count) узлов"
        }
    }

    /// Rounded ping in milliseconds with the unit, e.g. "7 мс".
    static func latencyText(_ latencyMs: Double?) -> String? {
        guard let latencyMs, latencyMs.isFinite, latencyMs >= 0, latencyMs < Double(Int.max) else { return nil }
        return "\(Int(latencyMs.rounded())) мс"
    }

    static func locationCardWidth(
        containerWidth: CGFloat,
        visibleCardCount: Int,
        spacing: CGFloat
    ) -> CGFloat {
        let count = max(1, min(visibleCardCount, 3))
        let totalSpacing = CGFloat(max(0, count - 1)) * spacing
        return max(0, (containerWidth - totalSpacing) / CGFloat(count))
    }

    static func photoTransitionDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0.08 : 0.45
    }

    static func selectionTransitionDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0.01 : 0.24
    }

    static let pulseCanvasSize: CGFloat = 360
    static let pulseGradientEndRadius: CGFloat = 168

    static func featuredLocations(
        _ locations: [VpnLocation],
        selectedLocationId: String,
        limit: Int = 6
    ) -> [VpnLocation] {
        guard limit > 0 else { return [] }

        let selected = locations.first { $0.id == selectedLocationId }
        let selectedCountry = selected.map(countryKey)
        let groups = Dictionary(grouping: locations, by: countryKey)
        var seenCountries = Set<String>()
        let countryOrder = locations.compactMap { location -> String? in
            let country = countryKey(location)
            return seenCountries.insert(country).inserted ? country : nil
        }
        let representatives = countryOrder.compactMap { country -> VpnLocation? in
            if country == selectedCountry, let selected {
                return selected
            }
            return groups[country]?.sorted(by: locationPrecedes).first
        }

        return representatives.prefix(limit).map { $0 }
    }

    private static func countryKey(_ location: VpnLocation) -> String {
        let code = location.countryCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return code.isEmpty ? location.id : code
    }

    private static func locationPrecedes(_ lhs: VpnLocation, _ rhs: VpnLocation) -> Bool {
        switch (lhs.latencyMs, rhs.latencyMs) {
        case let (.some(left), .some(right)):
            return left == right ? lhs.id < rhs.id : left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.id < rhs.id
        }
    }

}
