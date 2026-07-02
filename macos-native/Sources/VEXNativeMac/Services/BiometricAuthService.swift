import Foundation
import LocalAuthentication

struct BiometricAuthAvailability: Equatable {
    var isAvailable: Bool
    var label: String
}

struct BiometricAuthService {
    func availability() -> BiometricAuthAvailability {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let label: String
        switch context.biometryType {
        case .touchID:
            label = "Touch ID"
        case .faceID:
            label = "Face ID"
        case .opticID:
            label = "Optic ID"
        default:
            label = "биометрии"
        }
        return BiometricAuthAvailability(isAvailable: available, label: label)
    }

    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        context.localizedFallbackTitle = "Пароль"
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Подтвердите личность, чтобы открыть сохраненную сессию VEX."
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
