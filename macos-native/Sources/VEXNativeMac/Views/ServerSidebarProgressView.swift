import SwiftUI

struct ServerSidebarSwitchProgress: Equatable {
    enum Phase: Equatable {
        case preparing
        case connecting
        case verifying
        case selected
        case verified
        case failed
    }

    let name: String
    let phase: Phase

    var title: String {
        switch phase {
        case .preparing: return "Выбираем маршрут"
        case .connecting: return "Переключаем VPN"
        case .verifying: return "Проверяем защиту"
        case .selected: return "Сервер выбран"
        case .verified: return "Защита проверена"
        case .failed: return "Переключение не удалось"
        }
    }

    var detail: String {
        switch phase {
        case .preparing: return "Подготавливаем \(name)"
        case .connecting: return "Безопасно переводим соединение"
        case .verifying: return "Подтверждаем защищённый маршрут"
        case .selected: return "\(name) готов к подключению"
        case .verified: return "\(name) подключен и защищён"
        case .failed: return "Проверьте состояние VPN и повторите попытку"
        }
    }

    var activeStep: Int {
        switch phase {
        case .preparing: return 0
        case .connecting, .failed: return 1
        case .verifying, .selected, .verified: return 2
        }
    }

    static func make(
        from operation: ServerSidebarOperationState,
        name: String
    ) -> Self? {
        switch operation {
        case .idle:
            return nil
        case .selected:
            return Self(name: name, phase: .selected)
        case .preparingRoute:
            return Self(name: name, phase: .preparing)
        case .connecting:
            return Self(name: name, phase: .connecting)
        case .verifying:
            return Self(name: name, phase: .verifying)
        case .failed:
            return Self(name: name, phase: .failed)
        case .verified:
            return Self(name: name, phase: .verified)
        }
    }
}

struct ServerSidebarSwitchProgressView: View {
    let progress: ServerSidebarSwitchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(
                    systemName: progress.phase == .failed
                        ? "exclamationmark.triangle.fill"
                        : "bolt.horizontal.circle.fill"
                )
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(progress.phase == .failed ? Color.orange : Color.vexCyan)

                VStack(alignment: .leading, spacing: 1) {
                    Text(progress.title)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(Color.vexText)
                    Text(progress.detail)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.vexSecondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if progress.phase == .preparing
                    || progress.phase == .connecting
                    || progress.phase == .verifying {
                    VEXMiniSpinner()
                }
            }

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(stepColor(index))
                        .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.vexPanel.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    progress.phase == .failed
                        ? Color.orange.opacity(0.30)
                        : Color.vexCyan.opacity(0.20),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.title). \(progress.detail).")
    }

    private func stepColor(_ index: Int) -> Color {
        if progress.phase == .failed, index == progress.activeStep {
            return Color.orange.opacity(0.82)
        }
        return index <= progress.activeStep
            ? Color.vexCyan.opacity(0.82)
            : Color.vexBorder.opacity(0.18)
    }
}
