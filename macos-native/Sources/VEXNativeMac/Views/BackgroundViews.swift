import SwiftUI

struct VEXBackground: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let selection: AppSection

    init(selection: AppSection = .home) {
        self.selection = selection
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color.vexBackground,
                        Color(red: 0.012, green: 0.071, blue: 0.082),
                        Color.vexBackground
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                AngularGradient(
                    colors: [
                        selection.accentColor.opacity(0.17),
                        Color.clear,
                        Color.vexCyanLight.opacity(0.07),
                        Color.clear,
                        selection.accentColor.opacity(0.12)
                    ],
                    center: .center
                )
                .scaleEffect(1.45)
                .rotationEffect(.degrees(22))
                .blur(radius: 72)
                .blendMode(.screen)

                RadialGradient(
                    colors: [
                        selection.accentColor.opacity(0.15),
                        selection.accentColor.opacity(0.035),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.78, y: 0.18),
                    startRadius: 20,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.66
                )

                RadialGradient(
                    colors: [
                        Color.vexCyanLight.opacity(0.075),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.16, y: 0.84),
                    startRadius: 16,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.54
                )

                LinearGradient(
                    colors: [
                        selection.accentColor.opacity(0.045),
                        Color.clear,
                        Color.vexBackground.opacity(0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .animation(
                accessibilityReduceMotion ? nil : .easeInOut(duration: 0.35),
                value: selection
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private extension AppSection {
    var accentColor: Color {
        switch self {
        case .home:
            return .vexCyan
        case .account:
            return Color(red: 0.42, green: 0.72, blue: 1.0)
        case .support:
            return Color(red: 0.25, green: 0.94, blue: 0.70)
        case .settings:
            return Color(red: 0.55, green: 0.62, blue: 1.0)
        }
    }
}

struct CircuitBackdrop: View {
    var body: some View {
        RadialGradient(
            colors: [
                Color.vexCyan.opacity(0.12),
                Color.clear
            ],
            center: .center,
            startRadius: 18,
            endRadius: 178
        )
        .allowsHitTesting(false)
    }
}
