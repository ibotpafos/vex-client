import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case home
    case account
    case support
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "Главная"
        case .account:
            return "Аккаунт"
        case .support:
            return "Поддержка"
        case .settings:
            return "Настройки"
        }
    }

    var systemName: String {
        switch self {
        case .home:
            return "house"
        case .account:
            return "person"
        case .support:
            return "message"
        case .settings:
            return "gearshape"
        }
    }
}
