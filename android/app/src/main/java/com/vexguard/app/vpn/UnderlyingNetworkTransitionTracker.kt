package com.vexguard.app.vpn

internal class UnderlyingNetworkTransitionTracker<T> {
  private var lastUsable: T? = null

  fun update(selected: T?): Pair<T, T>? {
    if (selected == null) {
      return null
    }
    val previous = lastUsable
    lastUsable = selected
    return if (previous != null && previous != selected) previous to selected else null
  }
}
