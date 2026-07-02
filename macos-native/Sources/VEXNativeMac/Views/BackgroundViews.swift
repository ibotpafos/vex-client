import SwiftUI

struct VEXBackground: View {
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

                RadialGradient(
                    colors: [
                        Color.vexCyan.opacity(0.18),
                        Color.vexCyan.opacity(0.04),
                        Color.clear
                    ],
                    center: .topTrailing,
                    startRadius: 24,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )
                .allowsHitTesting(false)

                RadialGradient(
                    colors: [
                        Color.vexCyanLight.opacity(0.10),
                        Color.clear
                    ],
                    center: .bottomLeading,
                    startRadius: 18,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.58
                )
                .allowsHitTesting(false)

                LinearGradient(
                    colors: [
                        Color.vexCyan.opacity(0.06),
                        Color.clear,
                        Color.vexBackground.opacity(0.28)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
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
