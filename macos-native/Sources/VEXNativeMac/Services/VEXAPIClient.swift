import Foundation

struct VEXAPIClient {
    var baseURL = URL(string: ProcessInfo.processInfo.environment["VEX_API_BASE_URL"] ?? "https://vexguard.app")!

    func me(accessToken: String) async throws -> VEXUser {
        try await json("/v1/auth/me", accessToken: accessToken)
    }

    func login(email: String, password: String) async throws -> AuthSession {
        let response: AuthResponse = try await json(
            "/v1/auth/login",
            method: "POST",
            body: [
                "email": email,
                "password": password,
                "remember_me": true,
                "device_session": true,
            ]
        )
        return response.sessionValue
    }

    func requestEmailOTP(email: String) async throws -> EmailOTPChallengeResponse {
        try await json(
            "/v1/auth/email-otp/request",
            method: "POST",
            body: [
                "email": email,
            ]
        )
    }

    func confirmEmailOTP(email: String, challengeID: String, code: String) async throws -> AuthSession {
        let response: AuthResponse = try await json(
            "/v1/auth/email-otp/confirm",
            method: "POST",
            body: [
                "email": email,
                "challenge_id": challengeID,
                "code": code,
                "remember_me": true,
                "device_session": true,
            ]
        )
        return response.sessionValue
    }

    func refreshSession(accessToken: String) async throws -> AuthSession {
        let response: AuthResponse = try await json(
            "/v1/auth/refresh",
            method: "POST",
            accessToken: accessToken
        )
        return response.sessionValue
    }

    func exchangeAppAuthCode(code: String, codeVerifier: String) async throws -> AuthSession {
        let response: AuthResponse = try await json(
            "/v1/auth/token",
            method: "POST",
            body: [
                "code": code,
                "code_verifier": codeVerifier,
            ]
        )
        return response.sessionValue
    }

    func vpnLocations(accessToken: String) async throws -> [VpnLocation] {
        let locations: [VpnLocation] = try await json("/v1/locations", accessToken: accessToken)
        return locations.filter { $0.healthyNodes > 0 && $0.availability != "retired" }
    }

    func entitlement(accessToken: String) async throws -> Entitlement {
        try await json("/v1/billing/entitlement", accessToken: accessToken)
    }

    func billingPlans() async throws -> [BillingPlan] {
        try await json("/v1/billing/plans")
    }

    func checkoutSession(accessToken: String, plan: BillingPlanOption) async throws -> CheckoutSession {
        try await json(
            "/v1/billing/checkout-session",
            method: "POST",
            accessToken: accessToken,
            body: [
                "plan_id": plan.id,
                "provider": plan.provider,
                "return_url": "\(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/billing/mobile-return?status=success",
                "failed_url": "\(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/billing/mobile-return?status=failed",
            ],
            idempotencyKey: "native-macos-checkout-\(plan.id)-\(Int(Date().timeIntervalSince1970 * 1000))"
        )
    }

    func cancelSubscription(accessToken: String) async throws -> Entitlement {
        try await json(
            "/v1/billing/subscription/cancel",
            method: "POST",
            accessToken: accessToken,
            idempotencyKey: "native-macos-subscription-cancel-\(Int(Date().timeIntervalSince1970 * 1000))"
        )
    }

    func portalSession(accessToken: String) async throws -> BillingPortalSession {
        try await json("/v1/billing/portal-session", accessToken: accessToken)
    }

    func billingPayments(accessToken: String, limit: Int = 24) async throws -> [BillingPayment] {
        let safeLimit = min(max(limit, 1), 100)
        return try await json("/v1/billing/payments?\(queryString([URLQueryItem(name: "limit", value: String(safeLimit))]))", accessToken: accessToken)
    }

    func vpnDevices(accessToken: String) async throws -> [VpnDevice] {
        try await json("/v1/devices", accessToken: accessToken)
    }

    func vpnDeviceUsage(accessToken: String) async throws -> [VpnDeviceUsage] {
        let response: VpnDeviceUsageResponse = try await json("/v1/devices/usage", accessToken: accessToken)
        return response.usage ?? []
    }

    func registerNativeDevice(
        accessToken: String,
        externalDeviceId: String,
        publicKey: String,
        keyEpoch: Int,
        locationId: String,
        identityFields: [String: String] = [:]
    ) async throws -> VpnDevice {
        var body: [String: Any] = [
            "device_id": externalDeviceId,
            "installation_id": externalDeviceId,
            "device_name": "Mac",
            "platform": "macos",
            "app_version": VEXAppInfo.version,
            "protocol": "amneziawg",
            "location": locationId,
            "public_key": publicKey,
            "key_epoch": keyEpoch,
        ]
        identityFields.forEach { body[$0.key] = $0.value }
        let response: NativeDeviceRegistrationResponse = try await json(
            "/v1/devices/register",
            method: "POST",
            accessToken: accessToken,
            body: body,
            idempotencyKey: "native-register-\(externalDeviceId)"
        )
        return response.device
    }

    func deviceIdentityChallenge(
        accessToken: String,
        installationId: String,
        purpose: String = "register"
    ) async throws -> DeviceIdentityChallenge {
        try await json(
            "/v1/devices/identity-challenge",
            method: "POST",
            accessToken: accessToken,
            body: [
                "installation_id": installationId,
                "purpose": purpose,
            ]
        )
    }

    func rotateManagedVpnKey(accessToken: String, deviceId: String, keyPair: WireGuardKeyPair, prefix: String) async throws -> VpnDevice {
        let response: NativeDeviceRegistrationResponse = try await json(
            "/v1/vpn/rotate-key",
            method: "POST",
            accessToken: accessToken,
            body: [
                "device_id": deviceId,
                "public_key": keyPair.publicKey,
                "key_epoch": keyPair.keyEpoch,
            ],
            idempotencyKey: "\(prefix)-\(deviceId)-\(keyPair.keyEpoch)-\(keyPair.publicKey)"
        )
        return response.device
    }

    func managedVpnProfile(
        accessToken: String,
        deviceId: String,
        locationId: String,
        routingMode: VpnRoutingMode,
        bypassRegion: String?,
        knownVersion: Int?
    ) async throws -> ManagedVpnProfile {
        var query = [
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "location", value: locationId),
            URLQueryItem(name: "routing_mode", value: routingMode.rawValue),
            URLQueryItem(name: "platform", value: "macos"),
        ]
        if let bypassRegion {
            query.append(URLQueryItem(name: "bypass_region", value: bypassRegion))
        }
        if let knownVersion, knownVersion > 0 {
            query.append(URLQueryItem(name: "known_version", value: String(knownVersion)))
        }
        return try await json("/v1/vpn/profile?\(queryString(query))", accessToken: accessToken)
    }

    func reportVpnConnect(accessToken: String, tunnel: PreparedTunnel) async {
        guard !tunnel.device.id.isEmpty else { return }
        var body: [String: Any] = [
            "device_id": tunnel.device.id,
            "client_time": ISO8601DateFormatter().string(from: Date()),
        ]
        if let profileVersion = tunnel.profileVersion {
            body["profile_version"] = profileVersion
        }
        if let proto = tunnel.device.protocol {
            body["protocol"] = proto
        }
        try? await raw(
            "/v1/vpn/connect",
            method: "POST",
            accessToken: accessToken,
            body: body
        )
    }

    func reportVpnDisconnect(accessToken: String, tunnel: PreparedTunnel?, reason: String) async {
        guard let tunnel, !tunnel.device.id.isEmpty else { return }
        var body: [String: Any] = [
            "device_id": tunnel.device.id,
            "reason": reason,
        ]
        if let profileVersion = tunnel.profileVersion {
            body["profile_version"] = profileVersion
        }
        try? await raw(
            "/v1/vpn/disconnect",
            method: "POST",
            accessToken: accessToken,
            body: body
        )
    }

    func submitClientDiagnostics(accessToken: String, report: ClientDiagnosticsReport) async throws {
        try await raw(
            "/v1/diagnostics/client",
            method: "POST",
            accessToken: accessToken,
            body: try report.dictionary()
        )
    }

    func supportTickets(accessToken: String) async throws -> [SupportTicket] {
        try await json("/v1/support-tickets", accessToken: accessToken)
    }

    func supportWebSocketURL(accessToken: String) async throws -> URL {
        let payload: SupportSocketTicketResponse = try await json(
            "/v1/support-ws-ticket",
            accessToken: accessToken
        )
        guard let ticket = payload.ticket?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ticket.isEmpty else {
            throw VEXAPIError.invalidResponse
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/v1/support-ws"
        components?.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let url = components?.url else {
            throw VEXAPIError.invalidResponse
        }
        return url
    }

    func createSupportTicket(accessToken: String, subject: String, message: String) async throws -> SupportTicket {
        try await json(
            "/v1/support-tickets",
            method: "POST",
            accessToken: accessToken,
            body: [
                "subject": subject,
                "message": message,
                "source": "macos-native",
            ],
            idempotencyKey: "native-support-\(UUID().uuidString)"
        )
    }

    func appUpdateCheck() async throws -> AppUpdateCheckResult {
        var result: AppUpdateCheckResult = try await json(
            "/v1/app/update/check",
            method: "POST",
            body: [
                "platform": "macos",
                "appVersion": VEXAppInfo.version,
                "buildNumber": VEXAppInfo.buildNumber,
                "channel": VEXAppInfo.channel,
                "coreVersion": VEXAppInfo.coreVersion,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "arch": nativeArch,
                "apiClientVersion": VEXAppInfo.apiClientVersion,
                "configSchemaVersion": VEXAppInfo.configSchemaVersion,
            ]
        )
        result.downloadUrl = absolutize(result.downloadUrl)
        return result
    }

    func appRemoteConfig() async throws -> AppRemoteConfig {
        try await json(
            "/v1/app/remote-config",
            method: "POST",
            body: [
                "platform": "macos",
                "appVersion": VEXAppInfo.version,
                "buildNumber": VEXAppInfo.buildNumber,
                "channel": VEXAppInfo.channel,
                "coreVersion": VEXAppInfo.coreVersion,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "arch": nativeArch,
                "apiClientVersion": VEXAppInfo.apiClientVersion,
                "configSchemaVersion": VEXAppInfo.configSchemaVersion,
            ]
        )
    }

    private var nativeArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private func absolutize(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value
        }
        if value.hasPrefix("/") {
            return "\(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(value)"
        }
        return "\(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(value)"
    }

    private func raw(
        _ path: String,
        method: String = "GET",
        accessToken: String? = nil,
        body: [String: Any]? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        let _: EmptyResponse = try await json(path, method: method, accessToken: accessToken, body: body, idempotencyKey: idempotencyKey)
    }

    private func json<T: Decodable>(
        _ path: String,
        method: String = "GET",
        accessToken: String? = nil,
        body: [String: Any]? = nil,
        idempotencyKey: String? = nil
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))") else {
            throw VEXAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("macos", forHTTPHeaderField: "X-Vex-Platform")
        request.setValue(VEXAppInfo.version, forHTTPHeaderField: "X-Vex-App-Version")
        request.setValue(String(VEXAppInfo.buildNumber), forHTTPHeaderField: "X-Vex-Build-Number")
        request.setValue(VEXAppInfo.channel, forHTTPHeaderField: "X-Vex-Channel")
        request.setValue(VEXAppInfo.apiClientVersion, forHTTPHeaderField: "X-Vex-API-Client-Version")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VEXAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VEXAPIError.http(status: http.statusCode, message: apiErrorMessage(data))
        }
        if T.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! T
        }
        if T.self == String.self, let text = String(data: data, encoding: .utf8) as? T {
            return text
        }
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func queryString(_ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }

    private func apiErrorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "HTTP request failed"
    }
}

private struct NativeDeviceRegistrationResponse: Decodable {
    var device: VpnDevice
}

private struct SupportSocketTicketResponse: Decodable {
    var ticket: String?
}

private struct EmptyResponse: Decodable {}

struct EmailOTPChallengeResponse: Decodable {
    var challengeID: String
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case expiresAt = "expires_at"
    }
}

private struct AuthResponse: Decodable {
    var user: VEXUser
    var session: AuthSessionPayload

    var sessionValue: AuthSession {
        AuthSession(user: user, accessToken: session.accessToken, expiresAt: session.expiresAt, refreshToken: nil)
    }
}

private struct AuthSessionPayload: Decodable {
    var accessToken: String
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }
}

enum VEXAPIError: LocalizedError {
    case invalidResponse
    case http(status: Int, message: String)

    var isUnauthorized: Bool {
        if case .http(let status, _) = self {
            return status == 401
        }
        return false
    }

    var isRateLimited: Bool {
        if case .http(let status, _) = self {
            return status == 429
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Некорректный ответ API."
        case .http(let status, let message):
            return "HTTP \(status): \(message)"
        }
    }
}

extension Error {
    var isUnauthorizedAPIError: Bool {
        (self as? VEXAPIError)?.isUnauthorized == true
    }

    var isRateLimitedAPIError: Bool {
        (self as? VEXAPIError)?.isRateLimited == true
    }

    var isTimeout: Bool {
        if let urlError = self as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }
}
