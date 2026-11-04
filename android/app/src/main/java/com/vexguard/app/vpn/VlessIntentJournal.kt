package com.vexguard.app.vpn

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID

/** Cross-process desired-state authority; SharedPreferences caches are not IPC. */
internal class VlessIntentJournal(private val directory: File) {
  data class State(
    val fence: String,
    val attemptId: String,
    val wanted: Boolean,
    val hold: Boolean,
    val permit: Boolean,
    val revoked: Boolean,
  )

  fun snapshot(): State = transaction { it to it }
  fun ticket(): String = snapshot().fence

  /** Called only after the explicit requestPermission bridge succeeds. */
  fun authorizeManual() = transaction { _ ->
    State(id(), "", false, false, true, false) to Unit
  }

  fun begin(ticket: String, hold: Boolean): String = transaction { state ->
    check(ticket == state.fence && !state.revoked && (state.wanted || state.permit)) {
      "VLESS requires a current user-authorized connection intent."
    }
    val attempt = id()
    state.copy(attemptId = attempt, wanted = true, hold = hold, permit = false) to attempt
  }

  fun isCurrent(attempt: String): Boolean {
    val state = snapshot()
    return attempt.isNotEmpty() && attempt == state.attemptId && state.wanted && !state.revoked
  }

  /** A stale/retired worker cannot revoke its successor or an internal handover. */
  fun revoke(attempt: String): Boolean = transaction { state ->
    if (attempt.isEmpty() || attempt != state.attemptId || state.revoked) state to false
    else state.copy(fence = id(), wanted = false, hold = false, permit = false, revoked = true) to true
  }

  fun stop(retainCapture: Boolean) = transaction { state ->
    state.copy(fence = id(), attemptId = "", wanted = false,
      hold = retainCapture && !state.revoked, permit = false) to Unit
  }

  /** Retire the worker before an intentional same-owner blocker takeover. */
  fun prepareRecoveryCapture(): Boolean = transaction { state ->
    if (state.revoked || !(state.wanted || state.hold)) state to false
    else state.copy(attemptId = "") to true
  }

  private fun <T> transaction(action: (State) -> Pair<State, T>): T = synchronized(localLock) {
    check(directory.isDirectory || directory.mkdirs()) { "VLESS intent storage is unavailable." }
    RandomAccessFile(File(directory, "vless-intent.lock"), "rw").use { lock ->
      lock.channel.lock().use {
        val file = File(directory, "vless-intent.json")
        val previous = if (!file.exists()) State(id(), "", false, false, false, false) else runCatching {
          val value = JSONObject(file.readText())
          check(value.getInt("schema") == 1)
          State(value.getString("fence"), value.getString("attemptId"), value.getBoolean("wanted"),
            value.getBoolean("hold"), value.getBoolean("permit"), value.getBoolean("revoked"))
        }.getOrElse {
          // Lost/corrupt authority is never automatic authorization. A new
          // explicit permission request can replace this fail-closed record.
          State(id(), "", false, false, false, true)
        }
        val (next, result) = action(previous)
        if (next != previous || !file.exists()) {
          val value = JSONObject().put("schema", 1).put("fence", next.fence)
            .put("attemptId", next.attemptId).put("wanted", next.wanted)
            .put("hold", next.hold).put("permit", next.permit).put("revoked", next.revoked)
          val temporary = File.createTempFile("vless-intent-", ".tmp", directory)
          try {
            FileOutputStream(temporary).use { stream ->
              stream.write(value.toString().toByteArray(Charsets.UTF_8))
              stream.fd.sync()
            }
            check(temporary.renameTo(file)) { "VLESS intent could not be recorded." }
          } finally { temporary.delete() }
        }
        result
      }
    }
  }

  companion object {
    private val localLock = Any()
    private fun id() = UUID.randomUUID().toString()
  }
}
