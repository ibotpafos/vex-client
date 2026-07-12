package com.vexguard.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UnderlyingNetworkTransitionTrackerTest {
  @Test
  fun initialNetworkDoesNotTriggerRecovery() {
    val tracker = UnderlyingNetworkTransitionTracker<String>()

    assertNull(tracker.update("wifi"))
  }

  @Test
  fun nullBridgeStillDetectsWifiToCellularHandover() {
    val tracker = UnderlyingNetworkTransitionTracker<String>()
    tracker.update("wifi")

    assertNull(tracker.update(null))
    assertEquals("wifi" to "cellular", tracker.update("cellular"))
  }

  @Test
  fun duplicateNetworkDoesNotTriggerRecovery() {
    val tracker = UnderlyingNetworkTransitionTracker<String>()
    tracker.update("wifi")

    assertNull(tracker.update("wifi"))
  }

  @Test
  fun reverseHandoverIsDetected() {
    val tracker = UnderlyingNetworkTransitionTracker<String>()
    tracker.update("wifi")
    tracker.update(null)
    tracker.update("cellular")

    assertEquals("cellular" to "wifi-2", tracker.update("wifi-2"))
  }
}
