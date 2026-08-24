import SwiftUI

struct HomePanel: View {
    @EnvironmentObject private var helper: VEXHelperModel
    @EnvironmentObject private var appState: VEXAppState
    let onShowServers: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            FocusPulseHero(
                status: helper.status,
                requiresHelperInstall: helper.installRequiredMessage != nil,
                installationPhase: helper.installationPhase,
                isBusy: helper.isBusy || appState.isVpnBusy,
                action: togglePower
            )

            FocusPulseLocations(
                locations: featuredLocations,
                selectedLocationId: appState.selectedLocationId,
                onSelect: selectLocation,
                onShowAll: onShowServers
            )

            footer
        }
        .frame(maxWidth: 1080, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .task {
            #if DEBUG
            if VEXPreviewMode.isEnabled {
                return
            }
            #endif
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch { return }
                guard !Task.isCancelled else { return }
                await appState.recoverTunnelIfNeeded(using: helper)
            }
        }
    }

    private var featuredLocations: [VpnLocation] {
        #if DEBUG
        if VEXPreviewMode.isEnabled {
            return FocusPulsePresentation.animationPreviewLocations
        }
        #endif

        return FocusPulsePresentation.featuredLocations(
            appState.locations,
            selectedLocationId: appState.selectedLocationId
        )
    }

    @ViewBuilder
    private var footer: some View {
        if let message = footerMessage {
            HStack(spacing: 8) {
                Image(systemName: installationFailed ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(
                        installationFailed
                            ? Color(red: 1.0, green: 0.36, blue: 0.40)
                            : Color.vexCyan
                    )
                Text(message)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.vexSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    private var footerMessage: String? {
        if let routeConflictMessage = helper.status.routeConflictMessage {
            return routeConflictMessage
        }
        if helper.status.state != .connected,
           let statusMessage = appState.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !statusMessage.isEmpty,
           let polished = VEXUserFacingText.status(
               statusMessage,
               respecting: helper.status,
               isBusy: helper.isBusy || appState.isVpnBusy
           ) {
            return polished
        }
        guard helper.status.state != .connected,
              let helperMessage = helper.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !helperMessage.isEmpty else {
            return nil
        }
        guard let polished = VEXUserFacingText.status(helperMessage),
              polished != "Системный компонент VEX запускается..." else {
            return nil
        }
        return polished
    }

    private var installationFailed: Bool {
        if case .failed = helper.installationPhase {
            return true
        }
        return false
    }

    private func togglePower() {
        Task {
            if helper.installRequiredMessage != nil {
                await helper.repairHelper()
            } else {
                await appState.toggleVPNPower(using: helper)
            }
        }
    }

    private func selectLocation(_ location: VpnLocation) {
        Task {
            await appState.selectLocation(location, using: helper)
        }
    }
}

private struct FocusPulseLocations: View {
    let locations: [VpnLocation]
    let selectedLocationId: String
    let onSelect: (VpnLocation) -> Void
    let onShowAll: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Локации")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.vexText)
                Spacer()
                Button(action: onShowAll) {
                    HStack(spacing: 5) {
                        Text("Все")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.vexSecondaryText)
                }
                .buttonStyle(.plain)
            }

            if locations.isEmpty {
                Button(action: onShowAll) {
                    GlassPanel(cornerRadius: 18, interactive: true, tint: Color.vexCyan.opacity(0.08)) {
                        Label("Выбрать доступный сервер", systemImage: "globe.europe.africa.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.vexText)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(locations) { location in
                            FocusPulseLocationCard(
                                location: location,
                                selected: location.id == selectedLocationId,
                                action: { onSelect(location) }
                            )
                            .containerRelativeFrame(
                                .horizontal,
                                count: 5,
                                span: 2,
                                spacing: 12
                            )
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.975)
                                    .opacity(phase.isIdentity ? 1 : 0.84)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 2, for: .scrollContent)
                .scrollClipDisabled()
                .scrollTargetBehavior(.viewAligned)
                .frame(height: 86)
            }
        }
    }
}

private struct FocusPulseLocationCard: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let location: VpnLocation
    let selected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(flag)
                    .font(.system(size: 27))

                VStack(alignment: .leading, spacing: 4) {
                    Text(location.localizedName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.vexText)
                        .lineLimit(1)
                    Text("\(FocusPulsePresentation.nodeCountText(location.healthyNodes)) · \(availability)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let latency = FocusPulsePresentation.latencyText(location.latencyMs) {
                    Text(latency)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color.vexCyanLight)
                }

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? Color.vexCyan : Color.vexMuted)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background {
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            Color.vexPanelStrong.opacity(
                                selected ? 0.82 : (isHovered ? 0.76 : 0.64)
                            )
                        )

                    ZStack {
                        CountrySilhouetteShape(countryCode: location.countryCode)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.vexCyan.opacity(0.30),
                                        Color.vexCyanLight,
                                    ],
                                    startPoint: .bottomLeading,
                                    endPoint: .topTrailing
                                ),
                                style: FillStyle(eoFill: true)
                            )
                            .opacity(countryArtworkHovered ? 0.20 : (selected ? 0.085 : 0.048))

                        CountrySilhouetteShape(countryCode: location.countryCode)
                            .stroke(
                                Color.vexCyanLight.opacity(
                                    countryArtworkHovered ? 0.52 : (selected ? 0.18 : 0.10)
                                ),
                                lineWidth: countryArtworkHovered ? 0.95 : 0.6
                            )
                    }
                    .frame(width: 82, height: 82)
                    .scaleEffect(countryArtworkHovered ? 1.28 : 1)
                    .shadow(
                        color: countryArtworkHovered ? Color.vexCyan.opacity(0.40) : .clear,
                        radius: 15
                    )
                    .padding(.trailing, 96)
                    .offset(x: 18, y: 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        selected
                            ? Color.vexCyan.opacity(0.82)
                            : (isHovered ? Color.vexCyan.opacity(0.38) : Color.white.opacity(0.08)),
                        lineWidth: selected ? 1.4 : 1
                    )
            )
            .shadow(
                color: selected || isHovered
                    ? Color.vexCyan.opacity(isHovered ? 0.18 : 0.10)
                    : Color.black.opacity(0.12),
                radius: isHovered ? 18 : 12,
                y: isHovered ? 8 : 5
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.012 : 1)
        .offset(y: isHovered ? -2 : 0)
        .onHover { hovering in
            withAnimation(
                accessibilityReduceMotion
                    ? .linear(duration: 0.01)
                    : .snappy(duration: 0.22)
            ) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(location.displayName), \(availability)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var flag: String {
        if let emoji = location.flagEmoji.flatMap(nonEmpty) {
            return emoji
        }
        return location.countryCode
            .uppercased()
            .unicodeScalars
            .compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init)
            .joined()
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var countryArtworkHovered: Bool {
        #if DEBUG
        return isHovered
            || ProcessInfo.processInfo.environment["VEX_PREVIEW_HOVER_LOCATION"] == location.id
        #else
        return isHovered
        #endif
    }

    private var availability: String {
        location.localizedStatus
    }
}
