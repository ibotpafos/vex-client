import Foundation

struct BillingService {
    private let fallbackPlans = [
        BillingPlan(id: "basic_monthly", name: "Базовый", provider: "platega", amountCents: 19900, currency: "RUB", interval: "monthly", deviceLimit: 1, tier: "basic", status: "active"),
        BillingPlan(id: "pro_monthly", name: "Pro", provider: "platega", amountCents: 29900, currency: "RUB", interval: "monthly", deviceLimit: 3, tier: "pro", status: "active"),
        BillingPlan(id: "pro_quarterly", name: "Pro", provider: "platega", amountCents: 80730, currency: "RUB", interval: "quarterly", deviceLimit: 3, tier: "pro", status: "active"),
        BillingPlan(id: "pro_semiannual", name: "Pro", provider: "platega", amountCents: 152490, currency: "RUB", interval: "semiannual", deviceLimit: 3, tier: "pro", status: "active"),
        BillingPlan(id: "pro_annual", name: "Pro", provider: "platega", amountCents: 269100, currency: "RUB", interval: "annual", deviceLimit: 3, tier: "pro", status: "active"),
    ]

    func buildSummary(plans: [BillingPlan], entitlement: Entitlement?) -> BillingSummary {
        let sourcePlans = plans.isEmpty ? fallbackPlans : plans
        let activePlans = sourcePlans
            .filter { $0.status == "active" }
            .sorted(by: planComesBefore)

        let currentPlan = currentBillingPlan(plans: activePlans, entitlement: entitlement)
        let hasActiveEntitlement = entitlement?.hasPaidAccess == true
        let status: BillingEntitlementStatus = entitlement == nil ? .unknown : (hasActiveEntitlement ? .active : .inactive)

        let selectablePlans = activePlans.filter { ["basic", "pro"].contains($0.tier.lowercased()) }
        let options = selectablePlans.compactMap { option(for: $0, currentPlan: currentPlan, status: status, hasActiveEntitlement: hasActiveEntitlement) }
        let currentOption = currentPlan.flatMap {
            option(for: $0, currentPlan: currentPlan, status: status, hasActiveEntitlement: hasActiveEntitlement)
        }
        let families = ["basic", "pro"].compactMap { tier -> BillingPlanFamily? in
            let familyPlans = options
                .filter { $0.tier == tier }
                .sorted { $0.months == $1.months ? $0.amountCents < $1.amountCents : $0.months < $1.months }
            guard let first = familyPlans.first else { return nil }
            return BillingPlanFamily(
                tier: tier,
                name: tier == "basic" ? "Базовый" : "Pro",
                deviceLimit: first.deviceLimit,
                plans: familyPlans
            )
        }

        return BillingSummary(
            title: status == .active ? "Управление подпиской" : (status == .unknown ? "Проверяем подписку" : "Выберите подписку"),
            subtitle: subtitle(status: status, currentPlan: currentPlan),
            emptyMessage: "Активные тарифы сейчас недоступны.",
            entitlementStatus: status,
            currentPlan: currentOption,
            currentPeriodEnd: entitlement?.currentPeriodEnd,
            effectiveExpiresAt: entitlement?.effectiveExpiresAt,
            remainingText: entitlement?.remainingText,
            status: entitlement?.status,
            plans: options,
            families: families
        )
    }

    private func option(
        for plan: BillingPlan,
        currentPlan: BillingPlan?,
        status: BillingEntitlementStatus,
        hasActiveEntitlement: Bool
    ) -> BillingPlanOption? {
        guard let months = intervalMonths(plan.interval) else { return nil }
        let current = currentPlan.map { billingPlansMatch(plan, $0) } ?? false
        return BillingPlanOption(
            id: plan.id,
            provider: plan.provider ?? "platega",
            tier: plan.tier.lowercased(),
            name: plan.name ?? planLabel(plan.tier, plan.id),
            meta: "\(planPrice(plan)) · \(deviceLimitText(plan.deviceLimit))",
            action: status == .unknown ? "Проверяем" : planActionText(plan: plan, currentPlan: currentPlan, hasCurrent: hasActiveEntitlement),
            current: current,
            disabled: status == .unknown,
            months: months,
            amountCents: plan.amountCents,
            currency: plan.currency,
            deviceLimit: plan.deviceLimit
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
        if !planId.isEmpty, let exactPlan = plans.first(where: { $0.id.lowercased() == planId }) {
            return exactPlan
        }

        guard !tier.isEmpty else { return nil }
        let tierPlans = plans.filter { !$0.tier.isEmpty && $0.tier.lowercased() == tier }
        return tierPlans.count == 1 ? tierPlans.first : nil
    }

    private func billingPlansMatch(_ plan: BillingPlan, _ currentPlan: BillingPlan) -> Bool {
        plan.id == currentPlan.id
    }

    private func planActionText(plan: BillingPlan, currentPlan: BillingPlan?, hasCurrent: Bool) -> String {
        if let currentPlan, billingPlansMatch(plan, currentPlan) {
            return "Продлить"
        }
        if !hasCurrent {
            return "Купить"
        }
        guard currentPlan != nil else { return "Сменить" }
        return "Перейти"
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
        case "quarter", "quarterly":
            return "3 мес."
        case "semiannual", "semi-annual", "half-year", "half_year":
            return "6 мес."
        case "week", "weekly":
            return "нед."
        case "day", "daily":
            return "день"
        default:
            return "мес."
        }
    }

    private func intervalMonths(_ interval: String) -> Int? {
        switch interval.lowercased() {
        case "month", "monthly":
            return 1
        case "quarter", "quarterly":
            return 3
        case "semiannual", "semi-annual", "half-year", "half_year":
            return 6
        case "year", "yearly", "annual":
            return 12
        default:
            return nil
        }
    }

    private func planComesBefore(_ left: BillingPlan, _ right: BillingPlan) -> Bool {
        let leftRank = planRank(left)
        let rightRank = planRank(right)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        if left.amountCents != right.amountCents {
            return left.amountCents < right.amountCents
        }
        return left.id < right.id
    }

    private func planRank(_ plan: BillingPlan) -> Int {
        let tierRank: Int
        switch plan.tier.lowercased() {
        case "basic":
            tierRank = 0
        case "pro":
            tierRank = 10
        case "team", "family":
            tierRank = 20
        default:
            tierRank = 30
        }

        let intervalRank: Int
        switch plan.interval.lowercased() {
        case "month", "monthly":
            intervalRank = 0
        case "quarter", "quarterly":
            intervalRank = 1
        case "semiannual", "semi-annual", "half-year", "half_year":
            intervalRank = 2
        case "year", "yearly", "annual":
            intervalRank = 3
        default:
            intervalRank = 4
        }
        return tierRank + intervalRank
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
