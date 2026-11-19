package com.vexguard.app.vpn

import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VlessStatusAuthorityTest {
  private fun oldConnected(protection: String) = JSONObject().put("state", "connected")
    .put("verified", true).put("connectionWanted", true).put("verificationEpochMillis", 1234)
    .put("latencyMs", 20).put("leakProtection", protection)

  @Test fun oldConnectedReplyAfterRetainedStopCannotRestoreTheConnectedIndicator() {
    val folder = Files.createTempDirectory("vex-withdrawn-status-").toFile()
    try {
      val journal = VlessIntentJournal(folder)
      journal.authorizeManual()
      journal.begin(journal.ticket(), true)
      val delayedReply = oldConnected("armed")
      journal.stop(true)
      val intent = journal.snapshot()
      assertFalse(intent.wanted)
      val actual = VlessStatusAuthority.withdrawn(delayedReply, intent.hold)
      assertEquals("error", actual.getString("state"))
      assertFalse(actual.getBoolean("verified"))
      assertFalse(actual.getBoolean("connectionWanted"))
      assertFalse(actual.has("verificationEpochMillis"))
      assertFalse(actual.has("latencyMs"))
      assertEquals("armed", actual.getString("leakProtection"))
    } finally { folder.deleteRecursively() }
  }

  @Test fun retainedBlockIsAnErrorAndReleasedOrMissingCaptureIsDisconnected() {
    assertEquals("error", VlessStatusAuthority.withdrawn(oldConnected("blocking"), true).getString("state"))
    for ((hold, protection) in listOf(false to "armed", false to "blocking", true to "off")) {
      val actual = VlessStatusAuthority.withdrawn(oldConnected(protection), hold)
      assertEquals("disconnected", actual.getString("state"))
      assertEquals("off", actual.getString("leakProtection"))
      assertFalse(actual.getBoolean("verified"))
    }
  }
}
