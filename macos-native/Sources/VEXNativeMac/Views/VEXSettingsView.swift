import SwiftUI

struct VEXSettingsView: View {
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel

    var body: some View {
        VStack(spacing: 14) {
            PageTitleBlock(title: "Настройки", subtitle: "Запуск, VPN, безопасность и системный helper.")
            incidentBanner
            generalSettings
            interfaceSettings
            helperSettings
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var incidentBanner: some View {
        if let banner = appState.remoteConfig?.incidentBanner?.trimmingCharacters(in: .whitespacesAndNewlines),
           !banner.isEmpty {
            CleanPanel {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.36))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Статус сервиса")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color.vexText)
                        Text(banner)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.vexSecondaryText)
                            .lineLimit(3)
                    }
                    Spacer()
                }
            }
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 12) {
            SettingsSection(title: "Запуск и VPN") {
                SettingsToggleRow(
                    systemName: "power",
                    title: "Запускать вместе с macOS",
                    subtitle: appState.autoLaunchEnabled ? "Приложение откроется после входа." : "Автозапуск выключен.",
                    isOn: Binding(
                        get: { appState.autoLaunchEnabled },
                        set: { appState.setAutoLaunchEnabled($0) }
                    )
                )
                SettingsToggleRow(systemName: "sparkles", title: "Автовыбор сервера", subtitle: "Выбирать ближайший доступный узел.", isOn: $appState.autoServerEnabled)
                SettingsToggleRow(
                    systemName: "globe.europe.africa",
                    title: "Умный режим",
                    subtitle: appState.smartRoutingEnabled ? "Российские сервисы идут без VPN." : "Весь трафик идет через VPN.",
                    isOn: Binding(
                        get: { appState.smartRoutingEnabled },
                        set: { appState.setSmartRoutingEnabled($0) }
                    )
                )
                SettingsToggleRow(systemName: "lock.shield", title: "Anti-leak", subtitle: "Защита от утечек при сбоях.", isOn: $appState.antiLeakEnabled)
                SettingsToggleRow(systemName: "arrow.triangle.2.circlepath", title: "Автовосстановление", subtitle: "Проверять и поднимать туннель автоматически.", isOn: $appState.autoRecoveryEnabled)
            }

            SettingsSection(title: "Безопасность") {
                SettingsToggleRow(
                    systemName: "touchid",
                    title: "Touch ID при запуске",
                    subtitle: appState.biometricAvailability.isAvailable ? "Разблокировка через \(appState.biometricAvailability.label)." : "Биометрия недоступна на этом Mac.",
                    isOn: $appState.biometricUnlockRequired,
                    disabled: !appState.biometricAvailability.isAvailable
                )
            }
        }
    }

    private var interfaceSettings: some View {
        SettingsSection(title: "Интерфейс") {
            SettingsLanguageRow(value: appState.interfaceLanguage, onChange: appState.setInterfaceLanguage)
        }
    }

    private var helperSettings: some View {
        VStack(spacing: 12) {
            SettingsSection(title: "Системный helper") {
                SettingsInfoRow(systemName: "checkmark.shield", title: "Статус", value: helperStatusText, tone: helperStatusTone)
                SettingsInfoRow(systemName: "number", title: "Версия", value: helperVersion, tone: .neutral)
                SettingsInfoRow(systemName: helper.status.state.symbolName, title: "VPN", value: helper.status.state.rawValue, tone: helper.status.state == .connected ? .good : .neutral)
            }

            SettingsSection(title: "Приложение") {
                SettingsInfoRow(systemName: "app.badge", title: "Версия", value: VEXAppInfo.version, tone: .neutral)
                SettingsInfoRow(systemName: "hammer", title: "Build", value: String(VEXAppInfo.buildNumber), tone: .neutral)
                SettingsInfoRow(systemName: "point.3.connected.trianglepath.dotted", title: "Канал", value: VEXAppInfo.channel, tone: .neutral)
                SettingsInfoRow(systemName: "cpu", title: "Ядро", value: VEXAppInfo.coreVersion, tone: .neutral)
                SettingsInfoRow(systemName: "network", title: "Маршруты", value: remoteRoutingPolicyVersion, tone: .neutral)
                SettingsInfoRow(systemName: "curlybraces", title: "API клиент", value: VEXAppInfo.apiClientVersion, tone: .neutral)
                SettingsInfoRow(systemName: "doc.badge.gearshape", title: "Схема", value: String(VEXAppInfo.configSchemaVersion), tone: .neutral)
            }
        }
    }

    private var remoteRoutingPolicyVersion: String {
        appState.remoteConfig?.routingPolicyVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? appState.remoteConfig?.routingPolicyVersion ?? VEXAppInfo.routingPolicyVersion
            : VEXAppInfo.routingPolicyVersion
    }

    private var helperStatusText: String {
        helper.installState?.filesCurrent == true ? "Установлен" : "Требует проверки"
    }

    private var helperStatusTone: VEXStatusBadge.Tone {
        helper.installState?.filesCurrent == true ? .good : .warning
    }

    private var helperVersion: String {
        let value = helper.installState?.version.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        CleanPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color.vexText)

                VStack(spacing: 0) {
                    content
                }
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let systemName: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 10) {
            SettingsGlyph(systemName: systemName)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.vexText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.vertical, 9)
        .opacity(disabled ? 0.62 : 1)
    }
}

private struct SettingsLanguageRow: View {
    let value: String
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            SettingsGlyph(systemName: "character.bubble")
            VStack(alignment: .leading, spacing: 2) {
                Text("Язык")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.vexText)
                Text("Язык интерфейса.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
            }
            Spacer(minLength: 10)
            Picker("", selection: Binding(get: { normalized }, set: onChange)) {
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            .frame(width: 154)
            .labelsHidden()
        }
        .padding(.vertical, 9)
    }

    private var normalized: String {
        value == "en" ? "en" : "ru"
    }
}

private struct SettingsInfoRow: View {
    let systemName: String
    let title: String
    let value: String
    let tone: VEXStatusBadge.Tone

    var body: some View {
        HStack(spacing: 10) {
            SettingsGlyph(systemName: systemName)
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.vexText)
                .lineLimit(1)
            Spacer(minLength: 10)
            VEXStatusBadge(text: value, tone: tone)
        }
        .padding(.vertical, 9)
    }
}

private struct SettingsGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.vexCyan)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.vexCyan.opacity(0.10)))
    }
}
