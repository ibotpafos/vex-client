package com.vexguard.app.vpn

/** One Android system binding/process may own exactly one CONNECT generation. */
internal class VlessWorkerGeneration {
  private var owner = ""
  private var retired = false
  @Synchronized fun claim(attempt: String) {
    check(!retired && owner.isEmpty() && attempt.isNotEmpty()) { "VLESS requires a fresh worker." }
    owner = attempt
  }
  @Synchronized fun attempt() = owner
  @Synchronized fun revoke(action: (String) -> Boolean): Boolean {
    retired = true
    return action(owner)
  }
}

/** ServiceConnection callbacks belong to the bind operation that created them. */
internal class VlessCallbackFence {
  private var generation = 0L
  @Synchronized fun advance(): Long = ++generation
  @Synchronized fun isCurrent(value: Long) = value == generation
}
