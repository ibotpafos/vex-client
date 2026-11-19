package com.vexguard.app.vpn

internal suspend fun completeRoutedVpnHandover(
  hasRoutingCapture: () -> Boolean,
  stopBlocker: suspend () -> Boolean,
) {
  check(hasRoutingCapture()) { "Routed VPN capture is unavailable during protection handover." }
  check(stopBlocker()) { "Anti-leak service did not stop after routed VPN capture was established." }
}
