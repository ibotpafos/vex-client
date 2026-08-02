import AppKit
import SwiftUI

struct AccountPanel: View {
    @EnvironmentObject private var appState: VEXAppState
    @State private var selectedFamilyID = ""
    @State private var selectedPlanIndexes: [String: Int] = [:]
    @State private var didChooseSubscriptionManually = false

    var body: some View {
        VStack(spacing: 12) {
            accountSummary

            if appState.accessToken != nil {
                subscriptionPicker
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
            synchronizeSelection(with: appState.billingSummary)
        }
        .onChange(of: appState.billingSummary) { _, summary in
            synchronizeSelection(with: summary)
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
                        Text("Выберите тариф или продлите текущий")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.vexSecondaryText)
                    }
                    Spacer()
                    if appState.isBillingBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await appState.refreshBilling() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.vexSecondaryText)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Обновить данные подписки")
                        .help("Обновить данные подписки")
                    }
                }

                if !billingFamilies.isEmpty {
                    HStack(spacing: 9) {
                        ForEach(billingFamilies) { family in
                            BillingFamilyCard(
                                family: family,
                                selected: family.id == selectedFamily?.id,
                                busy: appState.isBillingBusy
                            ) {
                                didChooseSubscriptionManually = true
                                selectedFamilyID = family.id
                            }
                        }
                    }

                    if let family = selectedFamily, let plan = selectedPlan {
                        BillingDurationSelector(
                            family: family,
                            selectedIndex: selectedPlanIndex,
                            busy: appState.isBillingBusy,
                            onSelect: { index in
                                didChooseSubscriptionManually = true
                                selectedPlanIndexes = selectedPlanIndexes.merging([family.id: index]) {
                                    _, newValue in newValue
                                }
                            }
                        )

                        Button {
                            Task { await appState.startCheckout(for: plan) }
                        } label: {
                            HStack(spacing: 8) {
                                if appState.isBillingBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "creditcard")
                                }
                                Text(appState.isBillingBusy ? "Открываем Platega…" : "Перейти к оплате · \(billingPrice(plan))")
                                    .font(.system(size: 12, weight: .black))
                            }
                            .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.vexProminentGlass)
                        .tint(Color.vexCyan)
                        .disabled(plan.disabled || appState.isBillingBusy)
                    }
                } else {
                    Text(appState.billingSummary?.emptyMessage ?? "Загружаем доступные тарифы…")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                }

                if canCancelSubscription {
                    HStack {
                        Text("Автопродление можно отключить в любой момент.")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.vexMuted)
                        Spacer()
                        Button("Отключить") {
                            Task { await appState.cancelSubscription() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .disabled(appState.isBillingBusy)
                    }
                }

                if let error = visibleBillingError {
                    Text(error)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                        .textSelection(.enabled)
                }
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

    private var canCancelSubscription: Bool {
        guard appState.billingSummary?.entitlementStatus == .active else { return false }
        return (appState.billingSummary?.status ?? "").lowercased() != "canceled"
    }

    private var visibleBillingError: String? {
        guard let error = appState.billingError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty else {
            return nil
        }
        return error.contains("404 page not found") ? nil : error
    }

    private var billingFamilies: [BillingPlanFamily] {
        appState.billingSummary?.families ?? []
    }

    private var selectedFamily: BillingPlanFamily? {
        billingFamilies.first(where: { $0.id == selectedFamilyID }) ?? billingFamilies.first
    }

    private var selectedPlanIndex: Int {
        guard let family = selectedFamily else { return 0 }
        return min(max(selectedPlanIndexes[family.id] ?? 0, 0), max(0, family.plans.count - 1))
    }

    private var selectedPlan: BillingPlanOption? {
        guard let family = selectedFamily, family.plans.indices.contains(selectedPlanIndex) else { return nil }
        return family.plans[selectedPlanIndex]
    }

    private func billingPrice(_ plan: BillingPlanOption) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .currency
        formatter.currencyCode = plan.currency.uppercased()
        formatter.maximumFractionDigits = plan.amountCents % 100 == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: Double(plan.amountCents) / 100.0))
            ?? "\(plan.amountCents / 100) \(plan.currency)"
    }

    private func synchronizeSelection(with summary: BillingSummary?) {
        guard !didChooseSubscriptionManually,
              let summary,
              let currentPlan = summary.currentPlan,
              let family = summary.families.first(where: {
                  $0.id.caseInsensitiveCompare(currentPlan.tier) == .orderedSame
                      || $0.plans.contains(where: { $0.id == currentPlan.id })
              }) else {
            return
        }

        selectedFamilyID = family.id
        guard let planIndex = family.plans.firstIndex(where: { plan in
            plan.id == currentPlan.id || plan.months == currentPlan.months
        }) else {
            return
        }
        selectedPlanIndexes = selectedPlanIndexes.merging([family.id: planIndex]) {
            _, newValue in newValue
        }
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

private struct BillingFamilyCard: View {
    let family: BillingPlanFamily
    let selected: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color.vexCyan)
                    }
                    Text(family.name)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color.vexText)
                        .lineLimit(1)
                    Spacer()
                }
                Text("до \(family.deviceLimit) \(deviceWord(family.deviceLimit))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(1)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.vexCyan.opacity(0.10) : Color.white.opacity(0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Color.vexCyan.opacity(0.46) : Color.white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func deviceWord(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "устройство" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "устройства" }
        return "устройств"
    }
}

private struct BillingDurationSelector: View {
    let family: BillingPlanFamily
    let selectedIndex: Int
    let busy: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Срок")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.vexMuted)
                        .textCase(.uppercase)
                    Text(durationText(selectedPlan.months))
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color.vexText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Цена с сервера")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.vexCyanLight.opacity(0.68))
                    Text(priceText(selectedPlan))
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color.vexCyanLight)
                }
            }

            Slider(
                value: Binding(
                    get: { Double(selectedIndex) },
                    set: { onSelect(Int($0.rounded())) }
                ),
                in: 0...Double(max(1, family.plans.count - 1)),
                step: 1
            )
            .tint(Color.vexCyan)
            .disabled(family.plans.count <= 1 || busy)
            .accessibilityLabel("Срок подписки \(family.name)")
            .accessibilityValue("\(durationText(selectedPlan.months)), \(priceText(selectedPlan))")

            HStack {
                ForEach(Array(family.plans.enumerated()), id: \.element.id) { index, plan in
                    Text("\(plan.months)")
                        .font(.system(size: 9, weight: index == selectedIndex ? .black : .bold))
                        .foregroundStyle(index == selectedIndex ? Color.vexCyanLight : Color.vexMuted)
                    if index < family.plans.count - 1 {
                        Spacer()
                    }
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.15))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var selectedPlan: BillingPlanOption {
        family.plans[min(max(selectedIndex, 0), family.plans.count - 1)]
    }

    private func durationText(_ months: Int) -> String {
        if months == 1 { return "1 месяц" }
        if (2...4).contains(months) { return "\(months) месяца" }
        return "\(months) месяцев"
    }

    private func priceText(_ plan: BillingPlanOption) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .currency
        formatter.currencyCode = plan.currency.uppercased()
        formatter.maximumFractionDigits = plan.amountCents % 100 == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: Double(plan.amountCents) / 100.0))
            ?? "\(plan.amountCents / 100) \(plan.currency)"
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
