// Property-only models for exercising the production parser on hosts without
// Network.framework. Their API follows the pinned WireGuardKit model types;
// these tests do not validate IP parsing, DNS resolution, or an iOS SDK build.
import Foundation
public struct PublicKey: Hashable { public let key: String; public init?(base64Key: String) { guard Data(base64Encoded: base64Key)?.count == 32 else { return nil }; key = base64Key } }
public struct PrivateKey: Equatable { public let key: String; public init?(base64Key: String) { guard Data(base64Encoded: base64Key)?.count == 32 else { return nil }; key = base64Key } }
public struct PreSharedKey: Equatable { public let key: String; public init?(base64Key: String) { guard Data(base64Encoded: base64Key)?.count == 32 else { return nil }; key = base64Key } }
public struct IPAddressRange: Equatable { public let stringRepresentation: String; public init?(from: String) { guard !from.isEmpty else { return nil }; stringRepresentation = from } }
public struct DNSServer: Equatable { public let stringRepresentation: String; public init?(from: String) { guard !from.isEmpty else { return nil }; stringRepresentation = from } }
public struct Endpoint: Equatable { public let stringRepresentation: String; public init?(from: String) { guard !from.isEmpty else { return nil }; stringRepresentation = from } }
public struct InterfaceConfiguration {
 public let privateKey: PrivateKey
 public init(privateKey: PrivateKey) { self.privateKey = privateKey }
 public var listenPort: UInt16?
 public var addresses: [IPAddressRange] = []
 public var dns: [DNSServer] = []
 public var dnsSearch: [String] = []
 public var mtu: UInt16?
 public var headerProtectionKey: PrivateKey?
 public var junkPacketCount: UInt16?
 public var junkPacketMinSize: UInt16?
 public var junkPacketMaxSize: UInt16?
 public var initPacketJunkSize: UInt16?
 public var responsePacketJunkSize: UInt16?
 public var cookieReplyPacketJunkSize: UInt16?
 public var transportPacketJunkSize: UInt16?
 public var initPacketMagicHeader: String?
 public var responsePacketMagicHeader: String?
 public var underloadPacketMagicHeader: String?
 public var transportPacketMagicHeader: String?
 public var specialJunk1: String?
 public var specialJunk2: String?
 public var specialJunk3: String?
 public var specialJunk4: String?
 public var specialJunk5: String?
 public var contentPaddingAddition: String?
 public var rekeyAfterTime: String?
 public var rekeyTimeout: String?
 public var rejectAfterTime: String?
 public var keepaliveTimeout: String?
 public var maxHandshakeAttempts: String?
}
public struct PeerConfiguration {
 public let publicKey: PublicKey
 public init(publicKey: PublicKey) { self.publicKey = publicKey }
 public var preSharedKey: PreSharedKey?
 public var allowedIPs: [IPAddressRange] = []
 public var endpoint: Endpoint?
 public var persistentKeepAlive: String?
}
public final class TunnelConfiguration {
 public let name: String?
 public let interface: InterfaceConfiguration
 public let peers: [PeerConfiguration]
 public init(name: String?, interface: InterfaceConfiguration, peers: [PeerConfiguration]) { self.name = name; self.interface = interface; self.peers = peers }
}
