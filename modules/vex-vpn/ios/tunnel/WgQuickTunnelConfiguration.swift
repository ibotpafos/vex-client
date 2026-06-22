import Foundation
import WireGuardKit

extension TunnelConfiguration {
  enum WgQuickParseError: Error {
    case invalidLine(String.SubSequence)
    case noInterface
    case multipleInterfaces
    case interfaceHasNoPrivateKey
    case interfaceHasInvalidPrivateKey(String)
    case interfaceHasInvalidListenPort(String)
    case interfaceHasInvalidAddress(String)
    case interfaceHasInvalidDNS(String)
    case interfaceHasInvalidMTU(String)
    case interfaceHasInvalidCustomParam(String)
    case interfaceHasUnrecognizedKey(String)
    case peerHasNoPublicKey
    case peerHasInvalidPublicKey(String)
    case peerHasInvalidPreSharedKey(String)
    case peerHasInvalidAllowedIP(String)
    case peerHasInvalidEndpoint(String)
    case peerHasInvalidPersistentKeepAlive(String)
    case peerHasUnrecognizedKey(String)
    case multiplePeersWithSamePublicKey
    case multipleEntriesForKey(String)
  }

  convenience init(fromWgQuickConfig wgQuickConfig: String, called name: String? = nil) throws {
    var interfaceConfiguration: InterfaceConfiguration?
    var peerConfigurations = [PeerConfiguration]()
    var parserState = WgQuickParserState.notInASection
    var attributes = [String: String]()
    let lines = wgQuickConfig.split { $0.isNewline }

    for (lineIndex, line) in lines.enumerated() {
      let trimmedLine = WgQuickLine.trim(line)
      let lowercasedLine = trimmedLine.lowercased()

      if !trimmedLine.isEmpty {
        if let equalsIndex = trimmedLine.firstIndex(of: "=") {
          let keyWithCase = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
          let key = keyWithCase.lowercased()
          let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...].trimmingCharacters(in: .whitespacesAndNewlines)
          try WgQuickLine.collect(key: key, keyWithCase: keyWithCase, value: value, into: &attributes)
          try WgQuickLine.validate(key: key, keyWithCase: keyWithCase, for: parserState)
        } else if lowercasedLine != "[interface]" && lowercasedLine != "[peer]" {
          throw WgQuickParseError.invalidLine(line)
        }
      }

      let isLastLine = lineIndex == lines.count - 1
      if isLastLine || lowercasedLine == "[interface]" || lowercasedLine == "[peer]" {
        if parserState == .inInterfaceSection {
          let interface = try TunnelConfiguration.collate(interfaceAttributes: attributes)
          guard interfaceConfiguration == nil else { throw WgQuickParseError.multipleInterfaces }
          interfaceConfiguration = interface
        } else if parserState == .inPeerSection {
          let peer = try TunnelConfiguration.collate(peerAttributes: attributes)
          peerConfigurations.append(peer)
        }
      }

      if lowercasedLine == "[interface]" {
        parserState = .inInterfaceSection
        attributes.removeAll()
      } else if lowercasedLine == "[peer]" {
        parserState = .inPeerSection
        attributes.removeAll()
      }
    }

    let peerPublicKeys = peerConfigurations.map(\.publicKey)
    guard peerPublicKeys.count == Set<PublicKey>(peerPublicKeys).count else {
      throw WgQuickParseError.multiplePeersWithSamePublicKey
    }
    guard let interfaceConfiguration else {
      throw WgQuickParseError.noInterface
    }

    self.init(name: name, interface: interfaceConfiguration, peers: peerConfigurations)
  }

  private static func collate(interfaceAttributes attributes: [String: String]) throws -> InterfaceConfiguration {
    guard let privateKeyString = attributes["privatekey"] else {
      throw WgQuickParseError.interfaceHasNoPrivateKey
    }
    guard let privateKey = PrivateKey(base64Key: privateKeyString) else {
      throw WgQuickParseError.interfaceHasInvalidPrivateKey(privateKeyString)
    }

    var interface = InterfaceConfiguration(privateKey: privateKey)
    try applyStandardInterfaceAttributes(attributes, to: &interface)
    try applyAmneziaInterfaceAttributes(attributes, to: &interface)
    return interface
  }

  private static func applyStandardInterfaceAttributes(
    _ attributes: [String: String],
    to interface: inout InterfaceConfiguration
  ) throws {
    if let listenPortString = attributes["listenport"] {
      guard let listenPort = UInt16(listenPortString) else {
        throw WgQuickParseError.interfaceHasInvalidListenPort(listenPortString)
      }
      interface.listenPort = listenPort
    }
    if let addressesString = attributes["address"] {
      interface.addresses = try addressesString.splitToArray(trimmingCharacters: .whitespacesAndNewlines).map {
        guard let address = IPAddressRange(from: $0) else {
          throw WgQuickParseError.interfaceHasInvalidAddress($0)
        }
        return address
      }
    }
    if let dnsString = attributes["dns"] {
      var dnsServers = [DNSServer]()
      var dnsSearch = [String]()
      for dnsServerString in dnsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
        if let dnsServer = DNSServer(from: dnsServerString) {
          dnsServers.append(dnsServer)
        } else {
          dnsSearch.append(dnsServerString)
        }
      }
      interface.dns = dnsServers
      interface.dnsSearch = dnsSearch
    }
    if let mtuString = attributes["mtu"] {
      guard let mtu = UInt16(mtuString) else {
        throw WgQuickParseError.interfaceHasInvalidMTU(mtuString)
      }
      interface.mtu = mtu
    }
  }

  private static func applyAmneziaInterfaceAttributes(
    _ attributes: [String: String],
    to interface: inout InterfaceConfiguration
  ) throws {
    interface.junkPacketCount = try uint16Value(attributes["jc"])
    interface.junkPacketMinSize = try uint16Value(attributes["jmin"])
    interface.junkPacketMaxSize = try uint16Value(attributes["jmax"])
    interface.initPacketJunkSize = try uint16Value(attributes["s1"])
    interface.responsePacketJunkSize = try uint16Value(attributes["s2"])
    interface.cookieReplyPacketJunkSize = try uint16Value(attributes["s3"])
    interface.transportPacketJunkSize = try uint16Value(attributes["s4"])
    interface.initPacketMagicHeader = attributes["h1"]
    interface.responsePacketMagicHeader = attributes["h2"]
    interface.underloadPacketMagicHeader = attributes["h3"]
    interface.transportPacketMagicHeader = attributes["h4"]
    interface.specialJunk1 = attributes["i1"]
    interface.specialJunk2 = attributes["i2"]
    interface.specialJunk3 = attributes["i3"]
    interface.specialJunk4 = attributes["i4"]
    interface.specialJunk5 = attributes["i5"]
  }

  private static func collate(peerAttributes attributes: [String: String]) throws -> PeerConfiguration {
    guard let publicKeyString = attributes["publickey"] else {
      throw WgQuickParseError.peerHasNoPublicKey
    }
    guard let publicKey = PublicKey(base64Key: publicKeyString) else {
      throw WgQuickParseError.peerHasInvalidPublicKey(publicKeyString)
    }

    var peer = PeerConfiguration(publicKey: publicKey)
    if let preSharedKeyString = attributes["presharedkey"] {
      guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
        throw WgQuickParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
      }
      peer.preSharedKey = preSharedKey
    }
    if let allowedIPsString = attributes["allowedips"] {
      peer.allowedIPs = try allowedIPsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines).map {
        guard let allowedIP = IPAddressRange(from: $0) else {
          throw WgQuickParseError.peerHasInvalidAllowedIP($0)
        }
        return allowedIP
      }
    }
    if let endpointString = attributes["endpoint"] {
      guard let endpoint = Endpoint(from: endpointString) else {
        throw WgQuickParseError.peerHasInvalidEndpoint(endpointString)
      }
      peer.endpoint = endpoint
    }
    if let persistentKeepAliveString = attributes["persistentkeepalive"] {
      guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
        throw WgQuickParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
      }
      peer.persistentKeepAlive = persistentKeepAlive
    }
    return peer
  }

  private static func uint16Value(_ value: String?) throws -> UInt16? {
    guard let value else {
      return nil
    }
    guard let parsed = UInt16(value) else {
      throw WgQuickParseError.interfaceHasInvalidCustomParam(value)
    }
    return parsed
  }
}

private enum WgQuickParserState {
  case inInterfaceSection
  case inPeerSection
  case notInASection
}

private enum WgQuickLine {
  static func trim(_ line: String.SubSequence) -> String {
    let uncommented = line.range(of: "#").map { line[..<$0.lowerBound] } ?? line
    return String(uncommented).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func collect(
    key: String,
    keyWithCase: String,
    value: String,
    into attributes: inout [String: String]
  ) throws {
    let keysWithMultipleEntriesAllowed: Set<String> = ["address", "allowedips", "dns"]
    if let presentValue = attributes[key] {
      guard keysWithMultipleEntriesAllowed.contains(key) else {
        throw TunnelConfiguration.WgQuickParseError.multipleEntriesForKey(keyWithCase)
      }
      attributes[key] = presentValue + "," + value
    } else {
      attributes[key] = value
    }
  }

  static func validate(
    key: String,
    keyWithCase: String,
    for parserState: WgQuickParserState
  ) throws {
    switch parserState {
    case .inInterfaceSection:
      guard interfaceSectionKeys.contains(key) else {
        throw TunnelConfiguration.WgQuickParseError.interfaceHasUnrecognizedKey(keyWithCase)
      }
    case .inPeerSection:
      guard peerSectionKeys.contains(key) else {
        throw TunnelConfiguration.WgQuickParseError.peerHasUnrecognizedKey(keyWithCase)
      }
    case .notInASection:
      break
    }
  }

  private static let interfaceSectionKeys: Set<String> = [
    "privatekey",
    "listenport",
    "address",
    "dns",
    "mtu",
    "jc",
    "jmin",
    "jmax",
    "s1",
    "s2",
    "s3",
    "s4",
    "h1",
    "h2",
    "h3",
    "h4",
    "i1",
    "i2",
    "i3",
    "i4",
    "i5"
  ]

  private static let peerSectionKeys: Set<String> = [
    "publickey",
    "presharedkey",
    "allowedips",
    "endpoint",
    "persistentkeepalive"
  ]
}

private extension String {
  func splitToArray(separator: Character = ",", trimmingCharacters: CharacterSet? = nil) -> [String] {
    split(separator: separator).map {
      if let trimmingCharacters {
        return $0.trimmingCharacters(in: trimmingCharacters)
      }
      return String($0)
    }
  }
}
