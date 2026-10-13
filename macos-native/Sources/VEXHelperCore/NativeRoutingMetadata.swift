import Darwin
import Foundation

enum NativeRoutingMetadata {
    static func prepare(raw: String, interfaceName: String, config: String, previousAuthorization: String? = nil) throws -> String {
        guard raw.utf8.count <= 2 * 1024 * 1024,
              var payload = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let user = getpwnam("_vexvpn"), (300...499).contains(user.pointee.pw_uid), user.pointee.pw_gid == user.pointee.pw_uid,
              String(cString: user.pointee.pw_shell) == "/usr/bin/false", String(cString: user.pointee.pw_dir) == "/var/empty",
              !interfaceName.hasPrefix("utun"), !interfaceName.hasPrefix("tun"),
              if_nametoindex(interfaceName) > 0 else {
            throw HelperError.protocolViolation("VPN_CONFIG_INVALID: routing metadata or physical interface unavailable")
        }
        func values(_ name: String) -> [String] {
            config.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() else { return [] }
                return parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        payload["addresses"] = values("Address")
        payload["dns"] = values("DNS")
        payload.removeValue(forKey: "previous_authorization")
        if let previousAuthorization, previousAuthorization.utf8.count <= 2 * 1024 * 1024,
           let previous = try? JSONSerialization.jsonObject(with: Data(previousAuthorization.utf8)) as? [String: Any] {
            payload["previous_authorization"] = previous
            if payload["authorization"] == nil && payload["mode"] as? String == "all_except_ru" { payload["authorization"] = previous }
        }
        let root: [String: Any] = ["routing": payload, "physical_interface_index": if_nametoindex(interfaceName),
            "uid": user.pointee.pw_uid, "gid": user.pointee.pw_gid]
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }
}
