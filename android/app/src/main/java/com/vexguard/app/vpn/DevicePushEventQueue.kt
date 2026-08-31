package com.vexguard.app.vpn

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

object DevicePushEventQueue {
  private const val preferencesName = "vex_device_push_events"
  private const val eventsKey = "pending_events"
  private const val maximumEvents = 32

  @Synchronized
  fun enqueue(context: Context, data: Map<String, String>) {
    val eventID = data["event_id"].orEmpty().trim()
    val type = data["type"].orEmpty().trim()
    val rotationID = data["rotation_id"].orEmpty().trim()
    val profileVersion = data["profile_version"].orEmpty().toIntOrNull() ?: 0
    if (eventID.isEmpty() || rotationID.isEmpty() || profileVersion <= 0 || (type != "profile_updated" && type != "cutover_ready")) return

    val events = read(context)
    if ((0 until events.length()).any { events.optJSONObject(it)?.optString("event_id") == eventID }) return
    events.put(JSONObject(data))
    val bounded = JSONArray()
    val start = (events.length() - maximumEvents).coerceAtLeast(0)
    for (index in start until events.length()) bounded.put(events.getJSONObject(index))
    write(context, bounded)
  }

  @Synchronized
  fun pending(context: Context): List<Map<String, String>> {
    val events = read(context)
    return (0 until events.length()).mapNotNull { index ->
      events.optJSONObject(index)?.let { item ->
        item.keys().asSequence().associateWith { key -> item.optString(key) }
      }
    }
  }

  @Synchronized
  fun acknowledge(context: Context, eventID: String) {
    val normalized = eventID.trim()
    if (normalized.isEmpty()) return
    val events = read(context)
    val remaining = JSONArray()
    for (index in 0 until events.length()) {
      val item = events.optJSONObject(index) ?: continue
      if (item.optString("event_id") != normalized) remaining.put(item)
    }
    write(context, remaining)
  }

  private fun read(context: Context): JSONArray {
    val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE).getString(eventsKey, "[]") ?: "[]"
    return try { JSONArray(raw) } catch (_: Exception) { JSONArray() }
  }

  private fun write(context: Context, events: JSONArray) {
    context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE).edit().putString(eventsKey, events.toString()).apply()
  }
}
