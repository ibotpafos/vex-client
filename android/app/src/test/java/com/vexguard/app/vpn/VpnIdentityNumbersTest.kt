package com.vexguard.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class VpnIdentityNumbersTest {
  @Test
  fun pushVersionsRetainWholeDecimalStringsBeyondInt32WithoutRounding() {
    for (value in listOf(1L, 7L, Int.MAX_VALUE.toLong(), Int.MAX_VALUE.toLong() + 1, VpnIdentityNumbers.maximumJavaScriptInteger)) {
      assertEquals(value, VpnIdentityNumbers.profileVersion(value.toString()))
    }
    assertEquals(7L, VpnIdentityNumbers.profileVersion(" 007 "))
  }

  @Test
  fun malformedPushVersionsDoNotAliasAValidStage() {
    for (value in listOf(null, "", "0", "-1", "+7", "7.5", "7e3", "7junk", "9007199254740992", "99999999999999999999999")) {
      assertNull(VpnIdentityNumbers.profileVersion(value))
    }
  }

  @Test
  fun legacyKeyBridgeKeepsItsExactExistingPositiveIntRange() {
    for (value in listOf(1, 7, Int.MAX_VALUE)) assertEquals(value, VpnIdentityNumbers.legacyKeyEpoch(value.toDouble()))
  }

  @Test
  fun invalidLegacyBridgeValuesAreRejectedBeforeConversion() {
    for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0, 0.0, 1.5, Int.MAX_VALUE.toDouble() + 1, VpnIdentityNumbers.maximumJavaScriptInteger.toDouble())) {
      rejects { VpnIdentityNumbers.legacyKeyEpoch(value) }
    }
  }

  @Test
  fun keyGenerationCannotOverflowIntoAnEarlierEpoch() {
    assertEquals(2, VpnIdentityNumbers.nextLegacyKeyEpoch(1))
    assertEquals(Int.MAX_VALUE, VpnIdentityNumbers.nextLegacyKeyEpoch(Int.MAX_VALUE - 1))
    for (value in listOf(-1, 0, Int.MAX_VALUE)) rejects { VpnIdentityNumbers.nextLegacyKeyEpoch(value) }
  }

  @Test
  fun accountGenerationDoesNotReadOrAdvanceAnExhaustedLegacyCounter() {
    var reads = 0
    val generated = mutableListOf<Int>()
    val generator = WireGuardKeyPairGenerator({ reads++; Int.MAX_VALUE }, { epoch -> generated.add(epoch); epoch })
    rejects { generator.nextLegacy() }
    assertEquals(1, reads)
    assertEquals(emptyList<Int>(), generated)
    assertEquals(1, generator.forAccount())
    assertEquals(1, reads)
    assertEquals(listOf(1), generated)
  }

  private fun rejects(run: () -> Unit) {
    try { run(); fail("Unrepresentable identity was accepted") } catch (_: IllegalArgumentException) { }
  }
}
