import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel
    @State private var selection: AppSection = .home

    init(initialSelection: AppSection = .home) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        Group {
            if appState.isAuthenticated || focusPulseUIPreview {
                desktopLayout
            } else if selection == .settings {
                unauthenticatedSettingsLayout
            } else {
                signInLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background {
            WindowIntelligenceGlow(
                isActive: connectionAnimationActive
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: VEXSettingsWindow.openNotification)) { notification in
            guard let rawValue = notification.userInfo?[VEXSettingsWindow.sectionUserInfoKey] as? String,
                  let section = AppSection(rawValue: rawValue) else {
                selection = .settings
                return
            }
            selection = section
        }
        .onChange(of: selection) { _, nextSelection in
            if nextSelection != .home {
                VEXServerSidebarWindow.close()
            }
        }
    }

    private var desktopLayout: some View {
        ZStack {
            VEXBackground(selection: selection)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            WindowDragSurface()
                .accessibilityHidden(true)

            authenticatedContent
                .id(selection)
                .contentTransition(.opacity)
                .transition(sectionTransition)
                .animation(sectionTransitionAnimation, value: selection)

            VEXScrollEdgeBlur(edge: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(25)

            VEXScrollEdgeBlur(edge: .bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(5)

            FocusPulseWindowHeader(
                pageTitle: selection.headerTitle,
                serverStatus: serverStatus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .zIndex(30)

            FocusPulseNavigationDock(
                selection: $selection,
                availableUpdateVersion: appState.availableNativeUpdateVersion
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14)
                .zIndex(10)

            VEXVersionLabel()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 20)
                .padding(.bottom, 20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(20)

            if selection == .home {
                VEXWebsiteLink()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    .zIndex(20)
            }

        }
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        if selection == .home {
            HomePanel(onShowServers: VEXServerSidebarWindow.toggle)
                .padding(.horizontal, 30)
                .padding(.top, 82)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if selection == .support {
            SupportPanel()
                .frame(maxWidth: 760, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 62)
                .padding(.bottom, 110)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                selectedPanel
                    .frame(maxWidth: contentMaxWidth)
                    .padding(.horizontal, 30)
                    .padding(.top, 72)
                    .padding(.bottom, 110)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var connectionAnimationActive: Bool {
        if focusPulseAnimationPreview {
            return true
        }

        return FocusPulsePresentation.shouldAnimateConnection(
            status: helper.status.state,
            isBusy: appState.isVpnBusy
        )
    }

    private var focusPulseAnimationPreview: Bool {
        VEXPreviewMode.isAnimationPreview
    }

    private var focusPulseUIPreview: Bool {
        VEXPreviewMode.isEnabled
    }

    private var contentMaxWidth: CGFloat {
        selection == .home ? 1080 : 680
    }

    private var sectionTransition: AnyTransition {
        guard !accessibilityReduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .scale(scale: 0.985))
        )
    }

    private var sectionTransitionAnimation: Animation {
        accessibilityReduceMotion
            ? .linear(duration: 0.01)
            : .snappy(duration: 0.34, extraBounce: 0.02)
    }

    private var signInLayout: some View {
        ZStack {
            VEXBackground()
                .allowsHitTesting(false)
            SignInPanel()
                .frame(maxWidth: 430)
                .padding(.horizontal, 26)

            FocusPulseWindowHeader(
                pageTitle: nil,
                serverStatus: .unknown
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            FocusPulseNavigationDock(
                selection: $selection,
                availableUpdateVersion: appState.availableNativeUpdateVersion,
                showsAuthenticatedSections: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)
        }
    }

    private var unauthenticatedSettingsLayout: some View {
        ZStack {
            VEXBackground()
                .allowsHitTesting(false)

            WindowDragSurface()
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        Button {
                            selection = .home
                        } label: {
                            Label("Назад", systemImage: "chevron.left")
                        }
                        .buttonStyle(.vexGlass)
                        Spacer()
                    }

                    VEXSettingsView()
                        .frame(maxWidth: 560)
                }
                .padding(.horizontal, 28)
                .padding(.top, 64)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            FocusPulseWindowHeader(
                pageTitle: AppSection.settings.headerTitle,
                serverStatus: .unknown
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            FocusPulseNavigationDock(
                selection: $selection,
                availableUpdateVersion: appState.availableNativeUpdateVersion,
                showsAuthenticatedSections: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selection {
        case .home:
            HomePanel(onShowServers: VEXServerSidebarWindow.toggle)
        case .account:
            AccountPanel()
        case .support:
            SupportPanel()
        case .settings:
            VEXSettingsView()
        }
    }

    private var serverStatus: FocusPulseServerStatus {
        FocusPulsePresentation.serverStatus(
            locations: appState.locations,
            isAuthenticated: appState.isAuthenticated,
            isLoading: appState.isLoading
        )
    }
}

private struct VEXVersionLabel: View {
    var body: some View {
        Text("VEX \(VEXAppInfo.version) · build \(VEXAppInfo.buildNumber)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.vexSecondaryText.opacity(0.72))
    }
}

private struct VEXWebsiteLink: View {
    private static let websiteURL = URL(string: "https://vexguard.app")!

    var body: some View {
        Link(destination: Self.websiteURL) {
            HStack(spacing: 6) {
                Text("vexguard.app")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .black))
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.vexCyanLight.opacity(0.82))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Открыть сайт VEX")
        .accessibilityLabel("Открыть сайт VEX")
    }
}

private struct VEXScrollEdgeBlur: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    colors: edge == .top
                        ? [.black, .black.opacity(0.72), .clear]
                        : [.clear, .black.opacity(0.72), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: edge == .top ? 68 : 104)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
