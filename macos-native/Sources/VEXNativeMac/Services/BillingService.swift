import Foundation

struct BillingService {
    private let fallbackPlans = [
        BillingPlan(id: "basic_monthly", name: "Базовый", provider: "platega", amountCents: 19900, currency: "RUB", interval: "monthly", deviceLimit: 1, tier: "basic", status: "active"),
        BillingPlan(id: "pro_monthly", name: "Pro", provider: "platega", amountCents: 49900, currency: "RUB", interval: "monthly", deviceLimit: 3, tier: "pro", status: "active"),
        BillingPlan(id: "family_monthly", name: "Team", provider: "platega", amountCents: 149900, currency: "RUB", interval: "monthly", deviceLimit: 10, tier: "team", status: "active"),
    ]

    func buildSummary(plans: [BillingPlan], entitlement: Entitlement?) -> BillingSummary {
        let sourcePlans = plans.isEmpty ? fallbackPlans : plans
        let activePlans = sourcePlans
            .filter { $0.status == "active" }
            .sorted { left, right in
                if left.amountCents != right.amountCents {
                    return left.amountCents < right.amountCents
                }
                return left.id < right.id
            }

        let currentPlan = currentBillingPlan(plans: activePlans, entitlement: entitlement)
        let hasActiveEntitlement = entitlement?.hasPaidAccess == true
        let status: BillingEntitlementStatus = entitlement == nil ? .unknown : (hasActiveEntitlement ? .active : .inactive)

        let options = activePlans.map { plan in
            let current = currentPlan.map { billingPlansMatch(plan, $0) } ?? false
            return BillingPlanOption(
                id: plan.id,
                provider: plan.provider ?? "platega",
                name: plan.name ?? planLabel(plan.tier, plan.id),
                meta: "\(planPrice(plan)) · \(deviceLimitText(plan.deviceLimit))",
                action: status == .unknown ? "Проверяем" : planActionText(plan: plan, currentPlan: currentPlan, hasCurrent: hasActiveEntitlement),
                current: current,
                disabled: current || status == .unknown
            )
        }

        return BillingSummary(
            title: status == .active ? "Управление подпиской" : (status == .unknown ? "Проверяем подписку" : "Выберите подписку"),
            subtitle: subtitle(status: status, currentPlan: currentPlan),
            emptyMessage: "Активные тарифы сейчас недоступны.",
            entitlementStatus: status,
            currentPlan: options.first(where: \.current),
            currentPeriodEnd: entitlement?.currentPeriodEnd,
            effectiveExpiresAt: entitlement?.effectiveExpiresAt,
            remainingText: entitlement?.remainingText,
            status: entitlement?.status,
            plans: options
        )
    }

    private func subtitle(status: BillingEntitlementStatus, currentPlan: BillingPlan?) -> String {
        switch status {
        case .active:
            return currentPlan == nil ? "Подписка активна. Можно перейти на один из доступных тарифов." : "Текущий тариф отмечен. Можно перейти на другой."
        case .unknown:
            return "Не удалось подтвердить текущий тариф. Обновите экран через несколько секунд."
        case .inactive:
            return "Оплата откроется в браузере."
        }
    }

    private func currentBillingPlan(plans: [BillingPlan], entitlement: Entitlement?) -> BillingPlan? {
        guard entitlement?.hasPaidAccess == true else { return nil }
        let planId = (entitlement?.planId ?? "").lowercased()
        let tier = (entitlement?.tier ?? "").lowercased()
        return plans.first { $0.id.lowercased() == planId }
            ?? plans.first { !$0.tier.isEmpty && $0.tier.lowercased() == tier }
            ?? plans.first { !tier.isEmpty && $0.id.lowercased().contains(tier) }
    }

    private func billingPlansMatch(_ plan: BillingPlan, _ currentPlan: BillingPlan) -> Bool {
        plan.id == currentPlan.id || (!plan.tier.isEmpty && plan.tier == currentPlan.tier)
    }

    private func planActionText(plan: BillingPlan, currentPlan: BillingPlan?, hasCurrent: Bool) -> String {
        if let currentPlan, billingPlansMatch(plan, currentPlan) {
            return "Текущий"
        }
        if !hasCurrent {
            return "Купить"
        }
        guard let currentPlan else { return "Сменить" }
        if plan.amountCents > currentPlan.amountCents { return "Обновить" }
        if plan.amountCents < currentPlan.amountCents { return "Перейти" }
        return "Сменить"
    }

    private func planPrice(_ plan: BillingPlan) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .currency
        formatter.currencyCode = plan.currency.uppercased()
        formatter.maximumFractionDigits = plan.amountCents % 100 == 0 ? 0 : 2
        let value = Double(plan.amountCents) / 100.0
        let price = formatter.string(from: NSNumber(value: value)) ?? "\(Int(value)) \(plan.currency)"
        return "\(price)/\(intervalText(plan.interval))"
    }

    private func intervalText(_ interval: String) -> String {
        switch interval.lowercased() {
        case "year", "yearly", "annual":
            return "год"
        case "week", "weekly":
            return "нед."
        case "day", "daily":
            return "день"
        default:
            return "мес."
        }
    }

    private func deviceLimitText(_ limit: Int) -> String {
        let safeLimit = max(0, limit)
        let mod10 = safeLimit % 10
        let mod100 = safeLimit % 100
        if mod10 == 1 && mod100 != 11 {
            return "\(safeLimit) устройство"
        }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            return "\(safeLimit) устройства"
        }
        return "\(safeLimit) устройств"
    }

    private func planLabel(_ values: String...) -> String {
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
            if !normalized.isEmpty {
                return normalized.prefix(1).uppercased() + normalized.dropFirst()
            }
        }
        return "Pro"
    }
}
