import Foundation

enum HelperDisconnectConfirmation {
    static func isExplicitlyDisconnected(_ response: String) -> Bool {
        var values: [String: String] = [:]
        for token in response.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, values[String(pair[0])] == nil else { return false }
            values[String(pair[0])] = String(pair[1])
        }
        return values["state"] == "disconnected"
            && values["route_ok"] == "false"
            && values["socket_exists"] == "false"
            && (values["operation_in_progress"] == nil || values["operation_in_progress"] == "false")
    }
}
