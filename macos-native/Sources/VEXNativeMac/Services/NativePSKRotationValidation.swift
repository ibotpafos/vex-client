import CryptoKit
import Foundation
import Darwin

/// Pure admission checks for an inactive, push-bound PSK stage. This does not persist, ACK, or activate.
enum NativePSKRotationValidation {
    enum Failure: Error, Equatable { case malformed, eventMismatch, expired, untrustedAuthorization, digestMismatch }

    static func validate(envelope: PSKRotationCurrentResponse, event: NativePushPSKEvent, managedDeviceID: String, expectedClientPublicKey: String?, now: Date = Date(), requireStagingDeadline: Bool = true) throws {
        guard event.kind == .profile_updated,
              uuid(managedDeviceID), uuid(envelope.rotationID), uuid(event.eventID),
              envelope.rotationID == event.rotationID, event.deviceID == managedDeviceID,
              event.profileVersion == envelope.profileVersion,
              !envelope.activate, envelope.currentVersion > 0, envelope.profileVersion > envelope.currentVersion,
              envelope.profile.version == envelope.profileVersion, envelope.profile.deviceId == managedDeviceID,
              envelope.profile.revoked != true, envelope.profile.unchanged != true,
              envelope.profile.config == nil else { throw Failure.eventMismatch }
        guard let deadline = date(envelope.deadlineAt), deadline.timeIntervalSinceReferenceDate.isFinite,
              (!requireStagingDeadline || deadline > now),
              (!requireStagingDeadline || (event.deadlineAt.map({ $0 > now }) ?? true)),
              let expiry = envelope.profile.expiresAt.flatMap(date), expiry > now else { throw Failure.expired }
        // Geometry accepts only the sanitized output of the separate pinned P-256 policy verifier.
        // The authenticated consumer must verify original signed proof before calling this primitive.
        guard envelope.profile.authorization == nil else { throw Failure.untrustedAuthorization }
        guard let protocolName = envelope.profile.protocol?.lowercased(), ["amneziawg", "awg3"].contains(protocolName),
              let server = envelope.profile.server, endpoint(server, envelope.profile.port),
              let serverKey = envelope.profile.serverPublicKey, key(serverKey),
              let psk = envelope.profile.presharedKey, key(psk),
              let clientKey = envelope.profile.clientPublicKey, key(clientKey),
              expectedClientPublicKey.map({ $0 == clientKey }) ?? true,
              let ip = envelope.profile.assignedIpv4, assignedIPv4(ip),
              let dns = envelope.profile.dns, !dns.isEmpty, dns.allSatisfy(validAddress),
              let allowed = envelope.profile.allowedIps, !allowed.isEmpty, allowed.allSatisfy(cidr) else { throw Failure.malformed }
        guard serverStableDigest(envelope.profile) == envelope.profileDigest else { throw Failure.digestMismatch }
    }

    private static func uuid(_ v: String) -> Bool { UUID(uuidString: v) != nil }
    private static func key(_ v: String) -> Bool { guard let d = Data(base64Encoded: v), d.count == 32 else { return false }; return d.base64EncodedString() == v }
    private static func date(_ raw: String) -> Date? { let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]; return a.date(from: raw) ?? b.date(from: raw) }
    private static func endpoint(_ server: String, _ port: Int?) -> Bool {
        guard let port, (1...65535).contains(port), !server.isEmpty, server.utf8.count <= 253,
              !server.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f }) else { return false }
        if ipv4(server) { return true }
        let labels = server.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    }
    private static func ipv4(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 4 && pieces.allSatisfy { piece in
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece) else { return false }
            return (0...255).contains(number) && String(number) == piece
        }
    }
    private static func assignedIPv4(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces[1] == "32" && ipv4(String(pieces[0]))
    }
    private static func validAddress(_ v: String) -> Bool {
        if ipv4(v) { return true }
        var addr = in6_addr()
        return v.utf8.count <= 45 && inet_pton(AF_INET6, v, &addr) == 1
    }
    private static func cidr(_ v: String) -> Bool { let p = v.split(separator: "/", omittingEmptySubsequences: false); guard p.count == 2, let n = Int(p[1]) else { return false }; return (ipv4(String(p[0])) && (0...32).contains(n)) || (validAddress(String(p[0])) && String(p[0]).contains(":") && (0...128).contains(n)) }

    /// Mirrors Go's ordered stable struct JSON. AWG fields are emitted in domain.AWGConfig order and omit zero values.
    static func serverStableDigest(_ p: ManagedVpnProfile) -> String? {
        guard let v=p.version, let d=p.deviceId, let proto=p.protocol, let s=p.server, let port=p.port, let spk=p.serverPublicKey, let psk=p.presharedKey, let ip=p.assignedIpv4, let dns=p.dns, let allowed=p.allowedIps else { return nil }
        func q(_ x: String) -> String {
            var out = "\""
            for scalar in x.unicodeScalars {
                switch scalar.value { case 0x22: out += "\\\""; case 0x5c: out += "\\\\"; case 8: out += "\\b"; case 12: out += "\\f"; case 10: out += "\\n"; case 13: out += "\\r"; case 9: out += "\\t"; case 0...0x1f, 0x3c, 0x3e, 0x26, 0x2028, 0x2029: out += String(format: "\\u%04x", scalar.value); default: out.unicodeScalars.append(scalar) }
            }
            return out + "\""
        }
        func array(_ xs:[String]) -> String { "[" + xs.map(q).joined(separator: ",") + "]" }
        var fields=["\"version\":\(v)","\"device_id\":\(q(d))","\"protocol\":\(q(proto))","\"server\":\(q(s))","\"port\":\(port)","\"server_public_key\":\(q(spk))","\"preshared_key\":\(q(psk))","\"assigned_ipv4\":\(q(ip))","\"dns\":\(array(dns))","\"allowed_ips\":\(array(allowed))"]
        if let a=p.amnezia { var x:[String]=[]; func i(_ k:String,_ n:Int?){if let n, n != 0{x.append("\"\(k)\":\(n)")}}; func t(_ k:String,_ z:String?){if let z, !z.isEmpty{x.append("\"\(k)\":\(q(z))")}}; i("jc",a.jc);i("jmin",a.jmin);i("jmax",a.jmax);i("s1",a.s1);i("s2",a.s2);i("s3",a.s3);i("s4",a.s4);t("h1",a.h1);t("h2",a.h2);t("h3",a.h3);t("h4",a.h4);t("i1",a.i1);t("i2",a.i2);t("i3",a.i3);t("i4",a.i4);t("i5",a.i5);t("header_protection_key",a.headerProtectionKey);t("content_padding_addition",a.contentPaddingAddition);t("rekey_after_time",a.rekeyAfterTime);t("rekey_timeout",a.rekeyTimeout);t("reject_after_time",a.rejectAfterTime);t("keepalive_timeout",a.keepaliveTimeout);t("max_handshake_attempts",a.maxHandshakeAttempts);t("persistent_keepalive",a.persistentKeepalive); fields.append("\"amnezia\":{\(x.joined(separator: ","))}") }
        let bytes=Data(("{"+fields.joined(separator: ",")+"}").utf8); return "sha256:"+SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
}
