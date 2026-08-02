import SwiftUI

enum ServerSidebarKeyboard {
    static let autoID = "__auto__"

    static func candidates(
        locations: [VpnLocation],
        includesAuto: Bool
    ) -> [String] {
        let availableIDs = locations
            .filter(ServerSidebarCatalog.isAvailable)
            .map(\.id)
        return (includesAuto ? [autoID] : []) + availableIDs
    }

    static func normalizedSelection(
        _ selection: String?,
        candidates: [String]
    ) -> String? {
        guard !candidates.isEmpty else { return nil }
        guard let selection, candidates.contains(selection) else {
            return candidates.first
        }
        return selection
    }
}

struct ServerPickerRow: View {
    let systemName: String
    let title: String
    let subtitle: String
    let trailing: String?
    let selected: Bool
    let keyboardFocused: Bool
    let favorite: Bool
    let favoriteVisible: Bool
    let actionDisabled: Bool
    let favoriteDisabled: Bool
    let disabledReason: String?
    let action: () -> Void
    let onFavorite: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(selected ? Color.vexCyanLight : Color.vexCyan)
                        .frame(width: 26)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(Color.vexText)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.vexSecondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 5)

                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 9.5, weight: .black, design: .rounded))
                            .foregroundStyle(selected ? Color.vexCyanLight : Color.vexSecondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.vexCyan)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(actionDisabled)
            .help(disabledReason ?? "")
            .accessibilityHint(disabledReason ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if favoriteVisible {
                Button(action: onFavorite) {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(favorite ? Color.vexCyanLight : Color.vexMuted)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(favoriteDisabled)
                .help(favorite ? "Убрать из избранного" : "Добавить в избранное")
                .accessibilityLabel(
                    favorite
                        ? "Убрать \(title) из избранного"
                        : "Добавить \(title) в избранное"
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    keyboardFocused ? Color.vexCyan.opacity(0.52) : Color.clear,
                    lineWidth: 1
                )
        }
        .opacity(actionDisabled && favoriteDisabled ? 0.58 : (actionDisabled ? 0.76 : 1))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: keyboardFocused)
        .accessibilityElement(children: .contain)
    }

    private var rowFill: Color {
        if selected {
            return Color.vexCyan.opacity(0.10)
        }
        if keyboardFocused || isHovering {
            return Color.vexPanelStrong.opacity(0.46)
        }
        return Color.clear
    }
}

struct ServerPickerEmptyRow: View {
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        if isLoading {
            ServerSidebarLoadingRow()
        } else if let errorMessage {
            HStack(spacing: 10) {
                PanelIcon(systemName: "wifi.exclamationmark", size: 36, iconSize: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Не удалось загрузить серверы")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(Color.vexText)
                    Text("Проверьте интернет и попробуйте снова.")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color.vexCyan)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Повторить")
                .accessibilityLabel("Повторить загрузку серверов")
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 66)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.vexPanel.opacity(0.66))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.orange.opacity(0.24), lineWidth: 1)
            }
            .help(errorMessage)
        } else {
            ServerPickerMessageRow(
                systemName: "server.rack",
                title: "Список серверов недоступен",
                subtitle: "Попробуйте обновить список позже."
            )
        }
    }
}

struct ServerSidebarLoadingRow: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.vexCyan.opacity(0.14))
                    .frame(width: 38, height: 38)
                    .scaleEffect(isPulsing && !accessibilityReduceMotion ? 1.16 : 0.92)
                    .opacity(isPulsing && !accessibilityReduceMotion ? 0.38 : 0.82)

                VEXMiniSpinner()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Загружаем серверы")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(Color.vexText)
                Text("Подгружаем доступные серверы VEX")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vexSecondaryText)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.vexCyan.opacity(0.86 - Double(index) * 0.18))
                        .frame(width: 4, height: 4)
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.vexPanel.opacity(0.66))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.vexCyan.opacity(0.16), lineWidth: 1)
        }
        .onAppear {
            guard !accessibilityReduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Загружаем серверы. Подгружаем доступные серверы VEX.")
    }
}

struct ServerPickerMessageRow: View {
    let systemName: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            PanelIcon(systemName: systemName, size: 36, iconSize: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(Color.vexText)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vexSecondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.vexPanel.opacity(0.66))
        )
    }
}
