import Foundation
import NetworkExtension
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let diagnostics = TunnelDiagnostics(source: "extension")
  private var policyCacheTimer: DispatchSourceTimer?
  private lazy var adapter = WireGuardAdapter(with: self) { [weak self] level, message in
    self?.diagnostics.record("wireguard_log", details: [
      "level": level.diagnosticName,
      "message": message
    ])
  }

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    guard let tunnelConfiguration = makeTunnelConfiguration() else {
      diagnostics.record("extension_start_failed", details: ["reason": "invalid_configuration"])
      completionHandler(TunnelConfigurationError())
      return
    }

    if let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol {
      if let raw = tunnelProtocol.providerConfiguration?["RoutingParameters"] as? String {
        guard let parameters = preparedRoutingParameters(raw, configuration: tunnelConfiguration) else {
          completionHandler(TunnelConfigurationError())
          return
        }
        adapter.routingParameters = parameters
        adapter.routingStartsSuspended = routingActivationIsRetired(tunnelProtocol)
      }
    }

    diagnostics.record("extension_start_requested", details: [
      "peers": String(tunnelConfiguration.peers.count)
    ])

    adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] error in
      if let error {
        self?.diagnostics.record("extension_start_failed", details: [
          "reason": error.diagnosticName
        ])
        completionHandler(error)
        return
      }

      self?.diagnostics.record("extension_started", details: [
        "interface": self?.adapter.interfaceName ?? "unknown"
      ])
      self?.startPolicyCacheTimer()
      completionHandler(nil)
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    policyCacheTimer?.cancel()
    policyCacheTimer = nil
    diagnostics.record("extension_stop_requested", details: ["reason": String(reason.rawValue)])
    adapter.stop { [weak self] error in
      if let error {
        self?.diagnostics.record("extension_stop_failed", details: ["error": error.localizedDescription])
      } else {
        self?.diagnostics.record("extension_stopped")
      }
      completionHandler()
    }
  }

  private var policyCacheURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.vexguard.app")?
      .appendingPathComponent("routing-policy-v2.json")
  }

  private var retiredActivationURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.vexguard.app")?
      .appendingPathComponent("routing-retired-activation.txt")
  }

  private func routingActivationIsRetired(_ tunnelProtocol: NETunnelProviderProtocol) -> Bool {
    guard let activation = tunnelProtocol.providerConfiguration?["RoutingActivationID"] as? String,
          UUID(uuidString: activation) != nil, let url = retiredActivationURL else { return true }
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber, size.intValue <= 64,
          let data = try? Data(contentsOf: url) else { return true }
    return String(data: data, encoding: .utf8) == activation
  }

  private func persistRetiredActivation() throws {
    guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
          let activation = tunnelProtocol.providerConfiguration?["RoutingActivationID"] as? String,
          UUID(uuidString: activation) != nil, let url = retiredActivationURL else {
      throw TunnelConfigurationError()
    }
    // On-demand may restart this same provider after a crash. Retire its
    // activation before stopping crypto, so restart retains capture without
    // replaying the saved account's peer keys. A new connect creates a new ID.
    try Data(activation.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private func preparedRoutingParameters(_ raw: String, configuration: TunnelConfiguration) -> String? {
    guard raw.utf8.count <= 2 * 1024 * 1024,
          var value = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
          let mode = value["mode"] as? String, ["full_tunnel", "all_except_ru"].contains(mode) else { return nil }
    value["addresses"] = configuration.interface.addresses.map { $0.stringRepresentation }
    value["dns"] = configuration.interface.dns.map { $0.stringRepresentation }
    value.removeValue(forKey: "previous_authorization")
    if let url = policyCacheURL,
       let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attributes[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024,
       let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024,
       let previous = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      value["previous_authorization"] = previous
      if mode == "all_except_ru" && value["authorization"] == nil { value["authorization"] = previous }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func startPolicyCacheTimer() {
    guard adapter.routingParameters != nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.vexguard.routing-cache"))
    timer.schedule(deadline: .now(), repeating: 5 * 60)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.adapter.verifiedRoutingAuthorization { [weak self] authorization in
        guard let self, let authorization, let url = self.policyCacheURL else { return }
        // The bridge returns only a successfully verified signature. Go checks
        // its platform, expiry and replay floor again on every cache reuse.
        try? Data(authorization.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
    }
    policyCacheTimer = timer
    timer.resume()
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    if messageData == Data([1]) {
      do { try persistRetiredActivation() }
      catch { completionHandler?(Data([0])); return }
      adapter.stopRoutingTransport { stopped in completionHandler?(Data([stopped ? 1 : 0])) }
      return
    }
    guard messageData.count == 1, messageData[0] == 0 else {
      completionHandler?(nil)
      return
    }
    adapter.getRuntimeConfiguration { settings in
      let stopped = self.adapter.routingTransportStopped
      completionHandler?(((settings ?? "") + (stopped ? "\nvex_transport_stopped=true\n" : "")).data(using: .utf8))
    }
  }

  private func makeTunnelConfiguration() -> TunnelConfiguration? {
    guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
      return nil
    }
    if let config = tunnelProtocol.providerConfiguration?["WgQuickConfig"] as? String {
      return try? TunnelConfiguration(fromWgQuickConfig: config, called: "VEX")
    }
    if let config = tunnelProtocol.providerConfiguration?["wgQuickConfig"] as? String {
      return try? TunnelConfiguration(fromWgQuickConfig: config, called: "VEX")
    }
    return nil
  }
}

private struct TunnelConfigurationError: LocalizedError {
  var errorDescription: String? {
    "VEX iOS tunnel configuration is invalid or missing."
  }
}

private extension WireGuardAdapterError {
  var diagnosticName: String {
    switch self {
    case .cannotLocateTunnelFileDescriptor:
      return "cannot_locate_tunnel_file_descriptor"
    case .invalidState:
      return "invalid_state"
    case .dnsResolution:
      return "dns_resolution"
    case .setNetworkSettings:
      return "set_network_settings"
    case .startWireGuardBackend:
      return "start_wireguard_backend"
    }
  }
}

private extension WireGuardLogLevel {
  var diagnosticName: String {
    switch self {
    case .verbose:
      return "verbose"
    case .error:
      return "error"
    }
  }
}

private struct TunnelDiagnostics {
  private let appGroupIdentifier = "group.com.vexguard.app"
  private let logFileName = "vex-vpn-diagnostics.jsonl"
  private let source: String

  init(source: String) {
    self.source = source
  }

  func record(_ event: String, details: [String: String] = [:]) {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
      return
    }
    let payload: [String: Any] = [
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "source": source,
      "event": event,
      "details": details
    ]
    append(payload, to: container.appendingPathComponent(logFileName))
  }

  private func append(_ payload: [String: Any], to url: URL) {
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
