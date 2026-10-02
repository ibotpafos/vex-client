import SwiftUI

struct NativeRemotePushSettingsSection: View {
    @ObservedObject var appState: VEXAppState
    @ObservedObject var registration: NativePushRegistrationService

    var body: some View {
        SettingsFeatureCard(systemName: "arrow.triangle.2.circlepath", title: "Фоновые обновления APNs", subtitle: "Отдельное явное разрешение") {
            SettingsToggleRow(systemName: "network", title: "Обновлять данные по push",
                subtitle: "Сохранять события и безопасно применять подтверждённую смену ключей.",
                isOn: Binding(get: { appState.nativeRemotePushEnabled }, set: { appState.setNativeRemotePushEnabled($0) }),
                disabled: !appState.canUseNativeRemotePush)
            Text(appState.canUseNativeRemotePush
                ? "Push содержит только событие. Новый профиль проверяется, сохраняется и подтверждается серверу до применения. Нужен доверенный публичный ключ сервера; неподдерживаемая политика маршрутизации не применяется."
                : "Для APNs нужна отдельная подписанная сборка с push entitlement и provisioning profile. В этой офлайн-сборке функция недоступна.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vexSecondaryText)
                .padding(.vertical, 9)
            SettingsInfoRow(systemName: "checkmark.circle", title: "Регистрация", value: statusText,
                tone: registration.status == .registered ? .good : .neutral)
            if let message = appState.nativePushRegistrationError {
                Text(message).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.vexSecondaryText)
            }
            if let message = appState.nativePushEventError {
                Text(message).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.vexSecondaryText)
            }
            Button("Повторить регистрацию") { appState.retryNativePushRegistration() }
                .buttonStyle(.vexGlass)
                .disabled(!appState.canUseNativeRemotePush || !appState.nativeRemotePushEnabled)
            Button(appState.isNativePSKPreparationBusy ? "Подготавливаем смену ключа…" : "Подготовить смену ключа VPN") {
                appState.prepareNativePSKRotation()
            }
                .buttonStyle(.vexGlass)
                .disabled(!appState.canPrepareNativePSKRotation)
            Text("Только для текущего собственного профиля Mac. Подготовка не включает новый профиль: подпись, сохранение, ACK и подтверждение сервера обязательны.")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.vexSecondaryText)
        }
    }

    private var statusText: String {
        switch registration.status {
        case .disabled: return "Отключена"
        case .idle: return "Ожидаем профиль устройства и токен Apple"
        case .queued: return "Регистрируем устройство"
        case .registered: return "Токен зарегистрирован на сервере"
        case .failed: return "Ошибка — повторите явно"
        }
    }
}
