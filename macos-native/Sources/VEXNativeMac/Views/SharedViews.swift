import AppKit
import SwiftUI

struct BundleImage: View {
    let name: String

    var body: some View {
        if let image = NSImage(named: name) ?? Bundle.module.image(name) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }
}

struct GlassPanel<Content: View>: View {
    let cornerRadius: CGFloat
    var interactive = false
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        let radius = cornerRadius

        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint == nil ? Color.vexPanel.opacity(0.62) : Color.vexPanelStrong.opacity(0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke((tint ?? Color.vexBorder).opacity(tint == nil ? 0.12 : 0.24), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(interactive ? 0.18 : 0.10), radius: interactive ? 14 : 8, y: 4)
    }
}

struct CleanPanel<Content: View>: View {
    var cornerRadius: CGFloat = 14
    var padding: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.vexPanel.opacity(0.50))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

struct PageTitleBlock: View {
    let title: String
    let subtitle: String?
    var trailing: AnyView?

    init(title: String, subtitle: String? = nil, trailing: AnyView? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(Color.vexText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let trailing {
                trailing
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PanelIcon: View {
    let systemName: String
    var size: CGFloat = 46
    var iconSize: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.vexCyan.opacity(0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.vexCyan.opacity(0.20), lineWidth: 1)
                )
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(Color.vexCyan)
        }
        .frame(width: size, height: size)
    }
}

struct VEXStatusBadge: View {
    enum Tone {
        case good
        case warning
        case neutral
        case danger
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .good:
            return Color.vexCyanLight
        case .warning:
            return Color(red: 1.0, green: 0.76, blue: 0.36)
        case .danger:
            return Color(red: 1.0, green: 0.48, blue: 0.48)
        case .neutral:
            return Color.vexSecondaryText
        }
    }

    private var background: Color {
        switch tone {
        case .good:
            return Color.vexCyan.opacity(0.16)
        case .warning:
            return Color(red: 1.0, green: 0.62, blue: 0.18).opacity(0.15)
        case .danger:
            return Color(red: 1.0, green: 0.22, blue: 0.22).opacity(0.14)
        case .neutral:
            return Color.white.opacity(0.08)
        }
    }
}

struct HeaderIconButton: View {
    let systemName: String
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: highlighted ? 17 : 27, weight: .bold))
                .foregroundStyle(highlighted ? Color.vexBackground : Color.vexText.opacity(0.92))
                .frame(width: highlighted ? 34 : 46, height: highlighted ? 34 : 46)
                .background(
                    Circle()
                        .fill(highlighted ? Color.vexCyan : Color.clear)
                )
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
    }
}

struct VEXGlassButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(prominent ? Color.vexBackground : Color.vexText.opacity(configuration.isPressed ? 0.72 : 0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(background(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(prominent ? Color.clear : Color.white.opacity(0.10), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> Color {
        if prominent {
            return Color.vexCyan.opacity(isPressed ? 0.82 : 0.96)
        }
        return Color.white.opacity(isPressed ? 0.12 : 0.07)
    }
}

extension ButtonStyle where Self == VEXGlassButtonStyle {
    static var vexGlass: VEXGlassButtonStyle {
        VEXGlassButtonStyle(prominent: false)
    }

    static var vexProminentGlass: VEXGlassButtonStyle {
        VEXGlassButtonStyle(prominent: true)
    }
}
