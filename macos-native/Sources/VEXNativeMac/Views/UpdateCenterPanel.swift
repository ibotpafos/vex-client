import SwiftUI

struct UpdateCenterPanel: View {
    @EnvironmentObject private var appState: VEXAppState

    var body: some View {
        VEXSheetScaffold(title: "Обновления", subtitle: "Проверка релиза native/macOS клиента.") {
            VStack(spacing: 14) {
                VStack(spacing: 12) {
                    GlassPanel(cornerRadius: 18) {
                        HStack(spacing: 12) {
                            PanelIcon(systemName: appState.updateCheck?.updateAvailable == true ? "arrow.down.circle" : "checkmark.seal", size: 46, iconSize: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(updateTitle)
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(Color.vexText)
                                    .lineLimit(2)
                                Text(updateSubtitle)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.vexSecondaryText)
                                    .lineLimit(3)
                            }
                            Spacer()
                            VEXStatusBadge(text: updateBadgeText, tone: updateBadgeTone)
                        }
                    }

                    GlassPanel(cornerRadius: 18) {
                        VStack(spacing: 8) {
                            UpdateInfoRow(title: "Текущая версия", value: "\(VEXAppInfo.version) (\(VEXAppInfo.buildNumber))")
                            UpdateInfoRow(title: "Доступная версия", value: availableVersionText)
                            UpdateInfoRow(title: "Канал", value: appState.updateCheck?.channel ?? VEXAppInfo.channel)
                            UpdateInfoRow(title: "Совместимость", value: compatibilityText, tone: compatibilityTone)
                            UpdateInfoRow(title: "Последняя сборка", value: appState.updateCheck.map { "\($0.latestVersion) (\($0.latestBuild))" } ?? "Проверяется")
                            if let minBuild = appState.updateCheck?.minSupportedBuild, minBuild > 0 {
                                UpdateInfoRow(title: "Минимальная сборка", value: String(minBuild))
                            }
                            if let rollout = appState.updateCheck?.rolloutPercent {
                                UpdateInfoRow(title: "Rollout", value: "\(rollout)%")
                            }
                            if appState.updateCheck?.checksumSha256?.isEmpty == false {
                                UpdateInfoRow(title: "Checksum", value: "SHA-256")
                            }
                            if appState.updateCheck?.signatureUrl?.isEmpty == false {
                                UpdateInfoRow(title: "Подпись", value: "Доступна")
                            }
                        }
                    }

                    Button {
                        appState.checkForNativeUpdates()
                    } label: {
                        Label(appState.updateCheck?.updateAvailable == true ? "Открыть Sparkle update" : "Проверить через Sparkle", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vexProminentGlass)
                    .tint(Color.vexCyan)
                    .disabled(!appState.canCheckForNativeUpdates)

                    if appState.updateCheck?.downloadUrl.isEmpty == false {
                        Button {
                            appState.openUpdateDownload()
                        } label: {
                            Label("Открыть ручную ссылку", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.vexGlass)

                        Button {
                            Task { await appState.downloadUpdate() }
                        } label: {
                            Label(appState.isDownloadingUpdate ? "Скачиваем" : "Скачать в Загрузки", systemImage: "arrow.down.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.vexGlass)
                        .disabled(appState.isDownloadingUpdate)

                        Button {
                            Task { await appState.restartAndUpdateNow() }
                        } label: {
                            Label("Скачать и открыть установщик", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.vexProminentGlass)
                        .tint(appState.updateCheck?.required == true || appState.updateCheck?.currentBuildBlocked == true ? .orange : Color.vexCyan)
                        .disabled(appState.isDownloadingUpdate)
                    }

                    Button {
                        Task { await appState.refreshUpdates() }
                    } label: {
                        Label("Проверить снова", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vexGlass)
                }
            }
        }
        .task {
            await appState.refreshUpdates()
        }
    }

    private var updateTitle: String {
        guard let update = appState.updateCheck else { return "Проверяем обновления" }
        if update.currentBuildBlocked == true {
            return "Эта сборка больше не поддерживается"
        }
        if update.required {
            return "Требуется обновление"
        }
        return update.updateAvailable ? "Доступна версия \(update.latestVersion)" : "Установлена актуальная версия"
    }

    private var updateSubtitle: String {
        guard let update = appState.updateCheck else { return "Подключаемся к VEX update API." }
        if update.currentBuildBlocked == true {
            return update.reason ?? "Поставьте актуальную сборку VEX, чтобы продолжить стабильную работу."
        }
        if update.required {
            return update.reason ?? update.changelog ?? "Эта версия должна быть обновлена."
        }
        if update.updateAvailable {
            return update.changelog ?? update.reason ?? "Сборка \(update.latestBuild) доступна для загрузки."
        }
        return "Канал \(update.channel ?? "native-preview"), сборка \(update.latestBuild)."
    }

    private var updateBadgeText: String {
        guard let update = appState.updateCheck else { return "Проверка" }
        if update.currentBuildBlocked == true { return "Заблокировано" }
        if update.required { return "Обязательно" }
        return update.updateAvailable ? "Доступно" : "Актуально"
    }

    private var updateBadgeTone: VEXStatusBadge.Tone {
        guard let update = appState.updateCheck else { return .neutral }
        if update.currentBuildBlocked == true { return .danger }
        if update.required { return .warning }
        return update.updateAvailable ? .warning : .good
    }

    private var availableVersionText: String {
        guard let update = appState.updateCheck else { return "Проверяется" }
        return update.updateAvailable ? "\(update.latestVersion) (\(update.latestBuild))" : "Нет новой версии"
    }

    private var compatibilityText: String {
        guard let update = appState.updateCheck else { return "Проверяется" }
        if update.currentBuildBlocked == true { return "Сборка заблокирована" }
        if update.required { return "Требуется обновление" }
        return "Совместимо"
    }

    private var compatibilityTone: VEXStatusBadge.Tone {
        guard let update = appState.updateCheck else { return .neutral }
        if update.currentBuildBlocked == true { return .danger }
        return update.required ? .warning : .good
    }
}

private struct UpdateInfoRow: View {
    let title: String
    let value: String
    var tone: VEXStatusBadge.Tone = .neutral

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color.vexMuted)
                .lineLimit(1)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(minHeight: 26)
    }

    private var valueColor: Color {
        switch tone {
        case .good:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        case .neutral:
            return Color.vexText
        }
    }
}
