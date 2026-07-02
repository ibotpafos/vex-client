import SwiftUI

struct AccountPanel: View {
    @EnvironmentObject private var appState: VEXAppState

    var body: some View {
        VStack(spacing: 14) {
            PageTitleBlock(
                title: "Аккаунт",
                subtitle: appState.accountTitle,
                trailing: AnyView(VEXStatusBadge(text: accessBadgeText, tone: accessBadgeTone))
            )

            accountSummary

            if appState.accessToken != nil {
                subscriptionManagement
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
        .padding(.top, 4)
        .padding(.bottom, 16)
        .task {
            await appState.refreshBilling()
        }
    }

    private var accountSummary: some View {
        CleanPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(accessTitle)
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(Color.vexText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                        if let accessSubtitle {
                            Text(accessSubtitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.vexSecondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: appState.entitlement?.hasPaidAccess == true ? "checkmark.seal.fill" : "person.crop.circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(appState.entitlement?.hasPaidAccess == true ? Color.vexCyan : Color.vexMuted)
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                HStack(spacing: 10) {
                    AccountFact(label: "Тариф", value: appState.billingSummary?.currentPlan?.name ?? accessTitle)
                    AccountFact(label: "Статус", value: accessBadgeText)
                }
            }
        }
    }

    private var subscriptionManagement: some View {
        CleanPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Подписка")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color.vexText)
                        Text(subscriptionSubtitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.vexSecondaryText)
                            .lineLimit(2)
                    }
                    Spacer()
                    VEXStatusBadge(text: appState.billingSummary?.currentPlan?.name ?? accessTitle, tone: .good)
                }

                HStack(spacing: 8) {
                    if let currentPlan = appState.billingSummary?.currentPlan {
                        Button {
                            Task { await appState.startCheckout(for: currentPlan) }
                        } label: {
                            Label("Продлить", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.vexProminentGlass)
                        .tint(Color.vexCyan)
                    }

                    Button {
                        Task { await appState.refreshBilling() }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .frame(width: 34)
                    }
                    .buttonStyle(.vexGlass)
                    .help("Обновить подписку")
                }
                .disabled(appState.isBillingBusy)

                if canCancelSubscription {
                    Button {
                        Task { await appState.cancelSubscription() }
                    } label: {
                        Text("Отменить автопродление")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vexGlass)
                    .disabled(appState.isBillingBusy)
                }

                if let error = visibleBillingError {
                    Text(error)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var paymentHistory: some View {
        CleanPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Оплаты")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color.vexText)
                    Spacer()
                    if appState.isBillingBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if appState.billingPayments.isEmpty {
                    EmptyPaymentHistory()
                } else {
                    VStack(spacing: 6) {
                        ForEach(appState.billingPayments.prefix(6)) { payment in
                            PaymentHistoryRow(payment: payment)
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
        guard let entitlement = appState.entitlement else { return appState.accessToken == nil ? nil : "Данные обновятся автоматически" }
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

    private var subscriptionSubtitle: String {
        appState.billingSummary?.subtitle ?? accessSubtitle ?? "Управление тарифом и платежами."
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
}

private struct AccountFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color.vexMuted)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.vexText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
