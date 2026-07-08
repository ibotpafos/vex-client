import Foundation

enum VEXUserFacingText {
    static func status(_ value: String?, respecting vpnStatus: VpnStatus, isBusy: Bool = false) -> String? {
        guard let text = status(value) else {
            return nil
        }
        if isConnectedSuccess(text), !vpnStatus.isUsableConnectedStatus {
            return nil
        }
        if !isBusy, vpnStatus.state == .disconnected, isTransientBusyMessage(text) {
            return nil
        }
        return text
    }

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
        if lower.contains("другой vpn удерживает системный маршрут")
            || lower.contains("foreign default route")
            || lower.contains("route conflict") {
            return "Другой VPN удерживает системный маршрут. Трафик через VEX не идет."
        }
        if lower.contains("admininstallrequired") || lower.contains("helper требует установки") {
            return "Helper требует установки."
        }
        let looksLikeHelperInstallCancel = lower.contains("установка helper отменена")
            || lower.contains("отменена пользователем")
            || ((lower.contains("cancelled") || lower.contains("canceled"))
                && (lower.contains("helper") || lower.contains("install") || lower.contains("command failed")))
        if looksLikeHelperInstallCancel {
            return "Установка helper отменена."
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
        if lower.contains("идут технические работы")
            || lower.contains("http 502")
            || lower.contains("http 503")
            || lower.contains("http 504")
            || lower.contains("connection refused")
            || lower.contains("could not connect") {
            return VEXAPIError.technicalWorksMessage
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

    private static func isConnectedSuccess(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("vpn подключен") || lower.contains("vpn переключен")
    }

    private static func isTransientBusyMessage(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("готовим vpn-профиль")
            || lower.contains("отменяем подключение")
            || lower.contains("подключим vpn")
            || lower.contains("переключаем сервер")
    }
}
