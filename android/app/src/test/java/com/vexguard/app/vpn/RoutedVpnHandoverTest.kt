package com.vexguard.app.vpn

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RoutedVpnHandoverTest {
  @Test fun establishedCaptureRetiresObsoleteBlocker() = runBlocking {
    val events = mutableListOf<String>()
    completeRoutedVpnHandover(
      { events.add("capture_owned"); true },
      { events.add("blocker_retired"); true },
    )
    assertEquals(listOf("capture_owned", "blocker_retired"), events)
  }

  @Test fun missingReplacementNeverReleasesBlocker() = runBlocking {
    var stopped = false
    try {
      completeRoutedVpnHandover({ false }, { stopped = true; true })
      fail("Missing capture must enter activation failure recovery")
    } catch (_: IllegalStateException) { }
    assertFalse(stopped)
  }

  @Test fun stopTimeoutFailsActivationInsteadOfReportingConnected() = runBlocking {
    try {
      completeRoutedVpnHandover({ true }, { false })
      fail("Unconfirmed blocker retirement must fail activation")
    } catch (_: IllegalStateException) { }
  }

  @Test fun cancellationReachesActivationRecovery() = runBlocking {
    val cancellation = kotlinx.coroutines.CancellationException("superseded")
    try {
      completeRoutedVpnHandover({ true }, { throw cancellation })
      fail("Cancelled handover must not report connected")
    } catch (error: kotlinx.coroutines.CancellationException) {
      assertSame(cancellation, error)
    }
  }
}
