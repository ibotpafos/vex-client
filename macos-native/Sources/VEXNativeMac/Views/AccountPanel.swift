import AppKit
import SwiftUI

struct AccountPanel: View {
    @EnvironmentObject private var appState: VEXAppState

    var body: some View {
        VStack(spacing: 12) {
            accountSummary

            if appState.accessToken != nil {
                subscriptionPicker
                deviceManagement
                paymentHistory
            } else {
                Button {
                    appState.openSignIn()
                } label: {
                    Text("Войти через сайт")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vexProminentGlass)
                .tint(Color.vexCyan)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 16)
        .task {
            await appState.refreshBilling()
        }
    }

    private var accountSummary: some View {
        AccountHero(
            accountTitle: appState.accountTitle,
            planTitle: appState.billingSummary?.currentPlan?.name ?? accessTitle,
            accessSubtitle: accessSubtitle,
            badgeText: accessBadgeText,
            badgeTone: accessBadgeTone,
            hasPaidAccess: appState.entitlement?.hasPaidAccess == true
        )
    }

    private var subscriptionPicker: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Подписка")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color.vexText)
                    Text("Оплата и управление подпиской — на сайте VEX")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                }
                Spacer()
            }

            Button {
                NSWorkspace.shared.open(BillingPresentation.billingDashboardURL)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard")
                    Text("Оплатить на сайте")
                        .font(.system(size: 12, weight: .black))
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.vexProminentGlass)
            .tint(Color.vexCyan)
        }
        .padding(.horizontal, 15)
    }

    private var paymentHistory: some View {
        AccountSurfaceCard(accent: .vexMuted) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Оплаты")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color.vexText)
                    Text("Последние операции по подписке")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                }

                if appState.billingPayments.isEmpty {
                    EmptyPaymentHistory()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(appState.billingPayments.prefix(6).enumerated()), id: \.element.id) { index, payment in
                            PaymentHistoryRow(payment: payment)
                            if index < min(appState.billingPayments.count, 6) - 1 {
                                Divider().overlay(Color.white.opacity(0.06))
                            }
                        }
                    }
                }
            }
        }
    }

    private var deviceManagement: some View {
        AccountSurfaceCard(accent: .vexCyan) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Устройства")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color.vexText)
                        Text(deviceLimitSubtitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.vexSecondaryText)
                    }
                    Spacer()
                    if let entitlement = appState.entitlement, entitlement.deviceLimit > 0 {
                        VEXStatusBadge(
                            text: "\(entitlement.activeDevices)/\(entitlement.deviceLimit)",
                            tone: entitlement.remainingDeviceSlots > 0 ? .good : .warning
                        )
                    }
                }

                if !appState.accountDevices.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(appState.accountDevices.prefix(4)) { device in
                            HStack(spacing: 9) {
                                Image(systemName: deviceIcon(for: device))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.vexCyanLight)
                                    .frame(width: 24, height: 24)
                                    .background(Color.vexCyan.opacity(0.10), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name.isEmpty ? "Устройство VEX" : device.name)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.vexText)
                                    Text(deviceStatusText(device))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.vexMuted)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .contextMenu {
                                Button("Переименовать") {
                                    Task {
                                        await appState.renameDevice(device, name: "Mac")
                                    }
                                }
                                Button("Удалить устройство", role: .destructive) {
                                    Task {
                                        await appState.removeDevice(device)
                                    }
                                }
                            }
                        }
                    }
                }

                if let entitlement = appState.entitlement, entitlement.canBuyDeviceAddon {
                    Button {
                        Task {
                            if let url = await appState.createDeviceAddonCheckout() {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if appState.isBillingBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text(appState.isBillingBusy ? "Открываем оплату..." : "Добавить устройство · \(deviceAddonPrice(entitlement)) / мес.")
                                .font(.system(size: 11, weight: .black))
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.vexProminentGlass)
                    .tint(Color.vexCyan)
                    .disabled(appState.isBillingBusy)
                }
            }
        }
    }

    private var accessTitle: String {
        guard appState.accessToken != nil else { return "Требуется вход" }
        guard let entitlement = appState.entitlement else { return "Проверяем" }
        if entitlement.hasPaidAccess {
            return entitlement.displayName ?? entitlement.subscriptionTitle ?? entitlement.tier?.capitalized ?? "Активна"
        }
        return "Нет активной подписки"
    }

    private var accessSubtitle: String? {
        guard let entitlement = appState.entitlement else {
            return appState.accessToken == nil ? nil : "Данные обновятся автоматически"
        }
        if let remaining = entitlement.remainingText, !remaining.isEmpty {
            return remaining
        }
        if let periodEnd = entitlement.currentPeriodEnd, !periodEnd.isEmpty {
            return "Оплачен до \(periodEnd)"
        }
        return entitlement.hasPaidAccess ? "VPN-доступ активен" : "Оформите подписку для VPN-доступа"
    }

    private var accessBadgeText: String {
        guard appState.accessToken != nil else { return "Нет" }
        guard let entitlement = appState.entitlement else { return "Проверка" }
        return entitlement.hasPaidAccess ? "Активен" : "Нет"
    }

    private var accessBadgeTone: VEXStatusBadge.Tone {
        guard appState.accessToken != nil else { return .neutral }
        guard let entitlement = appState.entitlement else { return .neutral }
        return entitlement.hasPaidAccess ? .good : .warning
    }

    private var deviceLimitSubtitle: String {
        guard let entitlement = appState.entitlement, entitlement.deviceLimit > 0 else {
            return "Лимит появится после обновления подписки"
        }
        let addonSlots = entitlement.addonDeviceSlots ?? appState.deviceAddons
            .filter { $0.status.lowercased() == "active" }
            .reduce(0) { $0 + $1.quantity }
        if addonSlots > 0 {
            return "Свободно \(entitlement.remainingDeviceSlots) · дополнительных мест: \(addonSlots)"
        }
        return "Свободно мест: \(entitlement.remainingDeviceSlots)"
    }

    private func deviceAddonPrice(_ entitlement: Entitlement) -> String {
        guard let amount = entitlement.deviceAddonPriceMinor else { return "ещё 1 место" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .currency
        formatter.currencyCode = (entitlement.deviceAddonCurrency ?? "RUB").uppercased()
        formatter.maximumFractionDigits = amount % 100 == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: Double(amount) / 100.0)) ?? "\(amount / 100) ₽"
    }

    private func deviceIcon(for device: VpnDevice) -> String {
        switch device.platform?.lowercased() {
        case "macos": return "desktopcomputer"
        case "ios": return "iphone"
        case "android": return "smartphone"
        case "windows": return "pc"
        default: return "laptopcomputer"
        }
    }

    private func deviceStatusText(_ device: VpnDevice) -> String {
        let platform = device.platform?.uppercased() ?? "VEX"
        let status: String
        switch device.status.lowercased() {
        case "active", "online", "connected": status = "активно"
        case "revoked", "disabled": status = "отключено"
        default: status = device.status.isEmpty ? "зарегистрировано" : device.status
        }
        return "\(platform) · \(status)"
    }
}

private struct AccountHero: View {
    let accountTitle: String
    let planTitle: String
    let accessSubtitle: String?
    let badgeText: String
    let badgeTone: VEXStatusBadge.Tone
    let hasPaidAccess: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(initials)
                .font(.system(size: 19, weight: .black, design: .rounded))
                .foregroundStyle(Color.vexCyanLight)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(accountTitle)
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .foregroundStyle(Color.vexText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(planTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(hasPaidAccess ? Color.vexCyanLight : Color.vexSecondaryText)
                if let accessSubtitle, !accessSubtitle.isEmpty {
                    Text(accessSubtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.vexMuted)
                        .lineLimit(1)
                }
            }

            Spacer()
            VEXStatusBadge(text: badgeText, tone: badgeTone)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }

    private var initials: String {
        let name = accountTitle.split(separator: "@").first.map(String.init) ?? accountTitle
        let pieces = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = pieces.prefix(2).compactMap(\.first)
        let result = String(letters).uppercased()
        return result.isEmpty ? "V" : result
    }
}

private struct PaymentHistoryRow: View {
    let payment: BillingPayment
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(BillingPresentation.customerPaymentURL(for: payment))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.vexCyan)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.vexCyan.opacity(0.10)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(amountText)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color.vexText)
                        VEXStatusBadge(text: statusText, tone: statusTone)
                    }
                    Text(BillingPresentation.planName(for: payment.planId))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(dateText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.vexMuted)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isHovered ? Color.vexCyanLight : Color.vexMuted)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.045) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .help("Открыть оплату в кабинете VEX")
        .accessibilityLabel(
            "\(amountText), \(BillingPresentation.planName(for: payment.planId)), \(statusText), \(dateText)"
        )
        .accessibilityHint("Открыть оплату в кабинете VEX")
    }

    private var amountText: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .currency
        formatter.currencyCode = payment.currency.uppercased()
        formatter.maximumFractionDigits = payment.amountMinor % 100 == 0 ? 0 : 2
        let value = Double(payment.amountMinor) / 100.0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value)) \(payment.currency)"
    }

    private var statusText: String {
        switch payment.status.lowercased() {
        case "paid", "succeeded", "success", "completed", "manual": return "Оплачено"
        case "pending", "open": return "Ожидает"
        case "refunded": return "Возврат"
        case "failed", "declined": return "Ошибка"
        default: return payment.status.isEmpty ? "Статус" : payment.status
        }
    }

    private var statusTone: VEXStatusBadge.Tone {
        switch payment.status.lowercased() {
        case "paid", "succeeded", "success", "completed", "manual": return .good
        case "failed", "declined", "refunded": return .warning
        default: return .neutral
        }
    }

    private var iconName: String {
        switch payment.status.lowercased() {
        case "failed", "declined": return "exclamationmark.triangle.fill"
        case "refunded": return "arrow.uturn.backward.circle.fill"
        default: return "creditcard.fill"
        }
    }

    private var dateText: String {
        DateFormatter.vexShortDateTime(payment.paidAt ?? payment.createdAt) ?? "Дата"
    }
}

private struct EmptyPaymentHistory: View {
    var body: some View {
        HStack(spacing: 11) {
            PanelIcon(systemName: "tray", size: 36, iconSize: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text("Оплат пока нет")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.vexText)
                Text("Покупки и продления появятся здесь.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
            }
            Spacer()
        }
        .padding(11)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AccountSurfaceCard<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VEXFeatureSurface(accent: accent, cornerRadius: 16, contentPadding: 15) {
            content
        }
    }
}
