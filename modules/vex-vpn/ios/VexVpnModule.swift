import CryptoKit
import ExpoModulesCore
import Foundation
import Network
import NetworkExtension
import Security

public class VexVpnModule: Module {
  private let keyStore = WireGuardKeyStore()
  private let tunnelStore = IosTunnelStore()

  public func definition() -> ModuleDefinition {
    Name("VexVpn")

    AsyncFunction("needsPermission") { () -> Bool in
      return false
    }

    AsyncFunction("requestPermission") { () -> Bool in
      return true
    }

    AsyncFunction("connect") { (config: String) async throws -> [String: Any] in
      try await self.tunnelStore.connect(config: config)
      return await self.tunnelStore.currentStatus()
    }

    AsyncFunction("disconnect") { () async throws -> [String: Any] in
      try await self.tunnelStore.disconnect()
      return await self.tunnelStore.currentStatus()
    }

    AsyncFunction("status") { () async -> [String: Any] in
      return await self.tunnelStore.currentStatus()
    }

    AsyncFunction("getOrCreateWireGuardKeyPair") { () throws -> [String: Any] in
      return try self.keyStore.getOrCreateKeyPair().toDictionary()
    }

    AsyncFunction("generateWireGuardKeyPair") { () -> [String: Any] in
      return WireGuardKeyPair.generate(keyEpoch: self.keyStore.nextKeyEpoch()).toDictionary()
    }

    AsyncFunction("replaceWireGuardKeyPair") { (privateKey: String, publicKey: String, keyEpoch: Int) throws -> Bool in
      try self.keyStore.replaceKeyPair(WireGuardKeyPair(
        privateKey: privateKey,
        publicKey: publicKey,
        keyEpoch: max(keyEpoch, 1)
      ))
      return true
    }

    AsyncFunction("resetWireGuardKeyPair") { () -> Bool in
      self.keyStore.resetKeyPair()
      return true
    }

    AsyncFunction("measureEndpointLatency") { (endpoint: String) async -> Double? in
      return await EndpointLatencyProbe.measure(endpoint: endpoint)
    }

    AsyncFunction("readDiagnostics") { () -> [[String: Any]] in
      return VexVpnDiagnostics.readEvents(limit: 50)
    }

    AsyncFunction("updateLiveActivity") { (payload: [String: Any]) async -> Bool in
      return await VexVpnLiveActivityController.update(payload: payload)
    }

    AsyncFunction("endLiveActivity") { () async -> Bool in
      return await VexVpnLiveActivityController.end()
    }
  }
}

private struct WireGuardKeyPair {
  let privateKey: String
  let publicKey: String
  let keyEpoch: Int

  static func generate(keyEpoch: Int) -> WireGuardKeyPair {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    return WireGuardKeyPair(
      privateKey: privateKey.rawRepresentation.base64EncodedString(),
      publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
      keyEpoch: max(keyEpoch, 1)
    )
  }

  func normalized() throws -> WireGuardKeyPair {
    let normalizedPrivateKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPublicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Data(base64Encoded: normalizedPrivateKey)?.count == 32 else {
      throw InvalidWireGuardKeyException(field: "privateKey")
    }
    guard Data(base64Encoded: normalizedPublicKey)?.count == 32 else {
      throw InvalidWireGuardKeyException(field: "publicKey")
    }
    return WireGuardKeyPair(
      privateKey: normalizedPrivateKey,
      publicKey: normalizedPublicKey,
      keyEpoch: max(keyEpoch, 1)
    )
  }

  func toDictionary() -> [String: Any] {
    return [
      "privateKey": privateKey,
      "publicKey": publicKey,
      "keyEpoch": keyEpoch
    ]
  }
}

private final class WireGuardKeyStore {
  private let service = "com.vexguard.app.wireguard"
  private let privateKeyAccount = "private_key"
  private let publicKeyAccount = "public_key"
  private let keyEpochAccount = "key_epoch"

  func getOrCreateKeyPair() throws -> WireGuardKeyPair {
    if let keyPair = try readKeyPair() {
      return keyPair
    }
    let keyPair = WireGuardKeyPair.generate(keyEpoch: 1)
    try replaceKeyPair(keyPair)
    return keyPair
  }

  func nextKeyEpoch() -> Int {
    return (try? readKeyEpoch()).map { $0 + 1 } ?? 1
  }

  func replaceKeyPair(_ keyPair: WireGuardKeyPair) throws {
    let normalized = try keyPair.normalized()
    try writeString(normalized.privateKey, account: privateKeyAccount)
    try writeString(normalized.publicKey, account: publicKeyAccount)
    try writeString(String(normalized.keyEpoch), account: keyEpochAccount)
  }

  func resetKeyPair() {
    delete(account: privateKeyAccount)
    delete(account: publicKeyAccount)
    delete(account: keyEpochAccount)
  }

  private func readKeyPair() throws -> WireGuardKeyPair? {
    guard let privateKey = try readString(account: privateKeyAccount),
          let publicKey = try readString(account: publicKeyAccount) else {
      return nil
    }
    return try WireGuardKeyPair(
      privateKey: privateKey,
      publicKey: publicKey,
      keyEpoch: readKeyEpoch()
    ).normalized()
  }

  private func readKeyEpoch() throws -> Int {
    guard let value = try readString(account: keyEpochAccount),
          let epoch = Int(value) else {
      return 1
    }
    return max(epoch, 1)
  }

  private func readString(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainException(status: status)
    }
    guard let data = result as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private func writeString(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    var query = baseQuery(account: account)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeychainException(status: addStatus)
      }
      return
    }
    guard status == errSecSuccess else {
      throw KeychainException(status: status)
    }
  }

  private func delete(account: String) {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
  }

  private func baseQuery(account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
  }
}

private final class IosTunnelStore {
  private let providerBundleIdentifier = "com.vexguard.app.tunnel"
  private let tunnelDescription = "VEX AmneziaWG"

  func connect(config: String) async throws {
    let manager = try await loadOrCreateManager()
    let tunnelProtocol = NETunnelProviderProtocol()
    tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
    tunnelProtocol.serverAddress = Self.serverAddress(from: config)
    tunnelProtocol.providerConfiguration = [
      "WgQuickConfig": config,
      "wgQuickConfig": config,
      "createdAt": ISO8601DateFormatter().string(from: Date())
    ]

    manager.localizedDescription = tunnelDescription
    manager.protocolConfiguration = tunnelProtocol
    manager.isEnabled = true

    try await save(manager)
    try await loadFromPreferences(manager)
    try manager.connection.startVPNTunnel()
    VexVpnDiagnostics.record("ios_tunnel_start_requested", details: ["providerBundleIdentifier": providerBundleIdentifier])
  }

  func disconnect() async throws {
    let manager = try await loadExistingManager()
    manager?.connection.stopVPNTunnel()
    VexVpnDiagnostics.record("ios_tunnel_stop_requested")
  }

  func currentStatus() async -> [String: Any] {
    let manager = try? await loadExistingManager()
    let status = manager?.connection.status ?? .disconnected
    var result: [String: Any] = [
      "state": Self.stateName(status),
      "nativeState": status.rawValue,
      "rxBytes": 0,
      "txBytes": 0
    ]
    if status == .connected {
      result["verified"] = false
      result["verificationReason"] = "handshake_pending"
    }
    return result
  }

  private func loadOrCreateManager() async throws -> NETunnelProviderManager {
    if let manager = try await loadExistingManager() {
      return manager
    }
    return NETunnelProviderManager()
  }

  private func loadExistingManager() async throws -> NETunnelProviderManager? {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    return managers.first { manager in
      guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
        return false
      }
      return tunnelProtocol.providerBundleIdentifier == providerBundleIdentifier
    }
  }

  private func save(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in
        if let error {
          VexVpnDiagnostics.record("ios_tunnel_save_failed", details: ["error": error.localizedDescription])
          continuation.resume(throwing: IosTunnelException(message: error.localizedDescription))
          return
        }
        continuation.resume()
      }
    }
  }

  private func loadFromPreferences(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.loadFromPreferences { error in
        if let error {
          continuation.resume(throwing: IosTunnelException(message: error.localizedDescription))
          return
        }
        continuation.resume()
      }
    }
  }

  private static func stateName(_ status: NEVPNStatus) -> String {
    switch status {
    case .connected:
      return "connected"
    case .connecting, .reasserting:
      return "connecting"
    case .disconnecting:
      return "disconnecting"
    case .invalid, .disconnected:
      return "disconnected"
    @unknown default:
      return "error"
    }
  }

  private static func serverAddress(from config: String) -> String {
    for line in config.components(separatedBy: .newlines) {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedLine.lowercased().hasPrefix("endpoint") {
        return trimmedLine.components(separatedBy: "=").dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return "VEX AmneziaWG"
  }
}

enum VexVpnDiagnostics {
  private static let appGroupIdentifier = "group.com.vexguard.app"
  private static let logFileName = "vex-vpn-diagnostics.jsonl"

  static func record(_ event: String, details: [String: String] = [:]) {
    guard let url = diagnosticsFileURL() else {
      return
    }
    let payload: [String: Any] = [
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "source": "app",
      "event": event,
      "details": details
    ]
    append(payload, to: url)
  }

  static func readEvents(limit: Int) -> [[String: Any]] {
    guard let url = diagnosticsFileURL(),
          let data = try? Data(contentsOf: url),
          let content = String(data: data, encoding: .utf8) else {
      return []
    }

    return content
      .split(separator: "\n")
      .suffix(max(limit, 1))
      .compactMap { line in
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any] else {
          return nil
        }
        return event
      }
  }

  private static func diagnosticsFileURL() -> URL? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
      return nil
    }
    return container.appendingPathComponent(logFileName)
  }

  private static func append(_ payload: [String: Any], to url: URL) {
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload),
          var line = String(data: data, encoding: .utf8) else {
      return
    }
    line.append("\n")

    if FileManager.default.fileExists(atPath: url.path) == false {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    guard let handle = try? FileHandle(forWritingTo: url) else {
      return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    _ = try? handle.write(contentsOf: Data(line.utf8))
  }
}

private enum EndpointLatencyProbe {
  static func measure(endpoint: String) async -> Double? {
    guard let host = endpointHost(endpoint) else {
      return nil
    }
    let start = ContinuousClock.now
    let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)

    return await withCheckedContinuation { continuation in
      let state = LatencyProbeState()
      @Sendable func finish(_ value: Double?) {
        if state.resolve() == false {
          return
        }
        connection.cancel()
        continuation.resume(returning: value)
      }

      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          let elapsed = start.duration(to: ContinuousClock.now)
          finish(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000)
        case .failed, .cancelled:
          finish(nil)
        default:
          break
        }
      }
      connection.start(queue: .global(qos: .utility))
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
        finish(nil)
      }
    }
  }

  private static func endpointHost(_ endpoint: String) -> String? {
    let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
      return nil
    }
    if value.hasPrefix("[") && value.contains("]") {
      return value.dropFirst().split(separator: "]").first.map(String.init)
    }
    if let lastColon = value.lastIndex(of: ":"), value[..<lastColon].contains(":") == false {
      return String(value[..<lastColon])
    }
    return value
  }
}

private final class LatencyProbeState: @unchecked Sendable {
  private let lock = NSLock()
  private var resolved = false

  func resolve() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if resolved {
      return false
    }
    resolved = true
    return true
  }
}

private final class IosTunnelException: Exception, @unchecked Sendable {
  private let message: String

  init(message: String) {
    self.message = message
    super.init()
  }

  override var reason: String {
    "iOS tunnel operation failed: \(message)"
  }
}

private final class InvalidWireGuardKeyException: Exception, @unchecked Sendable {
  private let field: String

  init(field: String) {
    self.field = field
    super.init()
  }

  override var reason: String {
    "Invalid WireGuard \(field). Expected base64-encoded 32-byte key."
  }
}

private final class KeychainException: Exception, @unchecked Sendable {
  private let status: OSStatus

  init(status: OSStatus) {
    self.status = status
    super.init()
  }

  override var reason: String {
    "Keychain operation failed with status \(status)."
  }
}
