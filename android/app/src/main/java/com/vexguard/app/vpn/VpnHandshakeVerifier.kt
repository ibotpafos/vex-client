package com.vexguard.app.vpn

internal object VpnHandshakeVerifier {
  fun isVerified(latestHandshakeEpochMillis: Long): Boolean = latestHandshakeEpochMillis > 0L

  fun latestHandshakeEpochMillis(peerTimestampMillis: Long, backendTimestampSeconds: Long): Long {
    val backendTimestampMillis = if (backendTimestampSeconds > 0L) backendTimestampSeconds * 1_000L else 0L
    return maxOf(peerTimestampMillis, backendTimestampMillis)
  }
}
