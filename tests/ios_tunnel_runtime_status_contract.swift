import Foundation

@main
struct IosTunnelRuntimeStatusContract {
  static func main() {
    let runtimeConfiguration = """
    private_key=must-not-be-retained
    public_key=peer-one
    last_handshake_time_sec=1700000000
    last_handshake_time_nsec=250000000
    tx_bytes=7
    rx_bytes=11
    public_key=peer-two
    last_handshake_time_sec=1700000001
    last_handshake_time_nsec=500000000
    tx_bytes=13
    rx_bytes=17
    """

    let status = IosTunnelRuntimeStatus.parse(runtimeConfiguration)
    precondition(status.rxBytes == 28)
    precondition(status.txBytes == 20)
    precondition(status.latestHandshakeEpochMillis == 1_700_000_001_500)
    precondition(status.isVerified)

    let pending = IosTunnelRuntimeStatus.parse("rx_bytes=0\ntx_bytes=0\n")
    precondition(pending.rxBytes == 0)
    precondition(pending.txBytes == 0)
    precondition(pending.latestHandshakeEpochMillis == nil)
    precondition(!pending.isVerified)

    print("PASS iOS tunnel runtime status parser")
  }
}
