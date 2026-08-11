import SwiftUI

struct VEXSettingsView: View {
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel
    @State private var isSignOutConfirmationPresented = false

    var body: some View {
        VStack(spacing: 12) {
            SettingsHero()
            incidentBanner
            generalSettings
            interfaceSettings
            helperSettings
            accountSettings
        }
        .padding(.top, 2)
        .padding(.bottom, 16)
        .confirmationDialog(
            "Выйти из аккаунта?",
            isPresented: $isSignOutConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Выйти", role: .destructive) {
                appState.signOut()
            }
        } message: {
            Text("VPN будет отключён только вручную. Сессия на этом Mac будет удалена.")
        }
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
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12, alignment: .top),
                GridItem(.flexible(), spacing: 12, alignment: .top)
            ],
            alignment: .leading,
            spacing: 12
        ) {
            SettingsFeatureCard(
                systemName: "bolt.horizontal.circle.fill",
                title: "Подключение",
                subtitle: "Быстрый запуск и выбор маршрута"
            ) {
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
            }

            SettingsFeatureCard(
                systemName: "shield.lefthalf.filled",
                title: "Защита",
                subtitle: "Сеть восстанавливается без ручных действий"
            ) {
                SettingsToggleRow(systemName: "lock.shield", title: "Kill Switch", subtitle: "Блокирует утечки трафика при сбое VPN.", isOn: $appState.antiLeakEnabled)
                SettingsToggleRow(systemName: "arrow.triangle.2.circlepath", title: "Автовосстановление", subtitle: "Проверять и поднимать туннель автоматически.", isOn: $appState.autoRecoveryEnabled)
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
        SettingsFeatureCard(
            systemName: "slider.horizontal.3",
            title: "Интерфейс",
            subtitle: "Персональные параметры приложения"
        ) {
            SettingsLanguageRow(value: appState.interfaceLanguage) { value in
                appState.setInterfaceLanguage(value)
            }
        }
    }

    private var helperSettings: some View {
        VStack(spacing: 12) {
            SettingsFeatureCard(
                systemName: "cpu.fill",
                title: "Системный компонент",
                subtitle: "Состояние локального VPN-движка"
            ) {
                SettingsInfoRow(systemName: "checkmark.shield", title: "Статус", value: helperStatusText, tone: helperStatusTone)
                SettingsInfoRow(systemName: "number", title: "Версия", value: helperVersion, tone: .neutral)
                helperRepairRow
            }

            SettingsFeatureCard(
                systemName: "app.badge.fill",
                title: "Обновления",
                subtitle: "Новые версии без лишних действий"
            ) {
                SettingsToggleRow(
                    systemName: "arrow.down.circle",
                    title: "Обновлять VEX автоматически",
                    subtitle: appState.automaticallyChecksForUpdates
                        ? "Обновления скачиваются в фоне и применяются при перезапуске."
                        : "Автоматическая проверка обновлений выключена.",
                    isOn: Binding(
                        get: { appState.automaticallyChecksForUpdates },
                        set: { appState.automaticallyChecksForUpdates = $0 }
                    )
                )
                Button {
                    appState.checkForNativeUpdates()
                } label: {
                    Label(
                        appState.hasNewerNativeUpdate ? "Установить обновление" : "Проверить обновления",
                        systemImage: appState.hasNewerNativeUpdate
                            ? "arrow.down.circle.fill"
                            : "arrow.triangle.2.circlepath"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vexGlass)
                .help(
                    appState.availableNativeUpdateVersion.map {
                        "Доступно обновление \($0)"
                    } ?? "Проверить наличие новой версии VEX"
                )
            }
        }
    }

    @ViewBuilder
    private var accountSettings: some View {
        if appState.isAuthenticated {
            SettingsFeatureCard(
                systemName: "person.crop.circle",
                title: "Аккаунт",
                subtitle: "Управление входом на этом Mac"
            ) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Выйти из аккаунта")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.vexText)
                        Text("Удалит сохранённую сессию с этого Mac.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.vexSecondaryText)
                    }
                    Spacer(minLength: 12)
                    Button("Выйти") {
                        isSignOutConfirmationPresented = true
                    }
                    .buttonStyle(.vexGlass)
                    .tint(.red)
                    .accessibilityLabel("Выйти из аккаунта")
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var helperStatusText: String {
        if helper.installationPhase != .idle {
            return helper.installationPhase.title
        }
        guard let installState = helper.installState else {
            return "Проверяем"
        }
        return installState.filesCurrent ? "Установлен" : "Требует установки"
    }

    private var helperStatusTone: VEXStatusBadge.Tone {
        if case .failed = helper.installationPhase {
            return .warning
        }
        return helper.installState?.filesCurrent == true ? .good : .warning
    }

    private var helperVersion: String {
        let value = helper.installState?.version.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            return "unknown"
        }
        guard helper.installState?.filesCurrent == true else {
            return "\(value) устарел"
        }
        return value
    }

    @ViewBuilder
    private var helperRepairRow: some View {
        if helper.installState?.filesCurrent != true {
            HStack(spacing: 10) {
                SettingsGlyph(systemName: "wrench.and.screwdriver")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Root helper")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color.vexText)
                    Text(
                        helper.installationPhase == .idle
                            ? "Установить актуальный системный helper."
                            : helper.installationPhase.detail
                    )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 10)
                Button {
                    Task {
                        await helper.repairHelper()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if helper.isBusy {
                            VEXMiniSpinner(tint: Color.vexBackground)
                        }
                        Text(helper.isBusy ? "Установка…" : "Установить")
                    }
                }
                .buttonStyle(.vexProminentGlass)
                .disabled(helper.isBusy)
            }
            .padding(.vertical, 9)
        }
    }
}

private struct SettingsHero: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Color.vexCyanLight)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Настройки VEX")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(Color.vexText)
                Text("Сеть, защита и приложение — в одном месте")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

private struct SettingsFeatureCard<Content: View>: View {
    let systemName: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SettingsGlyph(systemName: systemName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color.vexText)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
            }

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            VStack(spacing: 0) {
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.vexPanel.opacity(0.46))
        }
    }
}

private struct SettingsCompactFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color.vexMuted)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.vexText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .toggleStyle(VEXSwitchToggleStyle())
                .labelsHidden()
                .disabled(disabled)
                .accessibilityLabel(title)
                .accessibilityHint(subtitle)
        }
        .padding(.vertical, 9)
        .opacity(disabled ? 0.62 : 1)
    }
}

private struct VEXSwitchToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? Color.vexCyan : Color.white.opacity(0.16))
                    .overlay {
                        Capsule()
                            .stroke(
                                configuration.isOn
                                    ? Color.vexCyanLight.opacity(0.42)
                                    : Color.white.opacity(0.10),
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: configuration.isOn
                            ? Color.vexCyan.opacity(0.38)
                            : Color.clear,
                        radius: 7
                    )

                Circle()
                    .fill(Color.vexText)
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.black.opacity(0.24), radius: 2, y: 1)
                    .offset(x: configuration.isOn ? 8 : -8)
            }
            .frame(width: 40, height: 23)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(
            accessibilityReduceMotion
                ? .linear(duration: 0.01)
                : .snappy(duration: 0.20, extraBounce: 0.03),
            value: configuration.isOn
        )
        .accessibilityValue(configuration.isOn ? "Включено" : "Выключено")
    }
}

private struct SettingsLanguageRow: View {
    let value: String
    let onChange: @MainActor @Sendable (String) -> Void

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
            Picker("", selection: Binding(get: { normalized }, set: { onChange($0) })) {
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            .frame(width: 154)
            .labelsHidden()
            .accessibilityLabel("Язык интерфейса")
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
            .accessibilityHidden(true)
    }
}
