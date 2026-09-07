package com.vexguard.app.vpn

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class VpnStatusPollingTest {
  @Test fun cancellationDuringDelayIsNotAnError() = runBlocking {
    var warnings = 0
    val polled = CompletableDeferred<Unit>()
    val job = launch {
      pollVpnStatus({ true }, { polled.complete(Unit); 60_000L }, { warnings++ }, 1L)
    }
    polled.await()
    job.cancelAndJoin()
    assertEquals(0, warnings)
  }

  @Test fun cancellationDuringReadIsNotAnError() = runBlocking {
    var warnings = 0
    val entered = CompletableDeferred<Unit>()
    val job = launch {
      pollVpnStatus({ true }, { entered.complete(Unit); awaitCancellation() }, { warnings++ }, 1L)
    }
    entered.await()
    job.cancelAndJoin()
    assertEquals(0, warnings)
  }

  @Test fun transientErrorRetriesAndReportsOnce() = runBlocking {
    var calls = 0
    var warnings = 0
    pollVpnStatus({ calls < 2 }, {
      calls++
      if (calls == 1) error("read failed")
      0L
    }, { warnings++ }, 1L)
    assertEquals(2, calls)
    assertEquals(1, warnings)
  }

  @Test fun noListenersDoesNotPoll() = runBlocking {
    var calls = 0
    pollVpnStatus({ false }, { calls++; 0L }, { fail("unexpected warning") }, 1L)
    assertEquals(0, calls)
  }
}
