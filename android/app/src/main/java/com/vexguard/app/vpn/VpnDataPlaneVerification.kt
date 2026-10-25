package com.vexguard.app.vpn

/** In-memory proof belongs to one admitted peer and one physical network. */
internal class VpnDataPlaneVerification {
  data class Attempt(val peer: String, val network: Long, val sequence: Long)
  data class Status(val verified: Boolean, val reason: String?)
  private var peer = ""
  private var network = 0L
  private var sequence = 0L
  private var pending: Attempt? = null
  private var expiresAt = 0L
  private var refreshAt = 0L
  private var retryAt = 0L
  private var reason = "data_plane_pending"

  @Synchronized fun clear() {
    peer = ""; network = 0L; pending = null
    expiresAt = 0L; refreshAt = 0L; retryAt = 0L
    reason = "data_plane_pending"
  }

  @Synchronized fun status(peer: String, network: Long, now: Long): Status {
    select(peer, network)
    val verified = peer.isNotEmpty() && now < expiresAt
    return Status(verified, if (verified) null else reason)
  }

  @Synchronized fun begin(peer: String, network: Long, now: Long): Attempt? {
    select(peer, network)
    if (peer.isEmpty() || pending != null || now < retryAt || now < refreshAt) return null
    return Attempt(peer, network, ++sequence).also { pending = it }
  }

  @Synchronized fun complete(attempt: Attempt, result: Int, now: Long): Boolean {
    if (pending != attempt || peer != attempt.peer || network != attempt.network) return false
    pending = null
    retryAt = now + 3_000L
    if (result == 0) {
      expiresAt = now + 60_000L
      refreshAt = now + 45_000L
      reason = "data_plane_pending"
    } else {
      expiresAt = 0L; refreshAt = 0L
      reason = when (result) {
        1 -> "dns_failed"
        2 -> "https_failed"
        else -> "data_plane_unavailable"
      }
    }
    return true
  }

  private fun select(selectedPeer: String, selectedNetwork: Long) {
    if (peer == selectedPeer && network == selectedNetwork) return
    clear()
    peer = selectedPeer; network = selectedNetwork
  }
}
