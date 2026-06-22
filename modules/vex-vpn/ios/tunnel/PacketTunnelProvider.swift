import Foundation
import NetworkExtension
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let diagnostics = TunnelDiagnostics(source: "extension")
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
      completionHandler(nil)
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
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

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard messageData.count == 1, messageData[0] == 0 else {
      completionHandler?(nil)
      return
    }
    adapter.getRuntimeConfiguration { settings in
      completionHandler?(settings?.data(using: .utf8))
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
