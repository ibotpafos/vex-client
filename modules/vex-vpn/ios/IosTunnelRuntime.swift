import Foundation

struct IosTunnelRuntimeStats: Sendable {
  let rxBytes: UInt64
  let txBytes: UInt64
  let latestHandshakeEpochMillis: UInt64

  // UAPI can contain private keys. Only these aggregate numeric fields may
  // cross the native status boundary; never retain or log the raw response.
  static func parse(_ data: Data?) -> IosTunnelRuntimeStats? {
    guard let data, data.count <= 128 * 1024,
          let text = String(data: data, encoding: .utf8) else { return nil }
    let maximumSafeInteger: UInt64 = 9_007_199_254_740_991
    let fields: Set<String> = ["rx_bytes", "tx_bytes", "last_handshake_time_sec", "last_handshake_time_nsec"]
    var peer: [String: UInt64]?
    var totalRX: UInt64 = 0
    var totalTX: UInt64 = 0
    var latestHandshake: UInt64 = 0
    var peerCount = 0

    func finishPeer() -> Bool {
      guard let peer, let rx = peer["rx_bytes"], let tx = peer["tx_bytes"],
            let seconds = peer["last_handshake_time_sec"] else { return false }
      let nanos = peer["last_handshake_time_nsec"] ?? 0
      guard nanos < 1_000_000_000, seconds <= maximumSafeInteger / 1000,
            rx <= maximumSafeInteger - totalRX, tx <= maximumSafeInteger - totalTX else { return false }
      let handshake = seconds == 0 ? 0 : seconds * 1000 + nanos / 1_000_000
      guard handshake <= maximumSafeInteger else { return false }
      totalRX += rx
      totalTX += tx
      latestHandshake = max(latestHandshake, handshake)
      peerCount += 1
      return true
    }

    for line in text.split(whereSeparator: { $0.isNewline }) {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      let key = String(parts[0])
      if key == "public_key" {
        if peer != nil && !finishPeer() { return nil }
        peer = [:]
      } else if fields.contains(key) || key == "errno" {
        let value = parts[1]
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = UInt64(value), number <= maximumSafeInteger else { return nil }
        if key == "errno" {
          guard number == 0 else { return nil }
        } else {
          guard peer != nil, peer?[key] == nil else { return nil }
          peer?[key] = number
        }
      }
    }
    guard finishPeer(), peerCount > 0 else { return nil }
    return IosTunnelRuntimeStats(rxBytes: totalRX, txBytes: totalTX, latestHandshakeEpochMillis: latestHandshake)
  }
}

enum IosTunnelRuntimeReader {
  static func read(
    timeoutSeconds: TimeInterval = 1,
    send: (_ request: Data, _ response: @escaping (Data?) -> Void) throws -> Void
  ) async -> IosTunnelRuntimeStats? {
    await withCheckedContinuation { continuation in
      let reply = RuntimeReply { continuation.resume(returning: IosTunnelRuntimeStats.parse($0)) }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) { reply.resolve(nil) }
      do {
        // Reuse the extension's existing WireGuard runtime query contract.
        try send(Data([0])) { reply.resolve($0) }
      } catch {
        reply.resolve(nil)
      }
    }
  }
}

private final class RuntimeReply: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: ((Data?) -> Void)?

  init(completion: @escaping (Data?) -> Void) { self.completion = completion }

  func resolve(_ data: Data?) {
    lock.lock()
    let callback = completion
    completion = nil
    lock.unlock()
    callback?(data)
  }
}
