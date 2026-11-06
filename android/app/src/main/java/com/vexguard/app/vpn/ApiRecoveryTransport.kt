package com.vexguard.app.vpn

import android.net.Network
import android.util.Log
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.modules.network.OkHttpClientProvider
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionPool
import okhttp3.Dns
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/** First-party profile recovery only; never changes process or VPN routing. */
internal class ApiRecoveryTransport(private val selectNetwork: () -> Network?) {
  private class Pending {
    val cancelled = AtomicBoolean(false)
    @Volatile var call: Call? = null
    fun cancel() { cancelled.set(true); call?.cancel() }
  }

  private val closed = AtomicBoolean(false)
  private val pending = ConcurrentHashMap<String, Pending>()

  fun cancel(id: String) { pending[id]?.cancel() }

  fun close() {
    closed.set(true)
    pending.values.forEach { it.cancel() }
  }

  fun request(id: String, url: String, method: String, headers: ReadableMap,
              body: String?, deadlineEpochMillis: Double, promise: Promise) {
    val slot = Pending()
    var pool: ConnectionPool? = null
    try {
      require(ApiRecoveryPolicy.acceptsRequestId(id) && ApiRecoveryPolicy.acceptsUrl(url))
      require(deadlineEpochMillis.isFinite())
      require(deadlineEpochMillis - System.currentTimeMillis() in 1.0..120_000.0)
      val verb = method.uppercase(Locale.US)
      require(verb in setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"))
      require(body == null || body.length <= ApiRecoveryPolicy.MAX_BYTES)
      val bytes = body?.toByteArray(Charsets.UTF_8)
      require(bytes == null || bytes.size <= ApiRecoveryPolicy.MAX_BYTES)
      require(verb !in setOf("GET", "HEAD") || body == null)
      val builder = Request.Builder().url(url)
      val names = headers.keySetIterator()
      var count = 0
      var headerBytes = 0
      var contentType: String? = null
      while (names.hasNextKey()) {
        val name = names.nextKey()
        require(++count <= 64 && headers.getType(name) == ReadableType.String)
        val value = headers.getString(name) ?: error("Invalid recovery header")
        require(ApiRecoveryPolicy.acceptsHeader(name, value))
        headerBytes += name.length + value.length
        require(headerBytes <= 32_768)
        builder.header(name, value)
        if (name.equals("content-type", true)) contentType = value
      }
      val requestBody = if (bytes != null || verb in setOf("POST", "PUT", "PATCH"))
        (bytes ?: ByteArray(0)).toRequestBody(contentType?.toMediaTypeOrNull()) else null
      val request = builder.method(verb, requestBody).build()
      synchronized(pending) {
        require(!closed.get() && pending.size < ApiRecoveryPolicy.MAX_CALLS && !pending.containsKey(id))
        pending[id] = slot
      }
      val network = selectNetwork() ?: error("No underlying network")
      val timeoutMs = deadlineEpochMillis.toLong() - System.currentTimeMillis()
      require(timeoutMs in 1L..120_000L)
      // A private pool cannot reuse a connection made through the failed VPN.
      // Preserve the application's TLS validation, pinning and cookie policy.
      val ownedPool = ConnectionPool(0, 1, TimeUnit.SECONDS)
      pool = ownedPool
      val client = OkHttpClientProvider.getOkHttpClient().newBuilder()
        .socketFactory(network.socketFactory)
        .dns(object : Dns {
          override fun lookup(hostname: String): List<InetAddress> = network.getAllByName(hostname).toList()
        })
        .connectionPool(ownedPool)
        .cache(null)
        .callTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
        .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
        .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
        .writeTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
        // Recovery must not forward credentials to another origin or downgrade TLS.
        .followRedirects(false).followSslRedirects(false)
        .build()
      val call = client.newCall(request)
      slot.call = call
      if (slot.cancelled.get() || closed.get()) call.cancel()
      call.enqueue(object : Callback {
        override fun onFailure(call: Call, error: IOException) {
          finish(id, slot, ownedPool)
          promise.reject("API_RECOVERY_FAILED", "Network request failed")
        }

        override fun onResponse(call: Call, response: Response) {
          try {
            response.use {
              val output = ByteArrayOutputStream()
              it.body?.byteStream()?.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                  val read = input.read(buffer)
                  if (read < 0) break
                  require(output.size() + read <= ApiRecoveryPolicy.MAX_BYTES)
                  output.write(buffer, 0, read)
                }
              }
              check(!slot.cancelled.get() && !closed.get() && !call.isCanceled() && System.currentTimeMillis() < deadlineEpochMillis)
              val result = Arguments.createMap()
              result.putInt("status", it.code)
              result.putString("statusText", it.message)
              result.putString("body", output.toString("UTF-8"))
              val replyHeaders = Arguments.createMap()
              it.headers.toMultimap().forEach { (name, values) -> replyHeaders.putString(name, values.joinToString(", ")) }
              result.putMap("headers", replyHeaders)
              Log.i("VexApiRecovery", "First-party recovery request completed")
              promise.resolve(result)
            }
          } catch (_: Exception) {
            promise.reject("API_RECOVERY_FAILED", "Network request failed")
          } finally {
            finish(id, slot, ownedPool)
          }
        }
      })
    } catch (_: Exception) {
      pending.remove(id, slot)
      pool?.evictAll()
      promise.reject("API_RECOVERY_FAILED", "Network request failed")
    }
  }

  private fun finish(id: String, slot: Pending, pool: ConnectionPool) {
    pending.remove(id, slot)
    pool.evictAll()
  }
}
