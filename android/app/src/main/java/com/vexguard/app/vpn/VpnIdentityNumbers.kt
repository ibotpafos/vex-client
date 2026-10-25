package com.vexguard.app.vpn

object VpnIdentityNumbers {
  const val maximumJavaScriptInteger = 9_007_199_254_740_991L

  fun profileVersion(value: String?): Long? {
    val normalized = value?.trim().orEmpty()
    if (normalized.isEmpty() || normalized.any { it !in '0'..'9' }) return null
    return normalized.toLongOrNull()?.takeIf { it in 1..maximumJavaScriptInteger }
  }

  // Keep the legacy Int preference format; account-scoped JSON keys have
  // separate safe-integer validation. Reject before touching native key data.
  fun legacyKeyEpoch(value: Double): Int {
    require(value.isFinite() && value >= 1 && value <= Int.MAX_VALUE && value % 1.0 == 0.0) {
      "WireGuard key epoch is outside the legacy native range."
    }
    return value.toInt()
  }

  fun nextLegacyKeyEpoch(current: Int): Int {
    require(current in 1 until Int.MAX_VALUE) { "WireGuard key epoch cannot be incremented safely." }
    return current + 1
  }
}

internal class WireGuardKeyPairGenerator<T>(
  private val currentLegacyEpoch: () -> Int,
  private val generateMaterial: (Int) -> T,
) {
  fun nextLegacy(): T = generateMaterial(VpnIdentityNumbers.nextLegacyKeyEpoch(currentLegacyEpoch()))
  fun forAccount(): T = generateMaterial(1)
}
