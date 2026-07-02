import AppKit
import SwiftUI

struct SubscriptionPanel: View {
    @EnvironmentObject private var appState: VEXAppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VEXSheetScaffold(title: "Подписка", subtitle: appState.billingSummary?.subtitle ?? "Проверяем текущий тариф, управление и историю оплат.") {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 14) {
                        subscriptionOverview
                        managementActions
                        plansSection
                        paymentHistorySection

                        if let error = appState.billingError, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .task {
            await appState.refreshBilling()
        }
    }

    private var subscriptionOverview: some View {
        GlassPanel(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    PanelIcon(systemName: overviewIconName, size: 46, iconSize: 21)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(appState.billingSummary?.title ?? "Проверяем подписку")
                            .font(.system(size: 21, weight: .black))
                            .foregroundStyle(Color.vexText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                        Text(appState.billingSummary?.subtitle ?? "Проверяем текущий тариф, управление и историю оплат.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.vexSecondaryText)
                            .lineLimit(3)
                    }

                    Spacer(minLength: 10)
                    VEXStatusBadge(text: overviewStatusText, tone: overviewStatusTone)
                }

                Divider().overlay(Color.white.opacity(0.1))

                HStack(spacing: 10) {
                    BillingMetric(title: "Тариф", value: appState.billingSummary?.currentPlan?.name ?? "Не выбран")
                    BillingMetric(title: "Период", value: accessUntilText(appState.billingSummary))
                    BillingMetric(title: "Статус", value: localizedSubscriptionStatus(appState.billingSummary?.status))
                }
            }
        }
    }

    private var managementActions: some View {
        GlassPanel(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Управление")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.vexMuted)
                    .textCase(.uppercase)

                HStack(spacing: 10) {
                    if let currentPlan = appState.billingSummary?.currentPlan {
                        Button {
                            Task {
                                await appState.startCheckout(for: currentPlan)
                                dismiss()
                            }
                        } label: {
                            Label("Продлить", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.vexProminentGlass)
                        .tint(Color.vexCyan)
                    }

                    Button {
                        Task { await appState.openBillingPortal() }
                    } label: {
                        Label("Портал", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vexGlass)

                    Button {
                        Task { await appState.cancelSubscription() }
                    } label: {
                        Label(cancelButtonTitle, systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vexGlass)
                    .disabled(cancelDisabled)

                    Button {
                        Task { await appState.refreshBilling() }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vexGlass)
                }
                .disabled(appState.isBillingBusy)
            }
        }
    }

    private var plansSection: some View {
        GlassPanel(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Тарифы", subtitle: "Можно продлить, купить или перейти на другой план.")

                if appState.isBillingBusy && appState.billingSummary == nil {
                    ProgressView("Загружаем тарифы")
                        .controlSize(.regular)
                        .tint(Color.vexCyan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let plans = appState.billingSummary?.plans ?? []
                    if plans.isEmpty {
                        Text(appState.billingSummary?.emptyMessage ?? "Активные тарифы сейчас недоступны.")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.vexSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(plans) { plan in
                                BillingPlanRow(plan: plan, busy: appState.isBillingBusy) {
                                    Task {
                                        await appState.startCheckout(for: plan)
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var paymentHistorySection: some View {
        GlassPanel(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "История оплат", subtitle: "Последние операции, статусы и чеки.")

                if appState.isBillingBusy && appState.billingPayments.isEmpty {
                    ProgressView("Загружаем историю")
                        .controlSize(.small)
                        .tint(Color.vexCyan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if appState.billingPayments.isEmpty {
                    EmptyPaymentHistory()
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.billingPayments) { payment in
                            PaymentHistoryRow(payment: payment)
                        }
                    }
                }
            }
        }
    }

    private var overviewIconName: String {
        appState.billingSummary?.entitlementStatus == .active ? "checkmark.seal.fill" : "creditcard"
    }

    private var overviewStatusText: String {
        switch appState.billingSummary?.entitlementStatus {
        case .active:
            return "Активна"
        case .inactive:
            return "Нет доступа"
        default:
            return "Проверка"
        }
    }

    private var overviewStatusTone: VEXStatusBadge.Tone {
        switch appState.billingSummary?.entitlementStatus {
        case .active:
            return .good
        case .inactive:
            return .warning
        default:
            return .neutral
        }
    }

    private var cancelButtonTitle: String {
        cancelDisabled && (appState.billingSummary?.status ?? "").lowercased() == "canceled" ? "Отменена" : "Отменить"
    }

    private var cancelDisabled: Bool {
        guard appState.billingSummary?.entitlementStatus == .active else { return true }
        return (appState.billingSummary?.status ?? "").lowercased() == "canceled"
    }

    private func accessUntilText(_ summary: BillingSummary?) -> String {
        guard let summary else { return "Уточняется" }
        let value = summary.currentPeriodEnd ?? summary.effectiveExpiresAt
        guard let value, !value.isEmpty else { return "Уточняется" }
        return DateFormatter.vexShortDateTime(value) ?? value
    }

    private func localizedSubscriptionStatus(_ value: String?) -> String {
        switch (value ?? "").lowercased() {
        case "active", "trialing":
            return "Активна"
        case "canceled":
            return "Отменена"
        case "past_due", "unpaid":
            return "Нужна оплата"
        case "expired":
            return "Истекла"
        default:
            return appState.billingSummary?.entitlementStatus == .active ? "Активна" : "Не активна"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color.vexText)
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(2)
            }
            Spacer()
        }
    }
}

private struct BillingMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color.vexMuted)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.vexText)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct BillingPlanRow: View {
    let plan: BillingPlanOption
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PanelIcon(systemName: plan.current ? "checkmark.seal.fill" : "crown", size: 40, iconSize: 19)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.name)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color.vexText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if plan.current {
                            VEXStatusBadge(text: "Текущий", tone: .good)
                        }
                    }
                    Text(plan.meta)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(plan.action)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(plan.disabled ? Color.vexMuted : Color(red: 0.01, green: 0.07, blue: 0.08))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(plan.disabled ? Color.white.opacity(0.07) : Color.vexCyan))
            }
            .padding(12)
            .frame(minHeight: 66)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(plan.disabled || busy)
    }
}

struct PaymentHistoryRow: View {
    let payment: BillingPayment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.vexCyan)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.vexCyan.opacity(0.10)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(amountText)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color.vexText)
                        .lineLimit(1)
                    VEXStatusBadge(text: statusText, tone: statusTone)
                }
                Text(detailText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 6) {
                Text(dateText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.vexMuted)
                    .lineLimit(1)
                if let url = receiptURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Чек", systemImage: "doc.text.magnifyingglass")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.vexGlass)
                    .controlSize(.small)
                    .help("Открыть чек")
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
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

    private var detailText: String {
        let plan = payment.planId?.replacingOccurrences(of: "_", with: " ") ?? "Подписка"
        let provider = payment.provider.isEmpty ? "платеж" : payment.provider
        return "\(plan) · \(provider)"
    }

    private var statusText: String {
        switch payment.status.lowercased() {
        case "paid", "succeeded", "success", "completed", "manual":
            return "Оплачено"
        case "pending", "open":
            return "Ожидает"
        case "refunded":
            return "Возврат"
        case "failed", "declined":
            return "Ошибка"
        default:
            return payment.status.isEmpty ? "Статус" : payment.status
        }
    }

    private var statusTone: VEXStatusBadge.Tone {
        switch payment.status.lowercased() {
        case "paid", "succeeded", "success", "completed", "manual":
            return .good
        case "failed", "declined", "refunded":
            return .warning
        default:
            return .neutral
        }
    }

    private var iconName: String {
        switch payment.status.lowercased() {
        case "failed", "declined":
            return "exclamationmark.triangle.fill"
        case "refunded":
            return "arrow.uturn.backward.circle.fill"
        default:
            return "creditcard.fill"
        }
    }

    private var dateText: String {
        DateFormatter.vexShortDateTime(payment.paidAt ?? payment.createdAt) ?? "Дата"
    }

    private var receiptURL: URL? {
        guard let value = payment.receiptUrl, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: value)
    }
}

struct EmptyPaymentHistory: View {
    var body: some View {
        HStack(spacing: 12) {
            PanelIcon(systemName: "tray", size: 38, iconSize: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("Оплат пока нет")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color.vexText)
                Text("После покупки или продления платеж появится здесь.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .frame(minHeight: 64)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension DateFormatter {
    static func vexShortDateTime(_ value: String) -> String? {
        guard let date = Date.vexFlexibleISO8601Date(from: value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private extension Date {
    static func vexFlexibleISO8601Date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }

        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: trimmed)
    }
}
