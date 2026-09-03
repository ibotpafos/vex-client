import Foundation

struct IosTunnelRuntimeStatus: Equatable {
  let latestHandshakeEpochMillis: Int64?
  let rxBytes: Int64
  let txBytes: Int64

  var isVerified: Bool {
    (latestHandshakeEpochMillis ?? 0) > 0
  }

  static func parse(_ runtimeConfiguration: String) -> IosTunnelRuntimeStatus {
    var latestHandshakeEpochMillis: Int64 = 0
    var currentHandshakeSeconds: Int64?
    var rxBytes: Int64 = 0
    var txBytes: Int64 = 0

    for rawLine in runtimeConfiguration.split(whereSeparator: \.isNewline) {
      let components = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard components.count == 2 else {
        continue
      }
      let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)

      switch key {
      case "public_key":
        currentHandshakeSeconds = nil
      case "last_handshake_time_sec":
        currentHandshakeSeconds = nonNegativeInteger(value)
        updateLatestHandshake(
          seconds: currentHandshakeSeconds,
          nanoseconds: 0,
          latestMilliseconds: &latestHandshakeEpochMillis
        )
      case "last_handshake_time_nsec":
        updateLatestHandshake(
          seconds: currentHandshakeSeconds,
          nanoseconds: nonNegativeInteger(value) ?? 0,
          latestMilliseconds: &latestHandshakeEpochMillis
        )
      case "rx_bytes":
        addSaturating(nonNegativeInteger(value), to: &rxBytes)
      case "tx_bytes":
        addSaturating(nonNegativeInteger(value), to: &txBytes)
      default:
        continue
      }
    }

    return IosTunnelRuntimeStatus(
      latestHandshakeEpochMillis: latestHandshakeEpochMillis > 0 ? latestHandshakeEpochMillis : nil,
      rxBytes: rxBytes,
      txBytes: txBytes
    )
  }

  private static func nonNegativeInteger(_ value: String) -> Int64? {
    guard let parsed = Int64(value), parsed >= 0 else {
      return nil
    }
    return parsed
  }

  private static func updateLatestHandshake(
    seconds: Int64?,
    nanoseconds: Int64,
    latestMilliseconds: inout Int64
  ) {
    guard let seconds, seconds > 0 else {
      return
    }
    let (secondsMilliseconds, multiplicationOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
    guard !multiplicationOverflow else {
      latestMilliseconds = Int64.max
      return
    }
    let boundedNanoseconds = min(max(nanoseconds, 0), 999_999_999)
    let (milliseconds, additionOverflow) = secondsMilliseconds.addingReportingOverflow(boundedNanoseconds / 1_000_000)
    latestMilliseconds = max(latestMilliseconds, additionOverflow ? Int64.max : milliseconds)
  }

  private static func addSaturating(_ value: Int64?, to total: inout Int64) {
    guard let value else {
      return
    }
    let (sum, overflow) = total.addingReportingOverflow(value)
    total = overflow ? Int64.max : sum
  }
}
