import Foundation

enum BillingPresentation {
    static let billingDashboardURL = URL(string: "https://vexguard.app/dashboard")!

    static func customerPaymentURL(for payment: BillingPayment) -> URL {
        billingDashboardURL
            .appendingPathComponent("payments", isDirectory: true)
            .appendingPathComponent(payment.id, isDirectory: true)
            .appendingPathComponent("receipt", isDirectory: false)
    }

    static func planName(for planId: String?) -> String {
        guard let planId, !planId.isEmpty else { return "Подписка VEX" }
        let normalized = planId.lowercased()

        let tier: String
        if normalized.contains("business") {
            tier = "Бизнес"
        } else if normalized.contains("family") || normalized.contains("team") {
            tier = "Team"
        } else if normalized.contains("pro") {
            tier = "Pro"
        } else if normalized.contains("basic") {
            tier = "Базовый"
        } else {
            tier = planId
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }

        let period: String?
        if normalized.contains("semiannual") {
            period = "6 месяцев"
        } else if normalized.contains("quarter") {
            period = "3 месяца"
        } else if normalized.contains("annual") || normalized.contains("year") {
            period = "год"
        } else if normalized.contains("month") {
            period = "месяц"
        } else {
            period = nil
        }

        return period.map { "\(tier) · \($0)" } ?? tier
    }
}

extension DateFormatter {
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
