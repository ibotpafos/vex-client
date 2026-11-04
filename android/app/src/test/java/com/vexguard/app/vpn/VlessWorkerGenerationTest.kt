package com.vexguard.app.vpn

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class VlessWorkerGenerationTest {
  @Test fun delayedOldSystemCallbackCannotReadTheSuccessorAttempt() {
    val folder = Files.createTempDirectory("vex-worker-generation-").toFile()
    try {
      val journal = VlessIntentJournal(folder)
      journal.authorizeManual()
      val first = journal.begin(journal.ticket(), true)
      val oldAdapter = VlessWorkerGeneration()
      oldAdapter.claim(first)
      val delayedSystemCallback = { oldAdapter.revoke { journal.revoke(it) } }
      journal.authorizeManual()
      val successor = journal.begin(journal.ticket(), true)
      val newAdapter = VlessWorkerGeneration()
      newAdapter.claim(successor)
      assertFalse(delayedSystemCallback())
      assertEquals(first, oldAdapter.attempt())
      assertEquals(successor, newAdapter.attempt())
      assertTrue(journal.isCurrent(successor))
    } finally { folder.deleteRecursively() }
  }

  @Test fun workerCannotBeReusedForAnotherConnectEvenBeforeDelayedRevokeArrives() {
    val worker = VlessWorkerGeneration()
    worker.claim("first")
    try { worker.claim("successor"); fail("An Android binding was reused") } catch (_: IllegalStateException) { }
    assertEquals("first", worker.attempt())
  }

  @Test fun systemRevokeBeforeConnectRetiresAnUnclaimedWorker() {
    val worker = VlessWorkerGeneration()
    assertFalse(worker.revoke { false })
    try { worker.claim("late-connect"); fail("A revoked binding accepted CONNECT") } catch (_: IllegalStateException) { }
  }

  @Test fun delayedServiceConnectionCallbacksBelongOnlyToTheirOriginalBind() {
    val callbacks = VlessCallbackFence()
    val oldBind = callbacks.advance()
    val delayedDisconnect = { callbacks.isCurrent(oldBind) }
    callbacks.advance() // expected unbind/process retirement
    val successorBind = callbacks.advance()
    assertFalse(delayedDisconnect())
    assertTrue(callbacks.isCurrent(successorBind))
  }
}
