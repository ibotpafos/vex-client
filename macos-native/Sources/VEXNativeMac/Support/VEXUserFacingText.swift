import Foundation

enum VEXUserFacingText {
    static func status(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()

        if lower == "status refreshed." {
            return nil
        }
        if lower.contains("helper status unavailable") {
            return "Проверяем helper..."
        }
        if lower.contains("admininstallrequired") || lower.contains("helper требует установки") {
            return "Helper установится при первом подключении."
        }
        if lower.contains("command failed") {
            if lower.contains("could not connect") || lower.contains("socket") {
                return "Helper запускается..."
            }
            return "Не удалось выполнить команду VPN."
        }
        if lower.contains("socket is not connected") || lower.contains("socket not connected") {
            return "Обновляем состояние подключения..."
        }
        if lower.contains("cancelled") || lower.contains("canceled") {
            return nil
        }
        if lower.contains("http 404") || lower.contains("404 page not found") || lower.contains("not found") {
            return "Сервис временно недоступен."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Сеть отвечает медленно. Повторяем..."
        }
        if lower.contains("network connection was lost") {
            return "Соединение прервалось. Восстанавливаем..."
        }

        return raw
    }
}
