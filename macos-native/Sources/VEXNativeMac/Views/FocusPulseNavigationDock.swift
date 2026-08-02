import SwiftUI

struct FocusPulseNavigationDock: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var selection: AppSection
    let availableUpdateVersion: String?
    var showsAuthenticatedSections = true
    @State private var hoveredSection: DockItem?

    var body: some View {
        if #available(macOS 26.0, *), !VEXPreviewMode.isEnabled {
            GlassEffectContainer(spacing: 8) {
                dockButtons
                    .padding(7)
                    .glassEffect(
                        .regular
                            .tint(Color.vexPanelStrong.opacity(0.38))
                            .interactive(),
                        in: .capsule
                    )
            }
            .shadow(color: Color.black.opacity(0.38), radius: 18, y: 9)
        } else {
            legacyDock
        }
    }

    private var legacyDock: some View {
        dockButtons
            .padding(7)
            .background(
                ZStack {
                    Capsule()
                        .fill(.ultraThinMaterial)
                    Capsule()
                        .fill(Color.vexPanelStrong.opacity(0.92))
                }
            )
            .shadow(color: Color.black.opacity(0.38), radius: 18, y: 9)
    }

    private var dockButtons: some View {
        HStack(spacing: 8) {
            dockButton(
                title: AppSection.home.title,
                systemName: "house.fill",
                selected: selection == .home,
                section: .home
            ) {
                selection = .home
            }

            if showsAuthenticatedSections {
                dockButton(
                    title: AppSection.support.title,
                    systemName: "shield.lefthalf.filled",
                    selected: selection == .support,
                    section: .support
                ) {
                    selection = .support
                }

                dockButton(
                    title: AppSection.account.title,
                    systemName: "person.fill",
                    selected: selection == .account,
                    section: .account
                ) {
                    selection = .account
                }
            }

            dockButton(
                title: AppSection.settings.title,
                systemName: "gearshape",
                selected: selection == .settings,
                section: .settings
            ) {
                selection = .settings
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func dockButton(
        title: String,
        systemName: String,
        selected: Bool,
        section: DockItem,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredSection == section

        return Button {
            withAnimation(
                accessibilityReduceMotion
                    ? .linear(duration: 0.01)
                    : .snappy(duration: 0.32, extraBounce: 0.05)
            ) {
                action()
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    selected
                        ? Color.vexBackground
                        : (isHovered ? Color.vexText : Color.vexSecondaryText)
                )
                .frame(width: 46, height: 38)
                .background(
                    ZStack {
                        Capsule()
                            .fill(
                                selected
                                    ? Color.vexCyan
                                    : Color.white.opacity(isHovered ? 0.075 : 0)
                            )

                        if selected || isHovered {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(selected ? 0.28 : 0.12),
                                            Color.clear
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .padding(1)
                        }
                    }
                )
                .overlay(
                    Capsule()
                        .stroke(
                            Color.white.opacity(selected ? 0.22 : (isHovered ? 0.11 : 0)),
                            lineWidth: 0.8
                        )
                )
                .shadow(
                    color: selected
                        ? Color.vexCyan.opacity(0.24)
                        : Color.black.opacity(isHovered ? 0.28 : 0),
                    radius: selected ? 9 : 6,
                    y: selected ? 3 : 4
                )
                .scaleEffect(isHovered ? 1.045 : 1)
                .offset(y: isHovered ? -1.5 : 0)
                .contentShape(Capsule())
                .overlay(alignment: .topTrailing) {
                    if section == .settings, availableUpdateVersion != nil {
                        Circle()
                            .fill(Color.vexCyan)
                            .frame(width: 7, height: 7)
                            .overlay {
                                Circle()
                                    .stroke(Color.vexBackground.opacity(0.9), lineWidth: 1)
                            }
                            .padding(.top, 5)
                            .padding(.trailing, 5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(
                accessibilityReduceMotion
                    ? .linear(duration: 0.01)
                    : .snappy(duration: 0.24, extraBounce: 0.04)
            ) {
                hoveredSection = hovering ? section : nil
            }
        }
        .help(helpText(for: section, fallback: title))
        .accessibilityLabel(helpText(for: section, fallback: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func helpText(for section: DockItem, fallback: String) -> String {
        guard section == .settings, let availableUpdateVersion else {
            return fallback
        }
        return "Настройки. Доступно обновление \(availableUpdateVersion)"
    }
}

private enum DockItem: Hashable {
    case home
    case support
    case account
    case settings
}
