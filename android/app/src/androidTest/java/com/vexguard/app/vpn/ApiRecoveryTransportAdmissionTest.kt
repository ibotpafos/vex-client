package com.vexguard.app.vpn

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.network.OkHttpClientFactory
import com.facebook.react.modules.network.OkHttpClientProvider
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Test

/** Actual production admission, both routing classes; no accepted request is dispatched. */
class ApiRecoveryTransportAdmissionTest {
  private fun rejected(url: String, method: String, deadline: Double) {
    // Suppressed MainApplication leaves the provider unused. Preserve both fields
    // anyway; a throwing factory makes a regressed admission fail before I/O.
    val clientField = OkHttpClientProvider::class.java.getDeclaredField("client").apply { isAccessible = true }
    val factoryField = OkHttpClientProvider::class.java.getDeclaredField("factory").apply { isAccessible = true }
    val previousClient = clientField.get(null)
    val previousFactory = factoryField.get(null)
    var clientAcquisitions = 0
    try {
      clientField.set(null, null)
      OkHttpClientProvider.setOkHttpClientFactory(OkHttpClientFactory {
        clientAcquisitions++
        throw IllegalStateException("TEST_DISPATCH_FORBIDDEN")
      })
      for (mutation in listOf(false, true)) {
        var rejected = 0
        var resolved = 0
        var headerReads = 0
        val headers = Proxy.newProxyInstance(ReadableMap::class.java.classLoader, arrayOf(ReadableMap::class.java)) { _, _, _ ->
          headerReads++
          throw IllegalStateException("ADMISSION_MUST_PRECEDE_HEADERS")
        } as ReadableMap
        val promise = Proxy.newProxyInstance(Promise::class.java.classLoader, arrayOf(Promise::class.java)) { _, method, args ->
          when (method.name) {
            "reject" -> {
              rejected++
              assertEquals(if (mutation) "API_MUTATION_FAILED" else "API_RECOVERY_FAILED", args!![0])
            }
            "resolve" -> resolved++
            else -> throw AssertionError("Unexpected promise call")
          }
          null
        } as Promise
        val transport = ApiRecoveryTransport(mutationsOnly = mutation)
        try {
          transport.request("api-1793930000000-1", url, method, headers, null, deadline, promise)
          assertEquals("synchronous rejection", 1, rejected)
          assertEquals(0, resolved)
          assertEquals("rejected before headers", 0, headerReads)
          assertEquals("zero client acquisitions => zero dispatch", 0, clientAcquisitions)
        } finally { transport.close() }
      }
    } finally {
      clientField.set(null, previousClient)
      factoryField.set(null, previousFactory)
    }
  }

  @Test fun foreignUrlRejectedBeforeDispatch() =
    rejected("https://foreign.invalid/v1/fixture", "POST", System.currentTimeMillis() + 60_000.0)

  @Test fun forbiddenMethodRejectedBeforeDispatch() =
    rejected("https://api.vexguard.app/v1/fixture", "TRACE", System.currentTimeMillis() + 60_000.0)

  @Test fun expiredDeadlineRejectedBeforeDispatch() =
    rejected("https://api.vexguard.app/v1/fixture", "POST", 0.0)
}
