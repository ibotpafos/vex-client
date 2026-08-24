import SwiftUI

struct FocusPulseHero: View {
    let status: VpnStatus
    let requiresHelperInstall: Bool
    let installationPhase: VEXHelperInstallationPhase
    let isBusy: Bool
    let action: () -> Void

    @State private var rxSpeedSamples: [CGFloat] = []
    @State private var txSpeedSamples: [CGFloat] = []
    @State private var rxSpeedLevel: CGFloat = 0.2
    @State private var txPreviousBytes: UInt64?
    @State private var rxPreviousBytes: UInt64?

    // log scale keeps both idle (~0 B/s) and heavy (~MB/s) traffic readable
    private static func normalizedSpeed(_ delta: UInt64) -> CGFloat {
        CGFloat(min(1, max(0.04, log10(Double(delta) + 1) / 7)))
    }

    private func recordRxSample() {
        guard let previous = rxPreviousBytes else {
            rxPreviousBytes = status.rxBytes
            return
        }
        let delta = status.rxBytes >= previous ? status.rxBytes - previous : 0
        rxPreviousBytes = status.rxBytes
        let level = Self.normalizedSpeed(delta)
        rxSpeedLevel = level
        withAnimation(.smooth(duration: 0.55)) {
            rxSpeedSamples.append(level)
            if rxSpeedSamples.count > 12 { rxSpeedSamples.removeFirst(rxSpeedSamples.count - 12) }
        }
    }

    private func recordTxSample() {
        guard let previous = txPreviousBytes else {
            txPreviousBytes = status.txBytes
            return
        }
        let delta = status.txBytes >= previous ? status.txBytes - previous : 0
        txPreviousBytes = status.txBytes
        let level = Self.normalizedSpeed(delta)
        withAnimation(.smooth(duration: 0.55)) {
            txSpeedSamples.append(level)
            if txSpeedSamples.count > 12 { txSpeedSamples.removeFirst(txSpeedSamples.count - 12) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            FocusPulseTrafficCard(
                title: "Получено",
                bytes: status.rxBytes,
                systemName: "arrow.down",
                samples: rxSpeedSamples
            )

            Spacer(minLength: 36)

            FocusPulsePowerControl(
                status: status,
                requiresHelperInstall: requiresHelperInstall,
                installationPhase: installationPhase,
                isBusy: isBusy,
                rxLevel: rxSpeedLevel,
                action: action
            )
            .frame(width: 244)
            .offset(y: 14)

            Spacer(minLength: 36)

            FocusPulseTrafficCard(
                title: "Отправлено",
                bytes: status.txBytes,
                systemName: "arrow.up",
                samples: txSpeedSamples
            )
        }
        .frame(maxWidth: 752)
        .frame(maxWidth: .infinity)
        .frame(height: 252)
        .onChange(of: status.rxBytes, initial: true) { _, _ in recordRxSample() }
        .onChange(of: status.txBytes, initial: true) { _, _ in recordTxSample() }
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        status.isUsableConnectedStatus ? Color.vexCyanLight : Color.vexCyan
    }
}

private struct FocusPulseWaves: View {
    let tint: Color
    let isConnected: Bool
    let trafficLevel: CGFloat

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private enum RingPhase {
        case rest, rise, peak, settle
    }

    private static let phases: [RingPhase] = [.rest, .rise, .peak, .settle]

    private func scale(for phase: RingPhase, index: Int) -> CGFloat {
        let base = 1.0 + CGFloat(index) * 0.012
        let trafficBoost = isConnected ? trafficLevel * 0.10 : 0
        switch phase {
        case .rest: return base
        case .rise: return base + 0.02 + trafficBoost * 0.5
        case .peak: return base + 0.05 + trafficBoost
        case .settle: return base + 0.01
        }
    }

    private func opacity(for phase: RingPhase, index: Int) -> Double {
        let fade = max(0.028, (isConnected ? 0.20 : 0.13) - Double(index) * 0.024)
        let boost = isConnected ? Double(trafficLevel) * 0.12 : 0
        switch phase {
        case .rest: return fade
        case .rise: return fade + 0.03 + boost * 0.5
        case .peak: return fade + 0.06 + boost
        case .settle: return fade + 0.015
        }
    }

    private func animation(for phase: RingPhase) -> Animation? {
        guard !accessibilityReduceMotion else { return nil }
        switch phase {
        case .rest: return .easeOut(duration: isConnected ? 1.1 : 2.2)
        case .rise: return .easeInOut(duration: 0.5)
        case .peak: return .easeInOut(duration: 0.7)
        case .settle: return .easeIn(duration: 0.45)
        }
    }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    tint.opacity(isConnected ? 0.20 : 0.13),
                    tint.opacity(0.045),
                    Color.clear,
                ],
                center: .center,
                startRadius: 12,
                endRadius: 250
            )

            ForEach(0..<6, id: \.self) { index in
                orbitRing(index: index)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func orbitRing(index: Int) -> some View {
        let diameter = 176 + CGFloat(index) * 46
        if accessibilityReduceMotion {
            Circle()
                .stroke(
                    tint.opacity(max(0.028, (isConnected ? 0.21 : 0.14) - Double(index) * 0.026)),
                    lineWidth: index == 0 ? 1.4 : 1
                )
                .frame(width: diameter, height: diameter)
        } else {
            PhaseAnimator(Self.phases) { phase in
                Circle()
                    .stroke(tint.opacity(opacity(for: phase, index: index)), lineWidth: index == 0 ? 1.4 : 1)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(scale(for: phase, index: index))
            } animation: { phase in
                animation(for: phase)
            }
        }
    }
}

private struct FocusPulsePowerControl: View {
    let status: VpnStatus
    let requiresHelperInstall: Bool
    let installationPhase: VEXHelperInstallationPhase
    let isBusy: Bool
    let rxLevel: CGFloat
    let action: () -> Void

    @State private var isPowerHovered = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.13, green: 0.19, blue: 0.20),
                                    Color(red: 0.014, green: 0.040, blue: 0.045),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.11), lineWidth: 1)
                                .padding(6)
                        }
                        .overlay {
                            Circle()
                                .stroke(tint, lineWidth: 4.5)
                                .shadow(color: tint.opacity(0.78), radius: 13)
                                .padding(10)
                        }
                        .shadow(color: Color.black.opacity(0.50), radius: 21, y: 10)

                    Image(systemName: "power")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(tint)
                        .opacity(installationPhase.isActive ? 0 : (isBusy ? 0.72 : 1))
                        .scaleEffect(isBusy ? 0.94 : 1)
                        .shadow(color: tint.opacity(0.62), radius: 9)

                    if installationPhase.isActive {
                        HelperInstallProgressRing()
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 152, height: 152)
                .contentShape(Circle())
                .animation(.snappy(duration: 0.16), value: status.state)
                .animation(.snappy(duration: 0.16), value: isBusy)
            }
            .buttonStyle(.plain)
            .background(alignment: .center) {
                FocusPulseWaves(
                    tint: tint,
                    isConnected: status.isUsableConnectedStatus,
                    trafficLevel: rxLevel
                )
                .frame(width: 470, height: 252)
            }
            .scaleEffect(isPowerHovered ? 1.035 : 1)
            .shadow(
                color: tint.opacity(isPowerHovered ? 0.34 : 0),
                radius: isPowerHovered ? 24 : 0
            )
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.24)) {
                    isPowerHovered = hovering
                }
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(installationDetail)
            .disabled(isBusy || installationPhase.isActive)

            VStack(spacing: 2) {
                Text(
                    installationTitle
                )
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.vexText)

                Text(
                    installationDetail
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.vexSecondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 232)
            }
        }
    }

    private var installationTitle: String {
        if installationPhase != .idle {
            return installationPhase.title
        }
        return FocusPulsePresentation.connectionTitle(
            status: status.state,
            requiresHelperInstall: requiresHelperInstall
        )
    }

    private var installationDetail: String {
        if installationPhase != .idle {
            return installationPhase.detail
        }
        return FocusPulsePresentation.connectionDetail(
            status: status.state,
            requiresHelperInstall: requiresHelperInstall
        )
    }

    private var tint: Color {
        status.isUsableConnectedStatus ? Color.vexCyanLight : Color.vexCyan
    }

    private var accessibilityLabel: String {
        if requiresHelperInstall {
            return "Установить системный компонент VEX"
        }
        return status.isUsableConnectedStatus ? "Отключить VPN" : "Подключить VPN"
    }
}

private struct HelperInstallProgressRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let rotation = Angle.degrees(elapsed.truncatingRemainder(dividingBy: 1.15) / 1.15 * 360)

            ZStack {
                Circle()
                    .stroke(Color.vexCyan.opacity(0.16), lineWidth: 3)
                    .frame(width: 66, height: 66)

                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.vexCyan.opacity(0.18),
                                Color.vexCyan,
                                Color.vexCyanLight,
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 66, height: 66)
                    .rotationEffect(rotation)
                    .shadow(color: Color.vexCyan.opacity(0.72), radius: 8)

                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.vexCyanLight)
                    .shadow(color: Color.vexCyan.opacity(0.62), radius: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FocusPulseTrafficCard: View {
    let title: String
    let bytes: UInt64
    let systemName: String
    let samples: [CGFloat]

    @State private var history: [CGFloat] = []
    @State private var previousBytes: UInt64?
    @State private var lastSampleAt = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.vexCyan)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.vexSecondaryText)
                    Text(FocusPulsePresentation.formatBytes(bytes))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.vexText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }
            }

            MiniTrafficSparkline(samples: renderedSamples)
                .frame(height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 136, height: 78, alignment: .leading)
        .onChange(of: bytes, initial: true) { _, newValue in
            updateTrafficHistory(with: newValue)
        }
    }

    private var renderedSamples: [CGFloat] {
        history.isEmpty ? samples : history
    }

    private func updateTrafficHistory(with newValue: UInt64) {
        let now = Date()
        guard let previousBytes else {
            previousBytes = newValue
            lastSampleAt = now
            history = samples
            return
        }

        let delta = newValue >= previousBytes ? newValue - previousBytes : 0
        let logarithmic = log10(Double(delta) + 1) / 7
        let target = CGFloat(min(1, max(0.10, 0.10 + logarithmic * 0.90)))
        let smoothed = history.last.map { $0 * 0.72 + target * 0.28 } ?? target

        self.previousBytes = newValue
        guard now.timeIntervalSince(lastSampleAt) >= 0.8 else {
            return
        }
        lastSampleAt = now
        let nextHistory = Array((history + [smoothed]).suffix(max(8, samples.count)))
        withAnimation(.smooth(duration: 0.72)) {
            history = nextHistory
        }
    }
}

private struct MiniTrafficSparkline: View {
    let samples: [CGFloat]

    @State private var reveal = 0.0
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard samples.count > 1 else { return }
                let step = proxy.size.width / CGFloat(samples.count - 1)
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: proxy.size.height * (1 - sample)
                    )
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .trim(from: 0, to: reveal)
            .stroke(
                LinearGradient(
                    colors: [Color.vexCyan.opacity(0.45), Color.vexCyanLight],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            )
            .animation(.easeInOut(duration: 0.46), value: samples)
        }
        .onAppear {
            if accessibilityReduceMotion {
                reveal = 1
            } else {
                withAnimation(.easeOut(duration: 0.82)) {
                    reveal = 1
                }
            }
        }
        .accessibilityHidden(true)
    }
}
