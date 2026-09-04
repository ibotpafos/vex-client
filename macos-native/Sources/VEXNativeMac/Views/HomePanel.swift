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

        // Apply the featured limit after grouping, never truncate a country's nodes.
        return appState.locations
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
    @State private var expandedCountryID: String?

    private var countries: [VEXCountryGroup] {
        VEXCountryGroup.make(locations, selectedID: selectedLocationId)
    }

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
                        ForEach(countries) { country in
                            FocusPulseLocationCard(
                                location: country.cardLocation,
                                selected: country.isSelected,
                                action: { expandedCountryID = country.id }
                            )
                            .popover(isPresented: Binding(
                                get: { expandedCountryID == country.id },
                                set: { if !$0 { expandedCountryID = nil } }
                            ), arrowEdge: .top) {
                                countryNodes(country)
                            }
                            .containerRelativeFrame(
                                .horizontal,
                                count: min(max(countries.count, 1), 3),
                                span: 1,
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

    private func countryNodes(_ country: VEXCountryGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(country.representative.localizedName)
                .font(.headline)
            Text("\(FocusPulsePresentation.nodeCountText(country.availableNodeCount)) · доступно")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(country.locations) { location in
                        Button {
                            expandedCountryID = nil
                            onSelect(location)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(location.city.isEmpty ? location.id : location.city)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(location.id)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(VEXCountryGroup.isAvailable(location) ? location.localizedStatus : "Недоступен")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                if VEXCountryGroup.isAvailable(location),
                                   let latency = FocusPulsePresentation.latencyText(location.latencyMs) {
                                    Text(latency).font(.caption.monospacedDigit())
                                }
                                Image(systemName: location.id == selectedLocationId ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(location.id == selectedLocationId ? Color.vexCyan : Color.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!VEXCountryGroup.isAvailable(location))
                        .accessibilityLabel("\(location.city), \(location.id), \(location.localizedStatus)")
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(country.locations.count) * 90, 320))
        }
        .padding(16)
        .frame(width: 360)
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
        location.healthyNodes > 0 ? "доступно" : "нет доступных"
    }
}
