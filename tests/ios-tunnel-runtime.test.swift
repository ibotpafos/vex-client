import Foundation

@main
enum IosTunnelRuntimeTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() { fatalError("iOS runtime regression: \(name)") }
  }

  static func peer(rx: String = "10", tx: String = "20", seconds: String = "1700000000", nanos: String = "123000000") -> String {
    "public_key=synthetic\nrx_bytes=\(rx)\ntx_bytes=\(tx)\nlast_handshake_time_sec=\(seconds)\nlast_handshake_time_nsec=\(nanos)\n"
  }

  static func parse(_ text: String) -> IosTunnelRuntimeStats? {
    IosTunnelRuntimeStats.parse(text.data(using: .utf8))
  }

  static func main() async {
    let runtime = parse("private_key=never-export-this\n" + peer() + "errno=0\n")
    expect(runtime?.rxBytes == 10 && runtime?.txBytes == 20, "actual counters")
    expect(runtime?.latestHandshakeEpochMillis == 1_700_000_000_123, "seconds and nanoseconds")
    let aggregate = parse(peer() + peer(rx: "30", tx: "40", seconds: "1700000001"))
    expect(aggregate?.rxBytes == 40 && aggregate?.txBytes == 60, "multiple peers")
    expect(aggregate?.latestHandshakeEpochMillis == 1_700_000_001_123, "latest peer handshake")
    expect(parse(peer(seconds: "0", nanos: "500000000"))?.latestHandshakeEpochMillis == 0, "pending handshake")
    expect(parse(peer().replacingOccurrences(of: "last_handshake_time_nsec=123000000\n", with: "")) != nil, "second resolution")
    for bad in [
      "", "private_key=never-export-this\n", peer(rx: "-1"), peer(tx: "NaN"),
      peer(seconds: "18446744073709551615"), peer(nanos: "1000000000"),
      peer() + "rx_bytes=1\n", peer() + "errno=5\n", peer() + "truncated-line",
      peer().replacingOccurrences(of: "tx_bytes=20\n", with: ""),
      peer(rx: "9007199254740991") + peer(rx: "1"),
      String(repeating: "x", count: 128 * 1024 + 1),
    ] { expect(parse(bad) == nil, "malformed or incomplete runtime stays unknown") }
    expect(IosTunnelRuntimeStats.parse(Data([0xff])) == nil, "invalid UTF-8")

    let valid = peer().data(using: .utf8)!
    let immediate = await IosTunnelRuntimeReader.read { request, reply in
      expect(request == Data([0]), "existing extension IPC contract")
      reply(valid)
      reply(nil)
    }
    expect(immediate?.rxBytes == 10, "duplicate callbacks resume once")
    let missing = await IosTunnelRuntimeReader.read { _, reply in reply(nil) }
    expect(missing == nil, "missing extension response")
    enum QueryFailure: Error { case unavailable }
    let failed = await IosTunnelRuntimeReader.read { _, _ in throw QueryFailure.unavailable }
    expect(failed == nil, "IPC error stays unknown")
    var lateReply: ((Data?) -> Void)?
    let expired = await IosTunnelRuntimeReader.read(timeoutSeconds: 0.02) { _, reply in lateReply = reply }
    expect(expired == nil, "missing callback has a bounded timeout")
    lateReply?(valid)
    print("IOS_TUNNEL_RUNTIME=PASS (parser, privacy, IPC, timeout, late/duplicate reply)")
  }
}
