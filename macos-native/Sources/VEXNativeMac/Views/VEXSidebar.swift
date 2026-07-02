import SwiftUI

struct VEXSidebar: View {
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel
    @Binding var selection: AppSection

    var body: some View {
        ZStack {
            sidebarBackground

            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        primaryNavigation
                        vpnSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 52)
                    .padding(.bottom, 12)
                }

                Divider()
                    .overlay(Color.white.opacity(0.10))

                profileMenu
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var sidebarBackground: some View {
        SidebarGlassBackground()
    }

    private var primaryNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(AppSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    CodexSidebarRow(
                        icon: section.systemName,
                        title: section.title,
                        detail: nil,
                        trailing: nil,
                        isSelected: selection == section
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var vpnSection: some View {
        VStack(alignment: .leading, spacing: 6) {
                Text("VPN")
                    .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vexSecondaryText)
                .padding(.horizontal, 10)

            Button {
                Task {
                    await appState.toggleVPNPower(using: helper)
                }
            } label: {
                CodexSidebarRow(
                    icon: helper.status.state.symbolName,
                    title: vpnActionTitle,
                    detail: VEXUserFacingText.status(appState.statusMessage),
                    trailing: nil,
                    isSelected: false
                )
            }
            .buttonStyle(.plain)

            CodexSidebarRow(
                icon: "server.rack",
                title: selectedServerTitle,
                detail: "Сервер",
                trailing: selectedServerLatency,
                isSelected: false
            )
        }
    }

    private var profileMenu: some View {
        HStack(spacing: 8) {
            Button {
                selection = .account
            } label: {
                profileLabel
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    selection = .account
                } label: {
                    Label("Личная учетная запись", systemImage: "person.crop.circle")
                }

                Button {
                    selection = .settings
                } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: [.command])

                Divider()

                if let updateReadyText = appState.updateReadyText {
                    Button {
                        appState.checkForNativeUpdates()
                    } label: {
                        Label(updateReadyText, systemImage: "arrow.down.circle.fill")
                    }
                }

                Button {
                    appState.checkForNativeUpdates()
                } label: {
                    Label("Проверить обновления", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!appState.canCheckForNativeUpdates)

                Divider()

                Button {
                    appState.signOut()
                } label: {
                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.vexSecondaryText)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var profileLabel: some View {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.vexCyan.opacity(0.95))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Text(initials)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.84))
                    )

                VStack(alignment: .leading, spacing: 2) {
                        Text(appState.accountTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.vexText)
                            .lineLimit(1)

                    Text(profileSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: profileAccessorySymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(profileAccessoryColor)
            }
            .padding(.leading, 2)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var vpnActionTitle: String {
        switch helper.status.state {
        case .connected:
            return "Отключить VPN"
        case .connecting:
            return "Подключается"
        case .disconnecting:
            return "Отключается"
        case .disconnected:
            return "Подключить VPN"
        }
    }

    private var selectedServerTitle: String {
        appState.selectedLocation?.displayName ?? appState.selectedLocationId.uppercased()
    }

    private var selectedServerLatency: String? {
        appState.selectedLocation?.latencyMs.map { "\(Int($0.rounded())) мс" }
    }

    private var initials: String {
        let value = appState.accountTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first else { return "V" }
        return String(first).uppercased()
    }

    private var profileSubtitle: String {
        if let updateReadyText = appState.updateReadyText {
            return updateReadyText
        }
        return helper.status.state == .connected ? "VPN активен" : "VEX Native"
    }

    private var profileAccessorySymbol: String {
        appState.updateReadyText == nil ? "desktopcomputer" : "arrow.down.circle.fill"
    }

    private var profileAccessoryColor: Color {
        appState.updateReadyText == nil ? Color.vexSecondaryText : Color.vexCyan
    }
}

private struct SidebarGlassBackground: View {
    var body: some View {
        base
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var base: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(Color.vexPanelStrong.opacity(0.18))
                .background(.ultraThinMaterial)
                .overlay(glassTint)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(glassTint)
                .overlay(Color.black.opacity(0.12))
        }
    }

    private var glassTint: some View {
        LinearGradient(
            colors: [
                Color.vexCyan.opacity(0.10),
                Color.vexPanelStrong.opacity(0.34),
                Color.black.opacity(0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct CodexSidebarRow: View {
    let icon: String
    let title: String
    let detail: String?
    let trailing: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.vexText : Color.vexMuted)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.vexText : Color.vexSecondaryText)
                    .lineLimit(1)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, detail == nil ? 7 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
