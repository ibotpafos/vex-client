package com.vexguard.app.vpn

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class VlessIntentJournalTest {
  private fun fixture(test: (File, VlessIntentJournal) -> Unit) {
    val folder = Files.createTempDirectory("vex-vless-intent-").toFile()
    try { test(folder, VlessIntentJournal(folder)) } finally { folder.deleteRecursively() }
  }

  private fun VlessIntentJournal.manual(hold: Boolean = true): String {
    authorizeManual()
    return begin(ticket(), hold)
  }

  private fun rejected(action: () -> Unit) {
    try { action(); fail("An unauthorized recovery was admitted") } catch (_: IllegalStateException) { }
  }

  @Test fun externalRevocationIsDurableAndCannotRearmCaptureOrConnection() = fixture { folder, main ->
    val attempt = main.manual()
    val worker = VlessIntentJournal(folder)
    assertTrue(worker.revoke(attempt))
    val restartedMain = VlessIntentJournal(folder)
    assertFalse(restartedMain.snapshot().wanted)
    assertFalse(restartedMain.snapshot().hold)
    assertTrue(restartedMain.snapshot().revoked)
    assertFalse(restartedMain.prepareRecoveryCapture())
    rejected { restartedMain.begin(restartedMain.ticket(), true) }
    restartedMain.stop(true)
    assertFalse(restartedMain.snapshot().hold)
    rejected { restartedMain.begin(restartedMain.ticket(), true) }
  }

  @Test fun unexpectedWorkerDeathKeepsIntentAndPermitsRecoveryWithoutNewPermission() = fixture { folder, main ->
    val lost = main.manual(false)
    val restartedMain = VlessIntentJournal(folder)
    assertTrue(restartedMain.snapshot().wanted)
    assertFalse(restartedMain.snapshot().revoked)
    val recovered = restartedMain.begin(restartedMain.ticket(), false)
    assertNotEquals(lost, recovered)
    assertTrue(restartedMain.isCurrent(recovered))
  }

  @Test fun alreadyInFlightRecoveryCannotOverwriteRevocationOrLaterManualAuthorization() = fixture { _, journal ->
    val attempt = journal.manual()
    val inFlight = journal.ticket()
    journal.revoke(attempt)
    rejected { journal.begin(inFlight, true) }
    journal.authorizeManual()
    rejected { journal.begin(inFlight, true) }
    val manual = journal.begin(journal.ticket(), true)
    assertTrue(journal.isCurrent(manual))
  }

  @Test fun staleOldRevocationCannotRevokeTheNewAttempt() = fixture { folder, main ->
    val old = main.manual()
    val worker = VlessIntentJournal(folder)
    val next = main.begin(main.ticket(), true)
    assertFalse(worker.revoke(old))
    assertTrue(main.isCurrent(next))
    assertTrue(main.snapshot().wanted)
  }

  @Test fun internalEngineHandoverRetiresTheWorkerBeforeItsRevokeCallback() = fixture { folder, main ->
    val attempt = main.manual()
    val worker = VlessIntentJournal(folder)
    main.stop(true)
    assertFalse(worker.revoke(attempt))
    assertFalse(main.snapshot().wanted)
    assertTrue(main.snapshot().hold)
    assertFalse(main.snapshot().revoked)
    rejected { main.begin(main.ticket(), true) }
    main.manual()
    assertTrue(main.snapshot().wanted)
  }

  @Test fun intentionalBlockerHandoverPreservesRecoveryButIgnoresOldWorkerRevoke() = fixture { folder, main ->
    val attempt = main.manual()
    val worker = VlessIntentJournal(folder)
    assertTrue(main.prepareRecoveryCapture())
    assertFalse(worker.revoke(attempt))
    val replacement = main.begin(main.ticket(), true)
    assertTrue(main.isCurrent(replacement))
  }

  @Test fun corruptStorageCannotAuthorizeAutomaticRecovery() = fixture { folder, journal ->
    journal.manual()
    File(folder, "vless-intent.json").writeText("invalid")
    assertTrue(journal.snapshot().revoked)
    rejected { journal.begin(journal.ticket(), true) }
    journal.authorizeManual()
    assertTrue(journal.isCurrent(journal.begin(journal.ticket(), false)))
  }
}
