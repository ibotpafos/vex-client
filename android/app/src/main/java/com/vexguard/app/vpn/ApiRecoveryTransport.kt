package com.vexguard.app.vpn

import android.net.Network
import android.util.Log
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.modules.network.OkHttpClientProvider
import java.io.IOException
import java.net.InetAddress
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionPool
import okhttp3.Dns
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Request
import okhttp3.Response

/** Separate instances keep default-route mutations distinct from bound recovery. */
internal class ApiRecoveryTransport(
  private val mutationsOnly: Boolean = false,
  private val selectNetwork: (() -> Network?)? = null,
) {
  private class Pending {
    val cancelled = AtomicBoolean(false)
    @Volatile var call: Call? = null
    fun cancel() { cancelled.set(true); call?.cancel() }
  }

  private val closed = AtomicBoolean(false)
  private val pending = ConcurrentHashMap<String, Pending>()
  private val errorCode get() = if (mutationsOnly) "API_MUTATION_FAILED" else "API_RECOVERY_FAILED"

  fun cancel(id: String) { pending[id]?.cancel() }

  fun close() {
    closed.set(true)
    pending.values.forEach { it.cancel() }
  }

  fun request(id: String, url: String, method: String, headers: ReadableMap,
              body: String?, deadlineEpochMillis: Double, promise: Promise) {
    val slot = Pending()
    val httpError = AtomicReference<ApiHttpReply?>()
    var pool: ConnectionPool? = null
    try {
      require(ApiRecoveryPolicy.acceptsRequestId(id) && ApiRecoveryPolicy.acceptsUrl(url))
      require(deadlineEpochMillis.isFinite())
      require(deadlineEpochMillis - System.currentTimeMillis() in 1.0..120_000.0)
      val verb = method.uppercase(Locale.US)
      require(verb in setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"))
      require(!mutationsOnly || ApiRecoveryPolicy.acceptsMutationMethod(verb))
      require(body == null || ApiRecoveryPolicy.acceptsBodySize(body.length, mutationsOnly))
      val bytes = body?.toByteArray(Charsets.UTF_8)
      require(bytes == null || ApiRecoveryPolicy.acceptsBodySize(bytes.size, mutationsOnly))
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
      val requestBody = ApiHttpSafety.requestBody(verb, bytes, contentType?.toMediaTypeOrNull())
      val request = builder.method(verb, requestBody).build()
      synchronized(pending) {
        require(!closed.get() && pending.size < ApiRecoveryPolicy.MAX_CALLS && !pending.containsKey(id))
        pending[id] = slot
      }
      val timeoutMs = deadlineEpochMillis.toLong() - System.currentTimeMillis()
      require(timeoutMs in 1L..120_000L)
      val ensureActive = {
        if (slot.cancelled.get() || closed.get() || slot.call?.isCanceled() == true || System.currentTimeMillis() >= deadlineEpochMillis) {
          throw IOException("API request cancelled or expired")
        }
      }
      // Private pools never reuse sockets across routing classes or requests.
      val ownedPool = ConnectionPool(0, 1, TimeUnit.SECONDS)
      pool = ownedPool
      val clientBuilder = ApiHttpSafety.clientBuilder(OkHttpClientProvider.getOkHttpClient(), ownedPool, timeoutMs, ensureActive) {
        httpError.set(it)
      }
      if (mutationsOnly) {
        // Ordinary mutations follow the OS's default route, including captured
        // VPN routing. Never select/protect/bind an underlying network here.
        check(selectNetwork == null)
      } else {
        val network = selectNetwork?.invoke() ?: error("No underlying network")
        clientBuilder.socketFactory(network.socketFactory)
          .dns(object : Dns {
            override fun lookup(hostname: String): List<InetAddress> = network.getAllByName(hostname).toList()
          })
      }
      val client = clientBuilder.build()
      val call = client.newCall(request)
      slot.call = call
      if (slot.cancelled.get() || closed.get()) call.cancel()
      call.enqueue(object : Callback {
        override fun onFailure(call: Call, error: IOException) {
          try {
            val knownHttp = if (error is ApiHttpError) error.reply else httpError.get()
            if (knownHttp != null) {
              // Header arrival is irreversible evidence even when cancellation
              // or a body deadline replaces OkHttp's failure. JS still rejects
              // its own expired/aborted attempt before consuming this reply.
              resolve(promise, knownHttp)
            } else {
              ensureActive()
              promise.reject(errorCode, "Network request failed")
            }
          } catch (_: Exception) {
            promise.reject(errorCode, "Network request failed")
          } finally {
            finish(id, slot, ownedPool)
          }
        }

        override fun onResponse(call: Call, response: Response) {
          try {
            val reply = ApiHttpSafety.readReply(response, ensureActive)
            ensureActive()
            resolve(promise, reply)
          } catch (_: Exception) {
            promise.reject(errorCode, "Network request failed")
          } finally {
            finish(id, slot, ownedPool)
          }
        }
      })
    } catch (_: Exception) {
      pending.remove(id, slot)
      pool?.evictAll()
      promise.reject(errorCode, "Network request failed")
    }
  }

  private fun resolve(promise: Promise, reply: ApiHttpReply) {
    val result = Arguments.createMap()
    result.putInt("status", reply.status)
    result.putString("statusText", reply.statusText)
    result.putString("body", reply.body)
    val headers = Arguments.createMap()
    reply.headers.forEach { (name, value) -> headers.putString(name, value) }
    result.putMap("headers", headers)
    Log.i("VexApiRecovery", "First-party API request completed")
    promise.resolve(result)
  }

  private fun finish(id: String, slot: Pending, pool: ConnectionPool) {
    pending.remove(id, slot)
    pool.evictAll()
  }
}
