import Foundation
import Security

/// The APNs environment is read from this executable's signing entitlements,
/// never inferred from a bearer token, build version, or editable preference.
enum NativeAPNsCapability {
    static var signedEnvironment: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return nil }
        let value = entitlements["com.apple.developer.aps-environment"] as? String
        return value == "development" || value == "production" ? value : nil
    }
}

@MainActor
final class NativePushAPIRegistrar: NativePushRegistrationRegistrar {
    private let api: VEXAPIClient
    var isCurrent: (NativePushRegistrationRequest) -> Bool = { _ in false }

    init(api: VEXAPIClient = VEXAPIClient()) { self.api = api }

    func registerNativePush(_ request: NativePushRegistrationRequest) async throws {
        guard isCurrent(request) else { throw CancellationError() }
        try await api.registerNativePushToken(accessToken: request.accessToken, deviceID: request.deviceID, token: request.token)
        guard isCurrent(request) else { throw CancellationError() }
    }
}
