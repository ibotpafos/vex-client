import Foundation
import WireGuardKit
import XCTest
@testable import IosWgQuickParserHarness

final class IosWgQuickParserTests: XCTestCase {
  private let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
  private let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
  private let secondPublicKey = Data(repeating: 3, count: 32).base64EncodedString()

  private var interface: String {
    "[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.0.0.2/32\n"
  }

  private func peer(key: String, attributes: String = "") -> String {
    "[Peer]\nPublicKey = \(key)\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n" + attributes
  }

  func testEmptyFinalPeerIsRejectedRegardlessOfTrailingWhitespaceOrComment() {
    for suffix in ["", "\n", "\n\n", "\n# final comment"] {
      XCTAssertThrowsError(try TunnelConfiguration(fromWgQuickConfig: interface + "[Peer]" + suffix)) { error in
        guard case TunnelConfiguration.WgQuickParseError.peerHasNoPublicKey = error else {
          return XCTFail("Expected a missing public key, got \(error)")
        }
      }
    }
  }

  func testEmptyAdditionalFinalPeerIsRejected() {
    let config = interface + peer(key: publicKey) + "[Peer]"
    XCTAssertThrowsError(try TunnelConfiguration(fromWgQuickConfig: config)) { error in
      guard case TunnelConfiguration.WgQuickParseError.peerHasNoPublicKey = error else {
        return XCTFail("Expected a missing public key, got \(error)")
      }
    }
  }

  func testEmptyAdditionalFinalInterfaceIsRejected() {
    for suffix in ["", "\n", "\n# final comment"] {
      let config = interface + peer(key: publicKey) + "[Interface]" + suffix
      XCTAssertThrowsError(try TunnelConfiguration(fromWgQuickConfig: config))
    }
  }

  func testFinalPeerWithAttributesIsPreserved() throws {
    let config = try TunnelConfiguration(
      fromWgQuickConfig: interface + peer(key: publicKey, attributes: "PersistentKeepalive = 22-30"),
      called: "VEX"
    )
    XCTAssertEqual(config.name, "VEX")
    XCTAssertEqual(config.interface.privateKey, PrivateKey(base64Key: privateKey))
    XCTAssertEqual(config.peers.count, 1)
    XCTAssertEqual(config.peers[0].publicKey, PublicKey(base64Key: publicKey))
    XCTAssertEqual(config.peers[0].persistentKeepAlive, "22-30")
  }

  func testMultiplePeersAreFlushedExactlyOnce() throws {
    let config = try TunnelConfiguration(fromWgQuickConfig:
      interface + peer(key: publicKey) + peer(key: secondPublicKey) + "# final comment"
    )
    XCTAssertEqual(config.peers.map(\.publicKey), [
      PublicKey(base64Key: publicKey)!, PublicKey(base64Key: secondPublicKey)!
    ])
  }

  func testDuplicatePeerPublicKeysAreRejected() {
    XCTAssertThrowsError(try TunnelConfiguration(fromWgQuickConfig:
      interface + peer(key: publicKey) + peer(key: publicKey)
    )) { error in
      guard case TunnelConfiguration.WgQuickParseError.multiplePeersWithSamePublicKey = error else {
        return XCTFail("Expected duplicate public keys, got \(error)")
      }
    }
  }

  func testRepeatedAddressAndAllowedIPEntriesArePreserved() throws {
    let config = try TunnelConfiguration(fromWgQuickConfig:
      interface + "Address = fd00::2/128\n" + peer(key: publicKey) + "AllowedIPs = ::/0"
    )
    XCTAssertEqual(config.interface.addresses.map(\.stringRepresentation), ["10.0.0.2/32", "fd00::2/128"])
    XCTAssertEqual(config.peers[0].allowedIPs.map(\.stringRepresentation), ["0.0.0.0/0", "::/0"])
  }

  func testAmnezia3FieldsAndRangesArePreserved() throws {
    let config = try TunnelConfiguration(fromWgQuickConfig: interface + """
    Jc = 4
    Jmin = 20
    Jmax = 40
    S1 = 8
    S2 = 9
    S3 = 10
    S4 = 11
    H1 = 100-200
    I1 = <b 0x010203>
    HeaderProtectionKey = \(privateKey)
    ContentPaddingAddition = 10-20
    RekeyAfterTime = 120-180
    RekeyTimeout = 5-10
    RejectAfterTime = 180-240
    KeepaliveTimeout = 10-20
    MaxHandshakeAttempts = 8-10

    """ + peer(key: publicKey, attributes: "PersistentKeepalive = 22-30"))
    XCTAssertEqual(config.interface.junkPacketCount, 4)
    XCTAssertEqual(config.interface.junkPacketMinSize, 20)
    XCTAssertEqual(config.interface.junkPacketMaxSize, 40)
    XCTAssertEqual(config.interface.initPacketJunkSize, 8)
    XCTAssertEqual(config.interface.responsePacketJunkSize, 9)
    XCTAssertEqual(config.interface.cookieReplyPacketJunkSize, 10)
    XCTAssertEqual(config.interface.transportPacketJunkSize, 11)
    XCTAssertEqual(config.interface.initPacketMagicHeader, "100-200")
    XCTAssertEqual(config.interface.specialJunk1, "<b 0x010203>")
    XCTAssertEqual(config.interface.headerProtectionKey, PrivateKey(base64Key: privateKey))
    XCTAssertEqual(config.interface.contentPaddingAddition, "10-20")
    XCTAssertEqual(config.interface.rekeyAfterTime, "120-180")
    XCTAssertEqual(config.interface.rekeyTimeout, "5-10")
    XCTAssertEqual(config.interface.rejectAfterTime, "180-240")
    XCTAssertEqual(config.interface.keepaliveTimeout, "10-20")
    XCTAssertEqual(config.interface.maxHandshakeAttempts, "8-10")
    XCTAssertEqual(config.peers[0].persistentKeepAlive, "22-30")
  }

  func testCompleteAdditionalInterfaceIsRejected() {
    XCTAssertThrowsError(try TunnelConfiguration(fromWgQuickConfig:
      interface + peer(key: publicKey) + interface
    )) { error in
      guard case TunnelConfiguration.WgQuickParseError.multipleInterfaces = error else {
        return XCTFail("Expected multiple interfaces, got \(error)")
      }
    }
  }

  func testInterfaceWithoutPeersRemainsSupported() throws {
    let config = try TunnelConfiguration(fromWgQuickConfig: interface)
    XCTAssertTrue(config.peers.isEmpty)
  }

  func testDuplicateScalarAttributeIsRejected() {
    XCTAssertThrowsError(try TunnelConfiguration(fromWgQuickConfig:
      interface + peer(key: publicKey, attributes: "PersistentKeepalive = 25\nPersistentKeepalive = 30")
    )) { error in
      guard case TunnelConfiguration.WgQuickParseError.multipleEntriesForKey("PersistentKeepalive") = error else {
        return XCTFail("Expected a duplicate scalar attribute, got \(error)")
      }
    }
  }
}
