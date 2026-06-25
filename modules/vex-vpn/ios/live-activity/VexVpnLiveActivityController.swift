import ActivityKit
import Foundation

enum VexVpnLiveActivityController {
  static func update(payload: [String: Any]) async -> Bool {
    guard #available(iOS 16.4, *) else {
      return false
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      return false
    }

    let state = contentState(from: payload)
    if state.state == "disconnected" && state.phase == "idle" {
      await end()
      return true
    }

    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(90))
    if let activity = Activity<VexVpnActivityAttributes>.activities.first {
      await activity.update(content)
      return true
    }

    do {
      _ = try Activity.request(
        attributes: VexVpnActivityAttributes(name: "VEX VPN"),
        content: content,
        pushType: nil
      )
      return true
    } catch {
      VexVpnDiagnostics.record("ios_live_activity_start_failed", details: ["error": error.localizedDescription])
      return false
    }
  }

  @discardableResult
  static func end() async -> Bool {
    guard #available(iOS 16.4, *) else {
      return false
    }

    let finalState = VexVpnActivityAttributes.ContentState(
      state: "disconnected",
      phase: "idle",
      locationName: "VEX",
      latencyText: "",
      receivedText: "0 B",
      sentText: "0 B",
      updatedAtEpochSeconds: Date().timeIntervalSince1970
    )
    let content = ActivityContent(state: finalState, staleDate: nil)
    for activity in Activity<VexVpnActivityAttributes>.activities {
      await activity.end(content, dismissalPolicy: .immediate)
    }
    return true
  }

  @available(iOS 16.4, *)
  private static func contentState(from payload: [String: Any]) -> VexVpnActivityAttributes.ContentState {
    let state = string(payload["state"], fallback: "disconnected")
    let phase = string(payload["phase"], fallback: state == "connected" ? "connected" : "idle")
    let locationName = string(payload["locationName"], fallback: "VEX")
    let latencyText = string(payload["latencyText"], fallback: "")
    let receivedText = string(payload["receivedText"], fallback: "0 B")
    let sentText = string(payload["sentText"], fallback: "0 B")
    let updatedAtEpochSeconds = payload["updatedAtEpochSeconds"] as? Double ?? Date().timeIntervalSince1970

    return VexVpnActivityAttributes.ContentState(
      state: state,
      phase: phase,
      locationName: locationName,
      latencyText: latencyText,
      receivedText: receivedText,
      sentText: sentText,
      updatedAtEpochSeconds: updatedAtEpochSeconds
    )
  }

  private static func string(_ value: Any?, fallback: String) -> String {
    guard let text = value as? String else {
      return fallback
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}
