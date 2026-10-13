import Foundation

enum HelperDisconnectError: LocalizedError {
    case unconfirmed
    var errorDescription: String? { "Отключение VPN не подтверждено. Повторите попытку." }
}

// "ok" acknowledges down; only a complete status proves teardown.
// Older helpers can omit operation_in_progress.
enum HelperDisconnectConfirmation {
    static func isExplicitlyDisconnected(_ response: String) -> Bool {
        var values: [String: String] = [:]
        for token in response.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty,
                  values[String(pair[0])] == nil else { return false }
            values[String(pair[0])] = String(pair[1])
        }
        return values["state"] == "disconnected"
            && values["route_ok"] == "false"
            && values["socket_exists"] == "false"
            && (values["operation_in_progress"] == nil || values["operation_in_progress"] == "false")
            && (values["iface"] == nil || values["iface"] == "")
            && (values["endpoint"] == nil || values["endpoint"] == "")
            && (values["leak_protection"] == nil || values["leak_protection"] == "off")
    }
}
