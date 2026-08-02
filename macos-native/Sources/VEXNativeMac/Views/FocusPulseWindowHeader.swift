import AppKit
import SwiftUI

struct FocusPulseWindowHeader: View {
    let pageTitle: String?
    let serverStatus: FocusPulseServerStatus

    @State private var isHoveringWindowControls = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                windowControl(
                    title: "Закрыть",
                    systemName: "xmark",
                    color: Color(red: 1.00, green: 0.35, blue: 0.38),
                    action: WindowChromeActions.performClose
                )
                windowControl(
                    title: "Свернуть",
                    systemName: "minus",
                    color: Color(red: 1.00, green: 0.75, blue: 0.16),
                    action: { WindowChromeActions.miniaturize() }
                )
                windowControl(
                    title: "Развернуть",
                    systemName: "plus",
                    color: Color(red: 0.18, green: 0.78, blue: 0.35),
                    action: { WindowChromeActions.zoom() }
                )
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHoveringWindowControls = hovering
                }
            }

            HStack(spacing: 8) {
                Text("VEX")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(Color.vexCyanLight)

                Circle()
                    .fill(serverStatusColor)
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: serverStatusGlow,
                        radius: 5
                    )

                if let pageTitle {
                    Text(pageTitle)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(Color.vexText.opacity(0.84))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(headerAccessibilityLabel)

            Spacer()
        }
        .animation(.easeOut(duration: 0.18), value: pageTitle)
        .animation(.easeOut(duration: 0.18), value: serverStatus)
        .padding(.leading, 22)
        .padding(.trailing, 16)
        .frame(height: 44)
        .background {
            WindowDragSurface()
                .accessibilityHidden(true)
        }
    }

    private var serverStatusColor: Color {
        switch serverStatus {
        case .unknown, .checking:
            return Color.vexMuted
        case .available:
            return Color(red: 0.18, green: 0.78, blue: 0.35)
        case .degraded:
            return Color(red: 1.00, green: 0.75, blue: 0.16)
        case .unavailable:
            return Color(red: 1.00, green: 0.35, blue: 0.38)
        }
    }

    private var serverStatusGlow: Color {
        switch serverStatus {
        case .available, .degraded, .unavailable:
            return serverStatusColor.opacity(0.72)
        case .unknown, .checking:
            return .clear
        }
    }

    private var headerAccessibilityLabel: String {
        let title = pageTitle.map { "VEX, \($0)" } ?? "VEX"
        return "\(title). \(serverStatus.title)"
    }

    private func windowControl(
        title: String,
        systemName: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                Circle()
                    .stroke(Color.black.opacity(0.18), lineWidth: 0.6)
                Image(systemName: systemName)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.66))
                    .opacity(isHoveringWindowControls ? 1 : 0)
            }
            .frame(width: 13, height: 13)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

@MainActor
enum WindowChromeActions {
    private static var restoreFrames: [ObjectIdentifier: NSRect] = [:]

    static func performClose() {
        focusPulseWindow?.orderOut(nil)
    }

    static func miniaturize(window explicitWindow: NSWindow? = nil) {
        guard let window = explicitWindow ?? focusPulseWindow else { return }
        window.miniaturize(nil)
    }

    static func zoom(window explicitWindow: NSWindow? = nil) {
        guard
            let window = explicitWindow ?? focusPulseWindow,
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else {
            return
        }

        let identifier = ObjectIdentifier(window)
        if let restoreFrame = restoreFrames.removeValue(forKey: identifier) {
            window.setFrame(restoreFrame, display: true, animate: true)
        } else {
            restoreFrames[identifier] = window.frame
            window.setFrame(visibleFrame, display: true, animate: true)
        }
    }

    private static var focusPulseWindow: NSWindow? {
        NSApp.windows.first { window in
            window.title == "VEX"
                && window.frame.width >= 800
        } ?? NSApp.keyWindow ?? NSApp.mainWindow
    }
}
