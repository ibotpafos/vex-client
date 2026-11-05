package com.vexguard.app.vpn

/** Bounded connection timers independent of React Native's paused UI frames. */
internal class VpnVerificationTimers(
  private val post: (Runnable, Long) -> Boolean,
  private val remove: (Runnable) -> Unit,
) {
  private data class Entry(val token: Any, val task: Runnable, val complete: (Boolean) -> Unit)
  private val pending = mutableMapOf<String, Entry>()

  @Synchronized
  /** Register one bounded timer; false leaves promise rejection to the caller. */
  fun schedule(id: String, delayMs: Double, complete: (Boolean) -> Unit): Boolean {
    if (!id.matches(Regex("verify-[1-9][0-9]{0,14}")) || !delayMs.isFinite() ||
      delayMs < 0 || delayMs > 60_000 || pending.size >= 128 || pending.containsKey(id)) return false
    val token = Any()
    val task = Runnable { finish(id, token) }
    pending[id] = Entry(token, task, complete)
    return try {
      if (post(task, delayMs.toLong())) true else { pending.remove(id); false }
    } catch (_: RuntimeException) {
      pending.remove(id)
      false
    }
  }

  /** Ignore callbacks retained by the queue after cancellation or ID reuse. */
  private fun finish(id: String, token: Any) {
    val entry = synchronized(this) {
      pending[id]?.takeIf { it.token === token }?.also { pending.remove(id) }
    }
    entry?.complete?.invoke(true)
  }

  /** Remove a timer and release its promise without publishing expiry. */
  fun cancel(id: String) {
    val entry = synchronized(this) { pending.remove(id) } ?: return
    remove(entry.task)
    entry.complete(false)
  }

  /** Release all pending callbacks when the React Native module is invalidated. */
  fun clear() {
    val entries = synchronized(this) { pending.values.toList().also { pending.clear() } }
    for (entry in entries) {
      remove(entry.task)
      entry.complete(false)
    }
  }
}
