import SwiftUI

/// User-controlled foreground notices. Authorization is only requested after
/// the user enables the toggle; status refresh is an explicit non-prompt action.
struct CustomerNotificationSettingsSection: View {
    @ObservedObject var service: CustomerNotificationService

    var body: some View {
        SettingsFeatureCard(
            systemName: "bell.badge.fill",
            title: "Оповещения",
            subtitle: "Только при запущенном клиенте"
        ) {
            SettingsToggleRow(
                systemName: "bell",
                title: "Уведомления об активности",
                subtitle: service.isEnabled
                    ? "Показывать события поддержки и релизов в этом сеансе."
                    : "Отключены до вашего явного включения.",
                isOn: Binding(
                    get: { service.isEnabled },
                    set: { enabled in
                        Task { await service.setEnabled(enabled) }
                    }
                ),
                disabled: service.isBusy
            )

            Text("Уведомления об активности поддержки и релизов приходят только пока клиент запущен и получает события. Это не APNs/background push и не счётчик непрочитанных сообщений.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vexSecondaryText)
                .padding(.vertical, 9)

            SettingsInfoRow(
                systemName: "checkmark.circle",
                title: "Разрешение",
                value: service.authorizationSummary,
                tone: statusTone
            )

            if service.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Проверяем разрешение…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                    Spacer()
                }
                .padding(.vertical, 9)
            }

            if service.permissionStatus == .denied {
                Text("Разрешите уведомления для VEX в настройках «Уведомления» macOS, затем включите переключатель снова.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .padding(.vertical, 9)
            }

            if let errorMessage = service.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .padding(.vertical, 9)
            }

            Button {
                Task { await service.refreshAuthorization() }
            } label: {
                Label("Обновить статус разрешения", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.vexGlass)
            .disabled(service.isBusy)
            .help("Проверить текущее разрешение без системного запроса")
            .padding(.top, 8)
        }
    }

    private var statusTone: VEXStatusBadge.Tone {
        switch service.permissionStatus {
        case .authorized, .provisional, .ephemeral:
            return .good
        case .notDetermined:
            return .neutral
        case .denied:
            return .warning
        }
    }
}
