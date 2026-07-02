import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel
    @State private var selection: AppSection = .home

    var body: some View {
        Group {
            if appState.isAuthenticated {
                desktopLayout
            } else if selection == .settings {
                unauthenticatedSettingsLayout
            } else {
                signInLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await helper.refreshStatus() }
                } label: {
                    Label("Обновить статус", systemImage: "arrow.clockwise")
                }

                Button {
                    selection = selection == .settings && !appState.isAuthenticated ? .home : .settings
                } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VEXSettingsWindow.openNotification)) { notification in
            guard let rawValue = notification.userInfo?[VEXSettingsWindow.sectionUserInfoKey] as? String,
                  let section = AppSection(rawValue: rawValue) else {
                selection = .settings
                return
            }
            selection = section
        }
    }

    private var desktopLayout: some View {
        NavigationSplitView {
            VEXSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 315, max: 460)
        } detail: {
            if selection == .support {
                supportDetailLayout
            } else {
                standardDetailLayout
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var standardDetailLayout: some View {
        ScrollView {
            VStack(spacing: 18) {
                if selection == .home {
                    HeaderView()
                }
                selectedPanel
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background {
            VEXBackground()
        }
    }

    private var supportDetailLayout: some View {
        SupportPanel()
            .frame(maxWidth: 430, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                VEXBackground()
            }
    }

    private var signInLayout: some View {
        ZStack {
            VEXBackground()
            SignInPanel()
                .frame(maxWidth: 430)
                .padding(.horizontal, 26)
        }
    }

    private var unauthenticatedSettingsLayout: some View {
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
                    .frame(maxWidth: 430)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background {
            VEXBackground()
        }
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selection {
        case .home:
            HomePanel()
        case .account:
            AccountPanel()
        case .support:
            SupportPanel()
        case .settings:
            VEXSettingsView()
        }
    }
}
