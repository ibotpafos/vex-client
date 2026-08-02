import SwiftUI

enum VEXTrayLayout {
    static let size = CGSize(width: 360, height: 448)
    static let screenMargin: CGFloat = 10

    static func panelFrame(
        below buttonFrame: CGRect,
        inside screenFrame: CGRect,
        size: CGSize = size
    ) -> CGRect {
        let minimumX = screenFrame.minX + screenMargin
        let maximumX = max(minimumX, screenFrame.maxX - size.width - screenMargin)
        let preferredX = buttonFrame.maxX - size.width
        let x = min(max(preferredX, minimumX), maximumX)

        let minimumY = screenFrame.minY + screenMargin
        let maximumY = max(minimumY, screenFrame.maxY - size.height - screenMargin)
        let preferredY = buttonFrame.minY - size.height - 8
        let y = min(max(preferredY, minimumY), maximumY)

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

struct VEXTrayPanelView: View {
    @ObservedObject var helper: VEXHelperModel
    @ObservedObject var appState: VEXAppState
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let onOpenApp: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var hoveredAction: TrayAction?

    var body: some View {
        ZStack {
            VEXBackground(selection: .home)

            VStack(spacing: 11) {
                header
                connectionPulse
                trafficStrip
                routeCard
                footer
            }
            .padding(16)
        }
        .frame(width: VEXTrayLayout.size.width, height: VEXTrayLayout.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.vexCyan.opacity(0.09),
                            Color.white.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.black.opacity(0.42), radius: 28, y: 14)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("VEX")
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(Color.vexText)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.55), radius: 4)

                Text(statusTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vexSubtext)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(Color.white.opacity(0.055), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.075), lineWidth: 1)
            }

            Spacer(minLength: 4)

            headerButton(
                systemName: "gearshape",
                action: .settings,
                help: "Настройки",
                perform: onOpenSettings
            )
            headerButton(
                systemName: "power",
                action: .quit,
                help: "Выйти из VEX",
                perform: onQuit
            )
        }
        .frame(height: 30)
    }

    private func headerButton(
        systemName: String,
        action: TrayAction,
        help: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    Color.white.opacity(hoveredAction == action ? 0.12 : 0.055),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(hoveredAction == action ? 0.13 : 0.06), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(hoveredAction == action ? Color.vexText : Color.vexSecondaryText)
        .scaleEffect(hoveredAction == action ? 1.045 : 1)
        .onHover { updateHover(action, hovering: $0) }
        .help(help)
        .accessibilityLabel(help)
    }

    private var connectionPulse: some View {
        VStack(spacing: 7) {
            ZStack {
                CircuitBackdrop()
                    .frame(width: 210, height: 132)
                    .mask {
                        Ellipse()
                            .blur(radius: 14)
                    }
                    .opacity(0.48)
                    .blur(radius: 12)

                Circle()
                    .stroke(Color.vexCyan.opacity(0.065), lineWidth: 1)
                    .frame(width: 126, height: 126)

                Circle()
                    .stroke(Color.vexCyan.opacity(0.11), lineWidth: 1)
                    .frame(width: 106, height: 106)

                Button {
                    Task {
                        await appState.toggleVPNPower(using: helper)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        statusColor.opacity(isConnected ? 0.34 : 0.14),
                                        Color.vexPanelStrong.opacity(0.98),
                                    ],
                                    center: .topLeading,
                                    startRadius: 2,
                                    endRadius: 78
                                )
                            )

                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        statusColor.opacity(isConnected ? 1 : 0.56),
                                        Color.vexCyanLight.opacity(isConnected ? 0.72 : 0.24),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 3
                            )
                            .padding(3)

                        Image(systemName: helper.isBusy ? "ellipsis" : "power")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(isConnected ? Color.vexBackground : Color.vexCyanLight)
                    }
                    .frame(width: 86, height: 86)
                    .scaleEffect(hoveredAction == .connection ? 1.045 : 1)
                    .shadow(
                        color: statusColor.opacity(hoveredAction == .connection ? 0.42 : 0.22),
                        radius: hoveredAction == .connection ? 22 : 14
                    )
                }
                .buttonStyle(.plain)
                .disabled(helper.isBusy)
                .onHover { updateHover(.connection, hovering: $0) }
                .accessibilityLabel(connectionActionTitle)
            }
            .frame(height: 114)

            Text(connectionHeadline)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.vexText)

            HStack(spacing: 7) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(locationTitle)
                    .lineLimit(1)
                if let latencyTitle {
                    Circle()
                        .fill(Color.vexSecondaryText.opacity(0.55))
                        .frame(width: 3, height: 3)
                    Text(latencyTitle)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.vexSubtext)
        }
        .frame(maxWidth: .infinity)
        .animation(motionAnimation, value: helper.status.state)
        .animation(motionAnimation, value: hoveredAction)
    }

    private var trafficStrip: some View {
        HStack(spacing: 0) {
            metric(
                title: "Получено",
                value: byteTitle(helper.status.rxBytes),
                systemName: "arrow.down"
            )

            Rectangle()
                .fill(Color.white.opacity(0.075))
                .frame(width: 1, height: 30)

            metric(
                title: "Отправлено",
                value: byteTitle(helper.status.txBytes),
                systemName: "arrow.up"
            )
        }
        .padding(.vertical, 9)
        .background(sectionBackground(cornerRadius: 14))
        .overlay(sectionBorder(cornerRadius: 14))
    }

    private func metric(title: String, value: String, systemName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.vexCyan)
                .frame(width: 24, height: 24)
                .background(Color.vexCyan.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.vexSecondaryText)
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.vexText)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity)
    }

    private var routeCard: some View {
        Button(action: onOpenApp) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vexCyanLight)
                    .frame(width: 31, height: 31)
                    .background(Color.vexCyan.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Умный маршрут")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.vexText)
                    Text(recommendationText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.vexSubtext)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.vexSecondaryText)
            }
            .padding(.horizontal, 11)
            .frame(height: 51)
            .background(sectionBackground(
                cornerRadius: 14,
                opacity: hoveredAction == .recommendation ? 0.80 : 0.62
            ))
            .overlay(sectionBorder(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .scaleEffect(hoveredAction == .recommendation ? 1.012 : 1)
        .onHover { updateHover(.recommendation, hovering: $0) }
        .animation(motionAnimation, value: hoveredAction)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button(action: onOpenApp) {
                Label("Открыть VEX", systemImage: "macwindow")
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        Color.white.opacity(hoveredAction == .openApp ? 0.14 : 0.075),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                hoveredAction == .openApp
                                    ? Color.vexCyan.opacity(0.30)
                                    : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    }
                    .foregroundStyle(Color.vexText)
            }
            .buttonStyle(.plain)
            .scaleEffect(hoveredAction == .openApp ? 1.012 : 1)
            .onHover { updateHover(.openApp, hovering: $0) }

            Link(destination: Self.websiteURL) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 38, height: 36)
                    .background(
                        Color.white.opacity(hoveredAction == .website ? 0.12 : 0.055),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    }
                    .foregroundStyle(Color.vexCyanLight)
            }
            .buttonStyle(.plain)
            .scaleEffect(hoveredAction == .website ? 1.035 : 1)
            .onHover { updateHover(.website, hovering: $0) }
            .help("Открыть сайт VEX")
            .accessibilityLabel("Открыть сайт VEX")
        }
        .animation(motionAnimation, value: hoveredAction)
    }

    private func sectionBackground(cornerRadius: CGFloat, opacity: Double = 0.62) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.vexPanelStrong.opacity(opacity))
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    private func sectionBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color.white.opacity(0.075), lineWidth: 1)
    }

    private func updateHover(_ action: TrayAction, hovering: Bool) {
        withAnimation(motionAnimation) {
            hoveredAction = hovering ? action : nil
        }
    }

    private var motionAnimation: Animation {
        accessibilityReduceMotion
            ? .linear(duration: 0.01)
            : .snappy(duration: 0.22, extraBounce: 0.025)
    }

    private var isConnected: Bool {
        helper.status.isUsableConnectedStatus
    }

    private var statusColor: Color {
        switch helper.status.state {
        case .connected:
            return .vexCyan
        case .connecting, .disconnecting:
            return .orange
        case .disconnected:
            return .vexSecondaryText
        }
    }

    private var statusTitle: String {
        switch helper.status.state {
        case .connected:
            return "Защита активна"
        case .connecting:
            return "Подключение…"
        case .disconnecting:
            return "Отключение…"
        case .disconnected:
            return "VPN отключён"
        }
    }

    private var connectionHeadline: String {
        switch helper.status.state {
        case .connected:
            return "Подключено"
        case .connecting:
            return "Подключаем"
        case .disconnecting:
            return "Отключаем"
        case .disconnected:
            return "Не подключено"
        }
    }

    private var connectionActionTitle: String {
        isConnected ? "Отключить VPN" : "Подключить VPN"
    }

    private var locationTitle: String {
        appState.selectedLocation?.displayName ?? appState.selectedLocationId.uppercased()
    }

    private var latencyTitle: String? {
        appState.selectedLocation?.latencyMs.map { "\(Int($0.rounded())) мс" }
    }

    private var recommendationText: String {
        if isConnected {
            return "Маршрут стабилен — \(locationTitle)"
        }
        return "Оптимальный сервер в одно нажатие"
    }

    private func byteTitle(_ bytes: UInt64) -> String {
        guard bytes > 0 else {
            return "0 Б"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static let websiteURL = URL(string: "https://vexguard.app")!
}

private enum TrayAction: Hashable {
    case connection
    case recommendation
    case openApp
    case website
    case settings
    case quit
}
