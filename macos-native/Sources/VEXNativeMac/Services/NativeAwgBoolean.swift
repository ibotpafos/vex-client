import Foundation

enum NativeAwgBoolean {
    // The DTO remains verbatim; awg-tools accepts on/off rather than true/false.
    // Reject unknown managed tokens, never omit or default them.
    static func append(_ name: String, _ value: String?, to lines: inout [String]) throws {
        guard let value else { return }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rendered: String
        if ["on", "1", "true", "t", "yes"].contains(token) { rendered = "on" }
        else if ["off", "0", "false", "f", "no"].contains(token) { rendered = "off" }
        else { throw NSError(domain: "VPN_CONFIG_INVALID", code: 1, userInfo: [NSLocalizedDescriptionKey: "VPN_CONFIG_INVALID: invalid managed boolean"]) }
        lines.append("\(name) = \(rendered)")
    }

}
