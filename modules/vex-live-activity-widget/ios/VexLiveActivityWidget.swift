import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VexLiveActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    VexLiveActivityWidget()
  }
}

struct VexLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VexVpnActivityAttributes.self) { context in
      VexLockScreenLiveActivityView(state: context.state)
        .activityBackgroundTint(VexLiveActivityColors.background)
        .activitySystemActionForegroundColor(VexLiveActivityColors.cyan)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VexExpandedStatusView(state: context.state)
        }
        DynamicIslandExpandedRegion(.trailing) {
          VexExpandedTrafficView(state: context.state)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VexExpandedBottomView(state: context.state)
        }
      } compactLeading: {
        Image(systemName: context.state.state == "degraded" ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
          .foregroundStyle(context.state.state == "degraded" ? VexLiveActivityColors.warning : VexLiveActivityColors.cyan)
      } compactTrailing: {
        Text(compactStateText(context.state))
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(VexLiveActivityColors.foreground)
      } minimal: {
        Image(systemName: context.state.state == "degraded" ? "exclamationmark.shield.fill" : "shield.fill")
          .foregroundStyle(context.state.state == "degraded" ? VexLiveActivityColors.warning : VexLiveActivityColors.cyan)
      }
      .widgetURL(URL(string: "vexguard://"))
      .keylineTint(VexLiveActivityColors.cyan)
    }
  }
}

private struct VexLockScreenLiveActivityView: View {
  let state: VexVpnActivityAttributes.ContentState

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(VexLiveActivityColors.cyan.opacity(0.22))
        Image(systemName: state.state == "degraded" ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
          .font(.system(size: 22, weight: .bold))
          .foregroundStyle(state.state == "degraded" ? VexLiveActivityColors.warning : VexLiveActivityColors.cyan)
      }
      .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 3) {
        Text(statusTitle(state))
          .font(.system(size: 17, weight: .heavy, design: .rounded))
          .foregroundStyle(VexLiveActivityColors.foreground)
        Text(subtitle(state))
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(VexLiveActivityColors.secondary)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 3) {
        Text(state.receivedText)
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(VexLiveActivityColors.foreground)
        Text("получено")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(VexLiveActivityColors.secondary)
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 16)
  }
}

private struct VexExpandedStatusView: View {
  let state: VexVpnActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("VEX")
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .foregroundStyle(VexLiveActivityColors.cyan)
      Text(statusTitle(state))
        .font(.system(size: 15, weight: .heavy, design: .rounded))
        .foregroundStyle(VexLiveActivityColors.foreground)
      Text(state.locationName)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(VexLiveActivityColors.secondary)
    }
  }
}

private struct VexExpandedTrafficView: View {
  let state: VexVpnActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      Text(state.latencyText.isEmpty ? "туннель" : state.latencyText)
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .foregroundStyle(VexLiveActivityColors.cyan)
      Text("↓ \(state.receivedText)")
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .foregroundStyle(VexLiveActivityColors.foreground)
      Text("↑ \(state.sentText)")
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .foregroundStyle(VexLiveActivityColors.secondary)
    }
  }
}

private struct VexExpandedBottomView: View {
  let state: VexVpnActivityAttributes.ContentState

  var body: some View {
    HStack(spacing: 8) {
      Capsule()
        .fill(state.state == "degraded" ? VexLiveActivityColors.warning : VexLiveActivityColors.cyan)
        .frame(width: 34, height: 5)
      Text(subtitle(state))
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(VexLiveActivityColors.secondary)
      Spacer(minLength: 0)
    }
  }
}

private enum VexLiveActivityColors {
  static let background = Color(red: 0.0, green: 0.05, blue: 0.055)
  static let cyan = Color(red: 0.13, green: 0.85, blue: 0.93)
  static let foreground = Color.white
  static let secondary = Color(red: 0.68, green: 0.78, blue: 0.78)
  static let warning = Color(red: 1.0, green: 0.72, blue: 0.22)
}

private func compactStateText(_ state: VexVpnActivityAttributes.ContentState) -> String {
  switch state.state {
  case "connected":
    return "ON"
  case "degraded":
    return "!"
  case "connecting", "verifying":
    return "..."
  case "disconnecting":
    return "OFF"
  default:
    return "VPN"
  }
}

private func statusTitle(_ state: VexVpnActivityAttributes.ContentState) -> String {
  switch state.state {
  case "connected":
    return "VPN подключен"
  case "degraded":
    return "VPN восстанавливается"
  case "connecting", "verifying":
    return "Подключаем VPN"
  case "disconnecting":
    return "Отключаем VPN"
  default:
    return "VEX VPN"
  }
}

private func subtitle(_ state: VexVpnActivityAttributes.ContentState) -> String {
  if state.state == "degraded" {
    return "Автопилот чинит туннель"
  }
  if state.state == "connected" {
    return state.latencyText.isEmpty ? "Трафик идёт через VEX" : "Трафик идёт, \(state.latencyText)"
  }
  if state.state == "connecting" || state.state == "verifying" {
    return "Открываем защищённый канал"
  }
  return state.locationName
}
