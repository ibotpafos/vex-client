import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case home
    case account
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "Главная"
        case .account:
            return "Аккаунт"
        case .settings:
            return "Настройки"
        }
    }

    var headerTitle: String? {
        self == .home ? nil : title
    }

    var systemName: String {
        switch self {
        case .home:
            return "house"
        case .account:
            return "person"
        case .settings:
            return "gearshape"
        }
    }
}
