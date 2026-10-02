import Foundation

enum NativePSKIdentifier {
    private static let hex = CharacterSet(charactersIn: "0123456789abcdef")
    static func device(_ value: String) -> Bool { canonicalUUID(value) || prefixed(value, "vex_") }
    static func rotation(_ value: String) -> Bool { canonicalUUID(value) || prefixed(value, "pskr_") }
    static func event(_ value: String, rotationID: String, kind: String) -> Bool {
        if canonicalUUID(value) { return true }
        guard kind == "profile_updated" || kind == "cutover_ready" else { return false }
        return value == "psk-rotation:\(rotationID):\(kind)"
    }
    private static func prefixed(_ value: String, _ prefix: String) -> Bool { value.hasPrefix(prefix) && value.count == prefix.count + 32 && value.dropFirst(prefix.count).unicodeScalars.allSatisfy { hex.contains($0) } }
    private static func canonicalUUID(_ value: String) -> Bool { guard let u = UUID(uuidString:value) else{return false}; return u.uuidString.caseInsensitiveCompare(value) == .orderedSame }
}
