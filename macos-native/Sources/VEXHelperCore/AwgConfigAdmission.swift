import Darwin
import Foundation

/// Read-only admission for the pinned awg-tools/Go parsers. Never includes values in errors.
public enum AwgConfigAdmission {
    private static let ranges: Set<String> = ["h1", "h2", "h3", "h4", "contentpaddingaddition", "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts"]
    private static let integers: Set<String> = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "listenport", "mtu"]
    private static let flags: Set<String> = ["randomtrailers", "disablecookies", "advancedsecurity"]
    private static let interfaceKeys: Set<String> = ["privatekey", "address", "dns", "mtu", "listenport", "fwmark", "table", "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5", "headerprotectionkey", "contentpaddingaddition", "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts", "randomtrailers", "disablecookies"]
    private static let peerKeys: Set<String> = ["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive", "advancedsecurity"]

    public static func validate(_ source: String) throws {
        var section = ""
        var interface: [String: String] = [:]
        var peers: [[String: String]] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.lowercased() == "[interface]" {
                guard section.isEmpty else { throw invalid("section") }
                section = "interface"; continue
            }
            if line.lowercased() == "[peer]" {
                guard !section.isEmpty else { throw invalid("section") }
                section = "peer"; peers.append([:]); continue
            }
            let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw invalid("syntax") }
            let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, (section == "interface" ? interfaceKeys : peerKeys).contains(key), !section.isEmpty else { throw invalid("field") }
            if section == "interface" { interface[key] = value } else { peers[peers.count - 1][key] = value }
            if ["privatekey", "publickey", "presharedkey", "headerprotectionkey"].contains(key) {
                guard let data = Data(base64Encoded: value), data.count == 32, data.base64EncodedString() == value else { throw invalid("key") }
            } else if ranges.contains(key) { _ = try range(value) }
            else if integers.contains(key) { guard uint(value, max: 65535) != nil else { throw invalid("integer") } }
            else if flags.contains(key) {
                guard ["on", "off"].contains(value.lowercased()) || uint(value) != nil else { throw invalid("boolean") }
            } else if key == "persistentkeepalive" {
                let bounds = try range(value)
                guard bounds.1 <= 65535 else { throw invalid("keepalive") }
            } else if key == "fwmark" || key == "table" {
                let hex = value.hasPrefix("0x") ? UInt32(value.dropFirst(2), radix: 16) : nil
                guard value == "off" || (key == "table" && value == "auto") || uint(value) != nil || hex != nil else { throw invalid("routing number") }
            } else if key == "address" || key == "allowedips" {
                for address in value.components(separatedBy: ",") { try validateNetwork(address.trimmingCharacters(in: .whitespaces)) }
            } else if key == "endpoint" { try validateEndpoint(value) }
            else if key == "dns" {
                for item in value.components(separatedBy: ",") { guard validHost(item.trimmingCharacters(in: .whitespaces)) else { throw invalid("DNS") } }
            } else if ["i1", "i2", "i3", "i4", "i5"].contains(key) { try validateSignature(value) }
        }
        guard interface["privatekey"] != nil, interface["address"] != nil, !peers.isEmpty else { throw invalid("incomplete profile") }
        for peer in peers { guard peer["publickey"] != nil, peer["endpoint"] != nil, peer["allowedips"] != nil else { throw invalid("incomplete peer") } }
        // Go's mergeWithDevice checks overlap and nonce padding, including defaults.
        let headers = try (1...4).map { try range(interface["h\($0)"] ?? String($0)) }
        for i in 0..<4 { for j in (i + 1)..<4 { guard headers[i].1 < headers[j].0 || headers[j].1 < headers[i].0 else { throw invalid("overlapping headers") } } }
        if let key = interface["headerprotectionkey"], let data = Data(base64Encoded: key), data.contains(where: { $0 != 0 }) {
            for i in 1...4 { guard let padding = uint(interface["s\(i)"] ?? "0"), padding >= 12 else { throw invalid("header padding") } }
        }
    }

    private static func invalid(_ field: String) -> HelperError { .protocolViolation("VPN_CONFIG_INVALID: invalid \(field)") }
    private static func uint(_ value: String, max: UInt64 = UInt64(UInt32.max)) -> UInt64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = UInt64(value), n <= max else { return nil }
        return n
    }
    private static func range(_ value: String) throws -> (UInt64, UInt64) {
        let parts = value.components(separatedBy: "-")
        guard (1...2).contains(parts.count), let low = uint(parts[0]), let high = uint(parts.last!), low <= high else { throw invalid("UInt32 range") }
        return (low, high)
    }
    private static func ipFamily(_ value: String) -> Int32? {
        var address = in6_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 { return AF_INET }
        if value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 { return AF_INET6 }
        return nil
    }
    private static func validateNetwork(_ value: String) throws {
        let parts = value.components(separatedBy: "/")
        guard parts.count <= 2, let family = ipFamily(parts[0]) else { throw invalid("address") }
        if parts.count == 2 { guard uint(parts[1], max: family == AF_INET ? 32 : 128) != nil else { throw invalid("prefix") } }
    }
    private static func validHost(_ value: String) -> Bool {
        if ipFamily(value) != nil { return true }
        return !value.isEmpty && value.count <= 253 && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
    private static func validateEndpoint(_ value: String) throws {
        guard let colon = value.lastIndex(of: ":"), let port = uint(String(value[value.index(after: colon)...]), max: 65535), port > 0 else { throw invalid("endpoint") }
        let host = String(value[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { guard ipFamily(String(host.dropFirst().dropLast())) == AF_INET6 else { throw invalid("endpoint") } }
        else { guard !host.contains(":"), validHost(host) else { throw invalid("endpoint") } }
    }
    private static func validateSignature(_ value: String) throws {
        var remaining = value[...]
        while let start = remaining.firstIndex(of: "<") {
            guard let end = remaining[start...].firstIndex(of: ">") else { throw invalid("signature") }
            let parts = remaining[remaining.index(after: start)..<end].split(whereSeparator: \.isWhitespace)
            guard let tag = parts.first else { throw invalid("signature") }
            let argument = parts.count > 1 ? String(parts[1]) : ""
            switch tag {
            case "t", "d", "ds": break
            case "r", "rc", "rd", "dz": guard let length = Int(argument), length >= 0 else { throw invalid("signature length") }
            case "b":
                let hex = argument.hasPrefix("0x") ? String(argument.dropFirst(2)) : argument
                guard !hex.isEmpty, hex.count % 2 == 0, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw invalid("signature bytes") }
            default: throw invalid("signature tag")
            }
            remaining = remaining[remaining.index(after: end)...]
        }
    }
}
