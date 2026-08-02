import SwiftUI

enum VEXLaunchTiming {
    static func minimumDisplayNanoseconds(reduceMotion: Bool) -> UInt64 {
        reduceMotion ? 80_000_000 : 1_050_000_000
    }
}

struct VEXLaunchContainer: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isReady = false
    @State private var didStart = false

    let skipAnimation: Bool
    let start: @MainActor () async -> Void

    var body: some View {
        ZStack {
            if skipAnimation || isReady {
                ContentView()
                    .transition(.opacity)
            } else {
                VEXLaunchView()
                    .transition(.opacity.combined(with: .scale(scale: 1.025)))
            }
        }
        .task {
            await runStartup()
        }
    }

    @MainActor
    private func runStartup() async {
        guard !didStart else { return }
        didStart = true

        let minimumNanoseconds = VEXLaunchTiming.minimumDisplayNanoseconds(
            reduceMotion: accessibilityReduceMotion
        )
        let startupTask = Task {
            await start()
        }
        defer {
            startupTask.cancel()
        }

        try? await Task.sleep(nanoseconds: minimumNanoseconds)
        guard !Task.isCancelled else { return }

        withAnimation(
            accessibilityReduceMotion
                ? .linear(duration: 0.01)
                : .easeOut(duration: 0.32)
        ) {
            isReady = true
        }
        await startupTask.value
    }
}

struct VEXLaunchView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var appeared: Bool

    init(appearedInitially: Bool = false) {
        _appeared = State(initialValue: appearedInitially)
    }

    var body: some View {
        ZStack {
            VEXBackground(selection: .home)

            WindowDragSurface()
                .accessibilityHidden(true)

            RadialGradient(
                colors: [
                    Color.vexCyan.opacity(0.16),
                    Color.vexCyan.opacity(0.035),
                    Color.clear,
                ],
                center: .center,
                startRadius: 18,
                endRadius: 310
            )
            .blur(radius: 16)

            TimelineView(.animation(
                minimumInterval: 1.0 / 30.0,
                paused: accessibilityReduceMotion
            )) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let orbit = accessibilityReduceMotion
                    ? 0.0
                    : seconds.truncatingRemainder(dividingBy: 6.0) / 6.0

                ZStack {
                    ForEach(0..<4, id: \.self) { index in
                        let phase = accessibilityReduceMotion
                            ? Double(index) * 0.16
                            : (seconds * 0.62 + Double(index) * 0.25)
                                .truncatingRemainder(dividingBy: 1.0)

                        Circle()
                            .stroke(
                                Color.vexCyan.opacity(0.23 * (1.0 - phase)),
                                lineWidth: index == 0 ? 1.5 : 1
                            )
                            .frame(width: 176, height: 176)
                            .scaleEffect(0.76 + phase * 1.18)
                    }

                    Circle()
                        .trim(from: 0.02, to: 0.18)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.vexCyan,
                                    Color.vexCyanLight,
                                    Color.vexCyan,
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                        )
                        .frame(width: 224, height: 224)
                        .rotationEffect(.degrees(orbit * 360.0 - 90.0))
                        .shadow(color: Color.vexCyan.opacity(0.85), radius: 10)

                    launchCore(seconds: seconds)
                }
                .frame(width: 410, height: 410)
            }
            .allowsHitTesting(false)

            VStack(spacing: 7) {
                Text("Защищаем соединение")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.vexSubtext)

                Text("VEX подготавливает безопасный сеанс")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vexSecondaryText.opacity(0.78))
            }
            .offset(y: 152)
            .opacity(appeared ? 1 : 0)
            .allowsHitTesting(false)
        }
        .clipped()
        .onAppear {
            withAnimation(
                accessibilityReduceMotion
                    ? .linear(duration: 0.01)
                    : .easeOut(duration: 0.5).delay(0.2)
            ) {
                appeared = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("VEX запускается. Защищаем соединение.")
    }

    private func launchCore(seconds: TimeInterval) -> some View {
        let breathe = accessibilityReduceMotion
            ? 1.0
            : 1.0 + sin(seconds * 3.2) * 0.025

        return ZStack {
            Circle()
                .fill(Color.vexBackground.opacity(0.94))
                .frame(width: 164, height: 164)
                .overlay {
                    Circle()
                        .stroke(Color.vexCyan.opacity(0.78), lineWidth: 3)
                }
                .shadow(color: Color.vexCyan.opacity(0.36), radius: 24)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("VEX")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .tracking(-2.2)

                Circle()
                    .fill(Color.vexCyanLight)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.vexCyan, radius: 8)
            }
            .foregroundStyle(Color.vexCyanLight)
        }
        .scaleEffect((appeared ? 1 : 0.78) * breathe)
        .opacity(appeared ? 1 : 0)
        .animation(
            accessibilityReduceMotion
                ? .linear(duration: 0.01)
                : .spring(response: 0.68, dampingFraction: 0.78),
            value: appeared
        )
    }
}
