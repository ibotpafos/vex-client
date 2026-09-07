package com.vexguard.app.vpn

import java.io.ByteArrayInputStream
import java.math.BigInteger
import java.nio.charset.StandardCharsets
import org.amnezia.awg.config.Config

internal class AwgConfigValidationException(message: String, cause: Throwable? = null) : IllegalArgumentException(message, cause)

internal object AwgConfigSafety {
  private val rangeFields = setOf(
    "contentpaddingaddition",
    "rekeyaftertime",
    "rekeytimeout",
    "rejectaftertime",
    "keepalivetimeout",
    "maxhandshakeattempts",
  )
  private val booleanFields = setOf("randomtrailers", "disablecookies")
  private val booleanTokens = setOf("on", "off", "1", "0", "true", "false", "t", "f", "yes", "no")
  private val uint32Max = BigInteger("4294967295")
  private val integerOrRange = Regex("^(\\d+)(?:-(\\d+))?$")

  fun parseForActivation(configText: String): Config = try {
    validateRangeFields(configText)
    Config.parse(ByteArrayInputStream(configText.toByteArray(StandardCharsets.UTF_8)))
  } catch (error: AwgConfigValidationException) {
    throw error
  } catch (error: Exception) {
    throw AwgConfigValidationException(error.message ?: "Invalid AWG configuration.", error)
  }

  private fun validateRangeFields(configText: String) {
    var inInterface = false
    configText.lineSequence().forEach { rawLine ->
      val line = rawLine.substringBefore('#').trim()
      when {
        line.equals("[Interface]", ignoreCase = true) -> inInterface = true
        line.startsWith("[") -> inInterface = false
        !inInterface || line.isEmpty() -> Unit
        else -> {
          val separator = line.indexOf('=')
          if (separator <= 0) return@forEach
          val name = line.substring(0, separator).trim()
          val value = line.substring(separator + 1).trim()
          if (name.lowercase() in booleanFields) {
            if (value.lowercase() !in booleanTokens) throw AwgConfigValidationException("Invalid $name; expected a boolean token.")
            return@forEach
          }
          if (name.lowercase() !in rangeFields) return@forEach
          val match = integerOrRange.matchEntire(value)
            ?: throw AwgConfigValidationException("Invalid $name; expected a non-negative integer or ascending integer range.")
          val lower = BigInteger(match.groupValues[1])
          val upperText = match.groupValues[2]
          val upper = if (upperText.isEmpty()) null else BigInteger(upperText)
          if (lower > uint32Max || (upper != null && (upper > uint32Max || upper < lower))) {
            throw AwgConfigValidationException("Invalid $name; expected a non-negative ascending integer range.")
          }
        }
      }
    }
  }
}
