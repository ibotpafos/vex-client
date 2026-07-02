import SwiftUI

struct HeaderView: View {
    @EnvironmentObject private var appState: VEXAppState

    var body: some View {
        HStack(spacing: 12) {
            BundleImage(name: "vex-logo-header")
                .frame(width: 54, height: 54)

            HStack(spacing: 10) {
                Text("VEX")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(Color.vexText)

                VEXStatusBadge(text: badgeText, tone: badgeTone)
            }

            Spacer()
        }
    }

    private var badgeText: String {
        guard appState.isAuthenticated else { return "Native" }
        guard let entitlement = appState.entitlement else { return "..." }
        if entitlement.hasPaidAccess {
            return entitlement.tier?.capitalized ?? entitlement.displayName ?? "Team"
        }
        return "Free"
    }

    private var badgeTone: VEXStatusBadge.Tone {
        guard appState.isAuthenticated else { return .neutral }
        guard let entitlement = appState.entitlement else { return .neutral }
        return entitlement.hasPaidAccess ? .good : .warning
    }
}
