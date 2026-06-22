package com.vexguard.app.vpn

import kotlinx.coroutines.flow.MutableStateFlow
import org.amnezia.awg.backend.Tunnel

class VexTunnel : Tunnel {
  val state = MutableStateFlow(Tunnel.State.DOWN)

  override fun getName(): String = "vex"

  override fun onStateChange(newState: Tunnel.State) {
    state.value = newState
  }
}
