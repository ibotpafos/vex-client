import SwiftUI

struct HomePanel: View {
    @EnvironmentObject private var helper: VEXHelperModel
    @EnvironmentObject private var appState: VEXAppState
    @State private var showingServerPicker = false

    var body: some View {
        VStack(spacing: 14) {
            PowerHero(
                status: helper.status,
                requiresHelperInstall: helper.installRequiredMessage != nil,
                isBusy: helper.isBusy || appState.isVpnBusy,
                action: {
                    Task {
                        if helper.installRequiredMessage != nil {
                            await helper.repairHelper()
                        } else {
                            await appState.toggleVPNPower(using: helper)
                        }
                    }
                }
            )
            .frame(minHeight: 292)

            Button {
                showingServerPicker = true
            } label: {
                ServerChip(status: helper.status)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingServerPicker) {
                ServerPickerPanel()
                    .environmentObject(appState)
                    .environmentObject(helper)
            }
            .frame(minHeight: 76)

            TrafficStats(status: helper.status)
                .frame(minHeight: 76)

            if let message = footerMessage {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
            } else {
                Color.clear.frame(height: 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await appState.recoverTunnelIfNeeded(using: helper)
            }
        }
    }

    private var footerMessage: String? {
        if let installRequiredMessage = helper.installRequiredMessage {
            return installRequiredMessage
        }
        if let routeConflictMessage = helper.status.routeConflictMessage {
            return routeConflictMessage
        }
        if let statusMessage = appState.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !statusMessage.isEmpty,
           let polished = VEXUserFacingText.status(statusMessage, respecting: helper.status, isBusy: helper.isBusy || appState.isVpnBusy) {
            return polished
        }
        guard helper.status.state != .connected,
              let helperMessage = helper.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !helperMessage.isEmpty,
              let polished = VEXUserFacingText.status(helperMessage) else {
            return nil
        }
        return polished
    }
}

private struct PowerHero: View {
    let status: VpnStatus
    let requiresHelperInstall: Bool
    let isBusy: Bool
    let action: () -> Void

    private var isConnected: Bool { status.isUsableConnectedStatus }

    private var isTransitioning: Bool {
        status.state == .connecting || status.state == .disconnecting
    }

    private var shouldAnimateHero: Bool {
        isTransitioning || isBusy
    }

    private var buttonText: String {
        if requiresHelperInstall {
            return "Установить"
        }
        switch status.state {
        case .connected:
            return "Отключить"
        case .connecting:
            return "Отменить"
        case .disconnecting:
            return "Подключить"
        case .disconnected:
            return "Подключить"
        }
    }

    private var subtext: String {
        if requiresHelperInstall {
            return "Helper требуется"
        }
        switch status.state {
        case .connected:
            return "VPN активен"
        case .connecting:
            return "Ждем handshake"
        case .disconnecting:
            return "Завершаем"
        case .disconnected:
            return "VPN выключен"
        }
    }

    var body: some View {
        ZStack {
            CircuitBackdrop()
                .frame(height: 286)
                .opacity(0.52)

            if shouldAnimateHero {
                AnimatedHeroLayers(status: status, tint: heroTint)
            } else {
                StaticHeroLayers(isConnected: isConnected, tint: heroTint)
            }

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.01, green: 0.13, blue: 0.16).opacity(0.96),
                                    Color(red: 0.00, green: 0.05, blue: 0.06).opacity(0.98)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(buttonRingColor, lineWidth: isTransitioning ? 8 : 7)
                        )
                        .shadow(color: heroTint.opacity(isTransitioning ? 0.42 : 0.34), radius: isTransitioning ? 18 : 12)

                    VStack(spacing: 8) {
                        if isBusy {
                            VEXMiniSpinner(tint: heroTint)
                        }

                        Text(buttonText)
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(Color.vexText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)

                        Text(subtext)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.vexSubtext)
                    }
                    .padding(.horizontal, 18)
                    .id("\(status.state.rawValue)-\(isBusy)")
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .frame(width: 204, height: 204)
            .buttonStyle(.plain)
            .scaleEffect(buttonScale)
            .animation(buttonScaleAnimation, value: status.state)
            .animation(buttonScaleAnimation, value: isBusy)
        }
        .frame(maxWidth: .infinity, minHeight: 292)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isConnected ? "Отключить VPN" : "Подключить VPN")
    }

    private var heroTint: Color {
        isConnected ? Color.green : Color.vexCyan
    }

    private var buttonScale: CGFloat {
        switch status.state {
        case .connected:
            return 1.0
        case .connecting:
            return 1.02
        case .disconnecting:
            return 0.985
        case .disconnected:
            return 1.0
        }
    }

    private var buttonRingColor: Color {
        isTransitioning ? heroTint.opacity(0.92) : Color(red: 0.207, green: 0.902, blue: 0.957)
    }

    private var buttonScaleAnimation: Animation {
        switch status.state {
        case .connecting:
            return .spring(response: 0.32, dampingFraction: 0.68)
        case .disconnecting:
            return .spring(response: 0.36, dampingFraction: 0.78)
        case .connected, .disconnected:
            return .snappy(duration: 0.24)
        }
    }

}

private struct StaticHeroLayers: View {
    let isConnected: Bool
    let tint: Color

    var body: some View {
        Group {
            Circle()
                .fill(tint.opacity(isConnected ? 0.16 : 0.10))
                .frame(width: 222, height: 222)
                .shadow(color: tint.opacity(0.26), radius: 12)

            Circle()
                .stroke(tint.opacity(0.34), lineWidth: 1)
                .frame(width: 228, height: 228)
                .opacity(isConnected ? 0.42 : 0.24)

            Circle()
                .stroke(Color.vexCyanLight.opacity(0.08), lineWidth: 6)
                .frame(width: 242, height: 242)
        }
    }
}

private struct AnimatedHeroLayers: View {
    let status: VpnStatus
    let tint: Color

    @State private var pulse = false
    @State private var orbit = false

    private var isConnected: Bool { status.isUsableConnectedStatus }

    private var isTransitioning: Bool {
        status.state == .connecting || status.state == .disconnecting
    }

    var body: some View {
        Group {
            Circle()
                .fill(tint.opacity(isConnected ? 0.16 : 0.10))
                .frame(width: 222, height: 222)
                .shadow(color: tint.opacity(isTransitioning ? 0.34 : 0.26), radius: isTransitioning ? 20 : 12)
                .scaleEffect(pulseScale)
                .animation(pulseAnimation, value: pulse)

            Circle()
                .stroke(tint.opacity(0.34), lineWidth: 1)
                .frame(width: 228, height: 228)
                .scaleEffect(orbitHaloScale)
                .opacity(orbitHaloOpacity)
                .animation(pulseAnimation, value: pulse)

            Circle()
                .stroke(Color.vexCyanLight.opacity(0.08), lineWidth: 6)
                .frame(width: 242, height: 242)

            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(
                    AngularGradient(
                        colors: [
                            tint.opacity(0.18),
                            tint.opacity(0.96),
                            Color.vexCyanLight.opacity(0.82),
                            tint.opacity(0.18),
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .frame(width: 214, height: 214)
                .rotationEffect(.degrees(orbit ? 360 : 0))
                .opacity(isTransitioning ? 0.96 : 0.0)
                .animation(orbitAnimation, value: orbit)
                .animation(.easeInOut(duration: 0.24), value: status.state)
        }
        .onAppear {
            pulse = true
            orbit = true
        }
    }

    private var pulseScale: CGFloat {
        switch status.state {
        case .connected:
            return pulse ? 1.025 : 0.99
        case .connecting:
            return pulse ? 1.055 : 0.97
        case .disconnecting:
            return pulse ? 0.985 : 1.045
        case .disconnected:
            return pulse ? 1.01 : 0.985
        }
    }

    private var orbitHaloScale: CGFloat {
        switch status.state {
        case .connected:
            return pulse ? 1.04 : 1.0
        case .connecting:
            return pulse ? 1.08 : 0.98
        case .disconnecting:
            return pulse ? 1.02 : 1.1
        case .disconnected:
            return pulse ? 1.03 : 0.99
        }
    }

    private var orbitHaloOpacity: Double {
        switch status.state {
        case .connected:
            return pulse ? 0.64 : 0.38
        case .connecting:
            return pulse ? 0.86 : 0.34
        case .disconnecting:
            return pulse ? 0.52 : 0.84
        case .disconnected:
            return pulse ? 0.34 : 0.22
        }
    }

    private var pulseAnimation: Animation {
        switch status.state {
        case .connected:
            return .easeInOut(duration: 1.9).repeatForever(autoreverses: true)
        case .connecting:
            return .easeInOut(duration: 0.82).repeatForever(autoreverses: true)
        case .disconnecting:
            return .easeInOut(duration: 1.05).repeatForever(autoreverses: true)
        case .disconnected:
            return .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        }
    }

    private var orbitAnimation: Animation {
        .linear(duration: status.state == .disconnecting ? 1.45 : 1.05)
            .repeatForever(autoreverses: false)
    }
}

private struct ServerChip: View {
    @EnvironmentObject private var appState: VEXAppState
    let status: VpnStatus

    var body: some View {
        GlassPanel(cornerRadius: 20, interactive: true, tint: Color.vexCyan.opacity(0.10)) {
            HStack(spacing: 10) {
                PanelIcon(systemName: "mappin.and.ellipse", size: 42, iconSize: 21)

                VStack(alignment: .leading, spacing: 3) {
                    Text("СЕРВЕР")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color.vexMuted)
                    Text(serverTitle)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color.vexText)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                if let latencyText {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                        Text(latencyText)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(red: 0.47, green: 0.59, blue: 0.61))
            }
            .frame(minHeight: 62)
        }
    }

    private var serverTitle: String {
        if appState.serverSelectionMode == "manual", let location = appState.selectedLocation {
            return location.displayName
        }
        if let endpoint = status.endpoint, !endpoint.isEmpty {
            return endpoint
        }
        return appState.selectedLocationId.uppercased()
    }

    private var latencyText: String? {
        appState.selectedLocation?.latencyMs.map { "\(Int($0.rounded())) мс" }
    }
}

private struct TrafficStats: View {
    let status: VpnStatus

    var body: some View {
        GlassPanel(cornerRadius: 18, tint: Color.vexCyan.opacity(0.08)) {
            HStack(spacing: 14) {
                TrafficItem(title: "ПОЛУЧЕНО", value: formatBytes(status.rxBytes), systemName: "arrow.down")

                Rectangle()
                    .fill(Color.vexCyan.opacity(0.22))
                    .frame(width: 1, height: 42)

                TrafficItem(title: "ОТПРАВЛЕНО", value: formatBytes(status.txBytes), systemName: "arrow.up")
            }
            .frame(minHeight: 62)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            .replacingOccurrences(of: "bytes", with: "Б")
            .replacingOccurrences(of: "byte", with: "Б")
    }
}

private struct TrafficItem: View {
    let title: String
    let value: String
    let systemName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color.vexMuted)

            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color.vexText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                ZStack {
                    Circle()
                        .fill(Color.vexCyan.opacity(0.14))
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color.vexCyan)
                }
                .frame(width: 24, height: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
