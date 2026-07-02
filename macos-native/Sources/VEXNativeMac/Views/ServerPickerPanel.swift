import SwiftUI

struct ServerPickerPanel: View {
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VEXSheetScaffold(title: "Серверы", subtitle: "Ближайший стабильный узел для текущей сессии.") {
            ScrollView {
                VStack(spacing: 10) {
                    ServerPickerRow(
                        systemName: "sparkles",
                        title: "Автовыбор",
                        subtitle: "VEX выберет лучший доступный сервер",
                        trailing: appState.serverSelectionMode == "auto" ? "Выбран" : nil,
                        selected: appState.serverSelectionMode == "auto"
                    ) {
                        appState.selectAutoServer()
                        Task { await appState.applySelectedLocationIfConnected(using: helper) }
                        dismiss()
                    }

                    if appState.locations.isEmpty {
                        ServerPickerEmptyRow(isLoading: appState.isLoading)
                    } else {
                        ForEach(appState.locations) { location in
                            ServerPickerRow(
                                systemName: "mappin.and.ellipse",
                                title: location.displayName,
                                subtitle: "\(location.healthyNodes) узлов · \(localizedStatus(location.status))",
                                trailing: location.latencyMs.map { "\(Int($0.rounded())) мс" },
                                selected: appState.serverSelectionMode == "manual" && appState.selectedLocationId == location.id
                            ) {
                                Task {
                                    await appState.selectLocation(location)
                                    await appState.applySelectedLocationIfConnected(using: helper)
                                }
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .task {
            await appState.refreshAll()
        }
    }

    private func localizedStatus(_ value: String) -> String {
        switch value.lowercased() {
        case "active", "online", "healthy":
            return "доступен"
        case "maintenance":
            return "обслуживание"
        default:
            return value.isEmpty ? "статус уточняется" : value
        }
    }
}

private struct ServerPickerRow: View {
    let systemName: String
    let title: String
    let subtitle: String
    let trailing: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassPanel(cornerRadius: 16) {
                HStack(spacing: 12) {
                    PanelIcon(systemName: systemName, size: 38, iconSize: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color.vexText)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.vexSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color.vexCyanLight)
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.vexCyan : Color.vexMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ServerPickerEmptyRow: View {
    let isLoading: Bool

    var body: some View {
        GlassPanel(cornerRadius: 16, tint: Color.vexCyan.opacity(0.08)) {
            HStack(spacing: 12) {
                PanelIcon(systemName: isLoading ? "arrow.clockwise" : "server.rack", size: 38, iconSize: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isLoading ? "Загружаем серверы" : "Список серверов недоступен")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color.vexText)
                        .lineLimit(1)
                    Text(isLoading ? "Проверяем доступные узлы VEX." : "Откройте экран позже или обновите аккаунт.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(2)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.vexCyan)
                }
            }
            .frame(minHeight: 58)
        }
    }
}
