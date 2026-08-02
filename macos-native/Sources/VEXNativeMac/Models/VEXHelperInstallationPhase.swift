import Foundation

enum VEXHelperInstallationPhase: Equatable, Sendable {
    case idle
    case preparing
    case authorizing
    case installing
    case verifying
    case installed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .authorizing, .installing, .verifying:
            return true
        case .idle, .installed, .failed:
            return false
        }
    }

    var title: String {
        switch self {
        case .idle:
            return "Требуется helper"
        case .preparing:
            return "Подготовка helper"
        case .authorizing:
            return "Подтвердите установку"
        case .installing:
            return "Устанавливаем helper"
        case .verifying:
            return "Проверяем helper"
        case .installed:
            return "Helper установлен"
        case .failed:
            return "Ошибка установки"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Установите системный компонент VEX"
        case .preparing:
            return "Проверяем пакет и готовим установку"
        case .authorizing:
            return "Введите пароль администратора в системном окне"
        case .installing:
            return "Не закрывайте VEX — это займёт несколько секунд"
        case .verifying:
            return "Ждём запуска защищённого системного компонента"
        case .installed:
            return "Системный компонент готов к работе"
        case .failed(let message):
            return message
        }
    }
}
