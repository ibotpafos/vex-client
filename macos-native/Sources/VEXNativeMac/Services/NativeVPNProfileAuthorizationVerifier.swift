import CryptoKit
import Foundation

/// Verifies the server-signed native-profile policy before any profile is admitted.
struct NativeVPNProfileAuthorizationVerifier {
    enum Failure: Error { case missingAuthorization, missingTrustAnchor, malformed, signature, policyMismatch, expired }
    struct Verified { let envelope: PSKRotationCurrentResponse; let mtu: Int; let persistentKeepalive: Int }
    private let keys: [String: Data]
    init(pinnedPublicKeyDER: [String: Data] = [:]) { self.keys = pinnedPublicKeyDER }

    /// Loads only immutable app-bundle trust anchors. Missing/invalid provisioning
    /// deliberately returns an empty verifier, which fails closed at verify().
    /// TODO: ship `native-vpn-profile-public-keys.json` after public-key provisioning.
    /// Format: { "key-id": "standard-base64-SPKI-DER" }; maximum 8 keys / 64 KiB.
    static func bundled() -> Self {
        guard let url = Bundle.main.url(forResource: "native-vpn-profile-public-keys", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count > 0, data.count <= 64 * 1024,
              let encoded = try? JSONDecoder().decode([String: String].self, from: data),
              !encoded.isEmpty, encoded.count <= 8 else { return Self() }
        var anchors: [String: Data] = [:]
        for (id, value) in encoded {
            guard !id.isEmpty, id.utf8.count <= 128,
                  let der = Data(base64Encoded: value), !der.isEmpty,
                  (try? P256.Signing.PublicKey(derRepresentation: der)) != nil else { return Self() }
            anchors[id] = der
        }
        return Self(pinnedPublicKeyDER: anchors)
    }

    func verify(_ envelope: PSKRotationCurrentResponse, ownerAccountID: String, managedDeviceID: String, locationID: String, routingMode: String, bypassRegion: String? = nil, now: Date = Date()) throws -> PSKRotationCurrentResponse {
        try verifyDetailed(envelope, ownerAccountID: ownerAccountID, managedDeviceID: managedDeviceID, locationID: locationID, routingMode: routingMode, bypassRegion: bypassRegion, now: now).envelope
    }

    func verifyDetailed(_ envelope: PSKRotationCurrentResponse, ownerAccountID: String, managedDeviceID: String, locationID: String, routingMode: String, bypassRegion: String? = nil, now: Date = Date()) throws -> Verified {
        guard let auth = envelope.profile.authorization else { throw Failure.missingAuthorization }
        guard auth.algorithm == "ECDSA_P256_SHA256_DER", let der = keys[auth.keyID] else { throw keys.isEmpty ? Failure.missingTrustAnchor : Failure.malformed }
        guard auth.keyID.utf8.count <= 128, auth.payloadBase64.utf8.count <= 1_400_000,
              auth.signatureBase64.utf8.count <= 128,
              let payload = rawURL(auth.payloadBase64), let signature = rawURL(auth.signatureBase64), payload.count <= 1 << 20 else { throw Failure.malformed }
        do { let key = try P256.Signing.PublicKey(derRepresentation: der); let sig = try P256.Signing.ECDSASignature(derRepresentation: signature); guard key.isValidSignature(sig, for: payload) else { throw Failure.signature } } catch { throw Failure.signature }
        let policy: Policy
        do { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; policy = try decoder.decode(Policy.self, from: payload) } catch { throw Failure.malformed }
        guard policy.schema == "vex.native-vpn-profile.v1", policy.userID == ownerAccountID, policy.deviceID == managedDeviceID, policy.profileVersion == envelope.profileVersion, (policy.routingMode ?? "full_tunnel") == routingMode, policy.assignedLocationID == locationID, policy.bypassRegion == bypassRegion, policy.issuedAt <= now, policy.expiresAt > now, envelope.profile.expiresAt.flatMap(parse) == policy.expiresAt, (policy.routingMode == nil || policy.routingPolicyVersion == envelope.profile.routingPolicyVersion), tunnel(policy.tunnel, envelope.profile) else { throw policy.expiresAt <= now ? Failure.expired : Failure.policyMismatch }
        var clean = envelope
        clean.profile.authorization = nil
        // Only Tunnel.AllowedIPs is signed. Never pass unsigned outer bypass
        // metadata to preparation, including explicit split-mode policies.
        clean.profile.bypassRanges = nil
        clean.profile.bypassDomains = nil
        if policy.routingMode == nil {
            // Current backend staged policies omit routing metadata and sign a full
            // tunnel. Never reinterpret this legacy proof as smart/split routing.
            // TODO(psk-signed-split-routing): server must stage and sign the requested
            // routing policy before split-mode rotation can be acknowledged safely.
            guard routingMode == "full_tunnel", policy.bypassRegion == nil,
                  policy.routingPolicyVersion == nil else { throw Failure.policyMismatch }
            clean.profile.routingPolicyVersion = nil
        }
        return Verified(envelope: clean, mtu: policy.tunnel.mtu, persistentKeepalive: policy.tunnel.persistentKeepalive)
    }
    private func rawURL(_ value: String) -> Data? { guard !value.isEmpty, !value.contains("="), value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), let d = Data(base64Encoded: value.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/") + String(repeating:"=", count:(4-value.count % 4)%4)) else{return nil}; return d.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") == value ? d:nil }
    private func parse(_ s: String) -> Date? { let a=ISO8601DateFormatter(); a.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; let b=ISO8601DateFormatter(); b.formatOptions=[.withInternetDateTime]; return a.date(from:s) ?? b.date(from:s) }
    private func tunnel(_ t: Tunnel, _ p: ManagedVpnProfile) -> Bool {
        guard t.protocol == p.protocol,
              t.endpoint == endpoint(server: p.server, port: p.port),
              t.assignedIPv4 == p.assignedIpv4,
              t.serverPublicKey == p.serverPublicKey,
              t.presharedKey == p.presharedKey,
              t.dns == p.dns,
              t.allowedIPs == p.allowedIps,
              t.mtu >= 576, t.mtu <= 9000,
              t.persistentKeepalive >= 0, t.persistentKeepalive <= 65535,
              amnezia(t.amnezia, p.amnezia)
        else { return false }
        return true
    }
    private func endpoint(server: String?, port: Int?) -> String {
        let host = server ?? ""
        return host.contains(":") ? "[\(host)]:\(port ?? 0)" : "\(host):\(port ?? 0)"
    }
    // The response model intentionally exposes every server-rendered AWG field.
    // MTU/keepalive are signed too, but are consumed from the signed config rather
    // than duplicated in this response shape; validate their syntax above.
    private func amnezia(_ signed: Amnezia?, _ rendered: ManagedVpnAmnezia?) -> Bool {
        guard let signed else { return rendered == nil }
        guard let rendered else { return false }
        return signed.jc == rendered.jc && signed.jmin == rendered.jmin && signed.jmax == rendered.jmax &&
            signed.s1 == rendered.s1 && signed.s2 == rendered.s2 && signed.s3 == rendered.s3 && signed.s4 == rendered.s4 &&
            signed.h1 == rendered.h1 && signed.h2 == rendered.h2 && signed.h3 == rendered.h3 && signed.h4 == rendered.h4 &&
            signed.i1 == rendered.i1 && signed.i2 == rendered.i2 && signed.i3 == rendered.i3 && signed.i4 == rendered.i4 && signed.i5 == rendered.i5 &&
            signed.headerProtectionKey == rendered.headerProtectionKey && signed.contentPaddingAddition == rendered.contentPaddingAddition &&
            signed.rekeyAfterTime == rendered.rekeyAfterTime && signed.rekeyTimeout == rendered.rekeyTimeout &&
            signed.rejectAfterTime == rendered.rejectAfterTime && signed.keepaliveTimeout == rendered.keepaliveTimeout &&
            signed.maxHandshakeAttempts == rendered.maxHandshakeAttempts &&
            signed.persistentKeepalive == rendered.persistentKeepalive &&
            rendered.randomTrailers == nil && rendered.disableCookies == nil
    }
    private struct Policy: Decodable { let schema:String; let userID:String; let deviceID:String; let assignedLocationID:String; let routingMode:String?; let bypassRegion:String?; let routingPolicyVersion:String?; let profileVersion:Int; let issuedAt:Date; let expiresAt:Date; let tunnel:Tunnel
        enum CodingKeys:String,CodingKey { case schema; case userID="user_id"; case deviceID="device_id"; case assignedLocationID="assigned_location_id"; case routingMode="routing_mode"; case bypassRegion="bypass_region"; case routingPolicyVersion="routing_policy_version"; case profileVersion="profile_version"; case issuedAt="issued_at"; case expiresAt="expires_at"; case tunnel }
    }
    private struct Tunnel: Decodable { let `protocol`:String; let endpoint:String; let assignedIPv4:String; let serverPublicKey:String; let presharedKey:String; let dns:[String]; let allowedIPs:[String]; let mtu:Int; let persistentKeepalive:Int; let amnezia: Amnezia?
        enum CodingKeys:String,CodingKey { case `protocol`,endpoint,dns,mtu,amnezia; case assignedIPv4="assigned_ipv4"; case serverPublicKey="server_public_key"; case presharedKey="preshared_key"; case allowedIPs="allowed_ips"; case persistentKeepalive="persistent_keepalive" }
    }
    private struct Amnezia: Decodable { let jc:Int?; let jmin:Int?; let jmax:Int?; let s1:Int?; let s2:Int?; let s3:Int?; let s4:Int?; let h1:String?; let h2:String?; let h3:String?; let h4:String?; let i1:String?; let i2:String?; let i3:String?; let i4:String?; let i5:String?; let headerProtectionKey:String?; let contentPaddingAddition:String?; let rekeyAfterTime:String?; let rekeyTimeout:String?; let rejectAfterTime:String?; let keepaliveTimeout:String?; let maxHandshakeAttempts:String?; let persistentKeepalive:String?
        enum CodingKeys:String,CodingKey { case jc,jmin,jmax,s1,s2,s3,s4,h1,h2,h3,h4,i1,i2,i3,i4,i5; case headerProtectionKey="header_protection_key"; case contentPaddingAddition="content_padding_addition"; case rekeyAfterTime="rekey_after_time"; case rekeyTimeout="rekey_timeout"; case rejectAfterTime="reject_after_time"; case keepaliveTimeout="keepalive_timeout"; case maxHandshakeAttempts="max_handshake_attempts"; case persistentKeepalive="persistent_keepalive" }
    }
}
