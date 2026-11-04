package com.vexguard.app.vpn

import java.util.UUID

/** No Android/core dependency: stale network/core work can never verify a successor. */
internal class VlessVerificationState(
  private val now: () -> Long = System::currentTimeMillis,
  private val newId: () -> String = { UUID.randomUUID().toString() },
) {
  data class Lease(val connectionId: String, val revision: Long)
  data class Snapshot(
    val state: String,
    val connectionId: String,
    val verified: Boolean,
    val verificationEpochMillis: Long,
    val verificationReason: String?,
    val leakProtection: String,
    val latencyMs: Long?,
  )

  private var connectionId = ""
  private var revision = 0L
  private var wanted = false
  private var captureHeld = false
  private var coreReady = false
  private var antiLeak = false
  private var epoch = 0L
  private var reason = "probe_pending"
  private var latency: Long? = null

  @Synchronized fun begin(antiLeakEnabled: Boolean): Lease {
    connectionId = newId()
    wanted = true
    coreReady = false
    antiLeak = antiLeakEnabled
    epoch = 0
    latency = null
    reason = "probe_pending"
    revision++
    return lease()
  }

  @Synchronized fun setCapture(held: Boolean) {
    captureHeld = held
    if (!held) {
      epoch = 0
      latency = null
      revision++
    }
  }

  @Synchronized fun setCoreReady(ready: Boolean) {
    coreReady = ready
    if (!ready) {
      epoch = 0
      latency = null
      revision++
    }
  }

  @Synchronized fun invalidate(why: String): Lease {
    require(why in setOf("probe_pending", "data_plane_failed", "network_unavailable"))
    epoch = 0
    latency = null
    reason = why
    revision++
    return lease()
  }

  @Synchronized fun lease() = Lease(connectionId, revision)

  @Synchronized fun isCurrent(value: Lease) = wanted && value == lease()

  @Synchronized fun confirm(value: Lease, latencyMs: Long? = null): Boolean {
    if (!isCurrent(value) || !captureHeld || !coreReady) return false
    epoch = now()
    latency = latencyMs?.takeIf { it >= 0 }
    return true
  }

  @Synchronized fun fail(value: Lease, why: String = "data_plane_failed") {
    if (!isCurrent(value)) return
    epoch = 0
    latency = null
    reason = why
  }

  @Synchronized fun stop(retainCapture: Boolean) {
    wanted = false
    coreReady = false
    epoch = 0
    latency = null
    captureHeld = retainCapture && captureHeld
    revision++
  }

  @Synchronized fun snapshot(): Snapshot {
    val fresh = wanted && captureHeld && coreReady && epoch > 0 && now() >= epoch && now() - epoch <= 30_000
    return Snapshot(
      state = when { !wanted && !captureHeld -> "disconnected"; fresh -> "connected"; captureHeld && (!wanted || reason != "probe_pending") -> "error"; else -> "verifying" },
      connectionId = connectionId,
      verified = fresh,
      verificationEpochMillis = if (fresh) epoch else 0,
      verificationReason = if (fresh || !wanted && !captureHeld) null else if (epoch > 0) "probe_pending" else reason,
      leakProtection = when { captureHeld && !coreReady -> "blocking"; captureHeld && antiLeak -> "armed"; else -> "off" },
      latencyMs = if (fresh) latency else null,
    )
  }
}
