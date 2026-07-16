package com.vexguard.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IcmpEchoProbeTest {
  @Test
  fun buildsValidEchoRequestChecksum() {
    val packet = buildIcmpEchoRequest(0x1234)

    assertEquals(8, packet[0].toInt())
    assertEquals(0x12, packet[6].toInt() and 0xff)
    assertEquals(0x34, packet[7].toInt() and 0xff)
    assertEquals(0, internetChecksum(packet))
  }

  @Test
  fun matchesEchoReplyWithSameSequence() {
    val reply = buildIcmpEchoRequest(0x4321)
    reply[0] = 0

    assertTrue(isMatchingIcmpEchoReply(reply, reply.size, 0x4321))
    assertFalse(isMatchingIcmpEchoReply(reply, reply.size, 0x4322))
  }

  @Test
  fun matchesReplyWithIpv4Header() {
    val reply = ByteArray(20) + buildIcmpEchoRequest(7)
    reply[0] = 0x45
    reply[20] = 0

    assertTrue(isMatchingIcmpEchoReply(reply, reply.size, 7))
  }
}
