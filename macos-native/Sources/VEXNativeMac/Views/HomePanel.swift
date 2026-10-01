import SwiftUI

struct HomePanel: View {
    @EnvironmentObject private var helper: VEXHelperModel
    @EnvironmentObject private var appState: VEXAppState
    let onShowServers: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            FocusPulseHero(
                status: helper.status,
                requiresHelperInstall: helper.installRequiredMessage != nil,
                installationPhase: helper.installationPhase,
                isBusy: helper.isBusy || appState.isVpnBusy,
                selectedLocation: selectedLocation,
                action: togglePower
            )

            FocusPulseLocations(
                locations: featuredLocations,
                selectedLocationId: presentationSelectedLocationId,
                onSelect: selectLocation,
                onShowAll: onShowServers
            )

            footer
        }
        .frame(maxWidth: 1080, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .task {
            if VEXPreviewMode.suppressesRuntime { return }
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
        if VEXPreviewMode.isEnabled || VEXPreviewMode.isOfflineSmoke {
            return FocusPulsePresentation.animationPreviewLocations
        }

        // Apply the featured limit after grouping, never truncate a country's nodes.
        return appState.locations
    }

    private var presentationSelectedLocationId: String {
        if VEXPreviewMode.suppressesRuntime {
            return ProcessInfo.processInfo.environment["VEX_PREVIEW_LOCATION_ID"]
                ?? featuredLocations.first?.id ?? ""
        }
        return appState.selectedLocationId
    }

    private var selectedLocation: VpnLocation? {
        featuredLocations.first { $0.id == presentationSelectedLocationId }
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
        guard helper.status.state != .connected else {
            return nil
        }

        let candidates = [appState.statusMessage, helper.message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let actionableMessage = candidates.first(where: isActionableStatusMessage) else {
            return nil
        }
        return VEXUserFacingText.status(
            actionableMessage,
            respecting: helper.status,
            isBusy: helper.isBusy || appState.isVpnBusy
        )
    }

    private func isActionableStatusMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return ["ошиб", "не удалось", "недоступ", "конфликт", "отмен", "failed", "error"]
            .contains { normalized.contains($0) }
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
        VEXCountryGroup.make(locations, selectedID: selectedLocationId, limit: locations.count)
            .sorted { $0.id < $1.id }
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
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.vexText)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                }
                .buttonStyle(.plain)
            } else {
                GeometryReader { geometry in
                    let spacing: CGFloat = 12
                    let cardWidth = FocusPulsePresentation.locationCardWidth(
                        containerWidth: geometry.size.width,
                        visibleCardCount: countries.count,
                        spacing: spacing
                    )
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: spacing) {
                            ForEach(countries) { country in
                                FocusPulseLocationCard(
                                    location: country.cardLocation,
                                    selected: country.isSelected,
                                    width: cardWidth,
                                    action: {
                                        if country.isSelected {
                                            expandedCountryID = country.id
                                        } else {
                                            onSelect(country.representative)
                                        }
                                    }
                                )
                                .disabled(country.availableNodeCount == 0 && !country.isSelected)
                                .popover(isPresented: Binding(
                                    get: { expandedCountryID == country.id },
                                    set: { if !$0 { expandedCountryID = nil } }
                                ), arrowEdge: .top) {
                                    countryNodes(country)
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollClipDisabled()
                    .scrollTargetBehavior(.viewAligned)
                }
                .frame(height: 140)
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
    let width: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                cardArtwork

                LinearGradient(
                    colors: [Color.clear, Color.vexBackground.opacity(0.90)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                HStack(alignment: .bottom, spacing: 9) {
                    Text(flag)
                        .font(.system(size: 24))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.localizedName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.vexText)
                            .lineLimit(1)
                        Text("\(FocusPulsePresentation.nodeCountText(location.healthyNodes)) · \(availability)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.vexSecondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if let latency = FocusPulsePresentation.latencyText(location.latencyMs) {
                        Text(latency)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color.vexCyanLight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(width: width, height: 136)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        selected
                            ? Color.vexCyan.opacity(0.94)
                            : (isHovered ? Color.vexCyan.opacity(0.34) : Color.white.opacity(0.10)),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color.vexCyanLight)
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.vexCyan.opacity(0.48), lineWidth: 1))
                        .padding(10)
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                }
            }
            .shadow(
                color: selected || isHovered
                    ? Color.vexCyan.opacity(isHovered ? 0.14 : 0.08)
                    : Color.black.opacity(0.10),
                radius: isHovered ? 12 : 8,
                y: isHovered ? 5 : 3
            )
        }
        .buttonStyle(.plain)
        .animation(selectionAnimation, value: selected)
        .brightness(isHovered ? 0.035 : 0)
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
        .accessibilityHint(selected ? "Открыть ручной выбор сервера" : "Выбрать лучший сервер страны")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectionAnimation: Animation {
        .easeInOut(
            duration: FocusPulsePresentation.selectionTransitionDuration(
                reduceMotion: accessibilityReduceMotion
            )
        )
    }

    @ViewBuilder
    private var cardArtwork: some View {
        if let assetName = LocationPhotoArtwork.assetName(countryCode: location.countryCode) {
            BundleImage(name: assetName, contentMode: .fill)
                .frame(width: width, height: 136)
                .clipped()
                .scaleEffect(isHovered ? 1.035 : 1)
        } else {
            ZStack {
                Color.vexPanelStrong
                CountrySilhouetteShape(countryCode: location.countryCode)
                    .fill(Color.vexCyan.opacity(0.12), style: FillStyle(eoFill: true))
                    .frame(width: 92, height: 92)
            }
        }
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

    private var availability: String {
        location.healthyNodes > 0 ? "доступно" : "нет доступных"
    }
}
