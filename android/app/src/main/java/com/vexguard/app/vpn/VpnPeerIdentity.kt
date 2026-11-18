package com.vexguard.app.vpn

import java.security.MessageDigest

/** Compare live UAPI keys, never a timestamp or the last requested DTO. */
internal fun vpnPeerKeysMatch(expected: List<String>, active: List<String>): Boolean =
  expected.isNotEmpty() && expected.size == expected.toSet().size &&
    active.size == expected.size && active.toSet() == expected.toSet()

internal fun vpnIdentityFingerprint(value: String): String =
  MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }
