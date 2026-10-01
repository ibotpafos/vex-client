import Foundation

// This executable never connects to a helper or a real HTTP server, and uses
// only temporary files and an in-memory keychain.
private final class MemoryKeychain: VEXSessionKeychain {
    var values: [String: String] = [:]
    func string(for account: String, allowAuthenticationUI: Bool) -> String? { values[account] }
    func setString(_ value: String, for account: String, requiresBiometricAuthentication: Bool) throws { values[account] = value }
    func delete(account: String) throws { values.removeValue(forKey: account) }
    func contains(account: String) -> Bool { values[account] != nil }
}

private final class MockHTTP: URLProtocol {
    static var responseStatus = 200
    static var responseBody = ""
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct OfflineHarness {
    @MainActor static func main() async throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(Entitlement.self, from: Data(#"{"active":true}"#.utf8))
        precondition(legacy.vpnAccess && !legacy.canBuyDeviceAddon && legacy.remainingDeviceSlots == 0)
        let modern = try decoder.decode(Entitlement.self, from: Data(#"{"active":true,"vpn_access":false,"device_limit":5,"active_devices":6,"addon_device_slots":2,"can_buy_device_addon":true,"device_addon_price_minor":9900}"#.utf8))
        precondition(!modern.vpnAccess && modern.remainingDeviceSlots == 0 && modern.addonDeviceSlots == 2)
        precondition(modern.deviceAddonPriceMinor == 9900)
        let nullFields = try decoder.decode(Entitlement.self, from: Data(#"{"active":null,"device_limit":null,"active_devices":null}"#.utf8))
        precondition(!nullFields.active && nullFields.deviceLimit == 0)
        print("PASS: old/new/null entitlement contracts and device slot bounds")

        let disconnected = "state=disconnected route_ok=false socket_exists=false"
        precondition(HelperDisconnectConfirmation.isExplicitlyDisconnected(disconnected))
        for response in ["", "ok", "error: unauthorized", "state=unknown", "state=disconnected", disconnected + " operation_in_progress=true", disconnected + " state=connected"] {
            precondition(!HelperDisconnectConfirmation.isExplicitlyDisconnected(response))
        }
        print("PASS: teardown rejects malformed, incomplete, duplicate and busy helper responses")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vex-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = AppSensitiveFileStore(directoryURL: folder)
        let native = MemoryKeychain(), previous = MemoryKeychain()
        let session = AuthSession(user: VEXUser(id: "fixture", email: "fixture@example.invalid", status: "active"), accessToken: "synthetic-token", expiresAt: nil, refreshToken: nil)
        try files.setData(JSONEncoder().encode(session), for: "vex.auth.session.v1")
        let store = VEXSessionStore(fileStore: files, nativeKeychain: native, legacyKeychain: previous)
        precondition(store.loadSession(allowAuthenticationUI: false, requiresBiometricAuthentication: true) == nil)
        precondition(files.data(for: "vex.auth.session.v1") == nil && native.contains(account: "vex.auth.session.v1"))
        precondition(store.loadSession(allowAuthenticationUI: true, requiresBiometricAuthentication: true) == session)
        try store.clearSession()
        precondition(store.loadSession() == nil && !store.hasStoredNativeSession())
        print("PASS: session migration removes plaintext; logout cannot restore legacy credentials")

        var parser = CustomerSSEWireDecoder()
        let event = "event: customer.change\nid: devices:7\ndata: {\"domain\":\"devices\",\"version\":7}\n\n"
        let decoded = Data(event.utf8).flatMap { parser.append($0) }
        precondition(decoded.count == 1 && decoded[0].id == "devices:7")
        precondition(CustomerRealtimeMetadata.parse(type: decoded[0].type, data: decoded[0].data)?.domains == ["devices"])
        precondition(CustomerRealtimeMetadata.parse(type: "customer.change", data: #"{"domain":"unknown","version":1}"#) == nil)
        precondition(CustomerRealtimeService.responseAction(statusCode: 401) == .refreshSession)
        precondition(CustomerRealtimeService.reconnectDelay(attempt: 100) == 30)
        print("PASS: realtime idle-frame dispatch, metadata filtering, auth recovery and bounded backoff")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        let api = VEXAPIClient(urlSession: network, baseURL: URL(string: "https://fixture.invalid")!)
        MockHTTP.responseBody = #"{"id":"device-fixture","name":"My Mac","status":"active"}"#
        let renamed = try await api.renameVpnDevice(accessToken: "fixture-token", deviceId: "device-fixture", name: "My Mac")
        precondition(renamed.name == "My Mac")
        precondition(MockHTTP.requests.last?.httpMethod == "PATCH")
        precondition(MockHTTP.requests.last?.url?.path == "/v1/devices/device-fixture")
        precondition(MockHTTP.requests.last?.value(forHTTPHeaderField: "X-Vex-Platform") == "macos")
        MockHTTP.responseStatus = 204; MockHTTP.responseBody = ""
        try await api.deleteVpnDevice(accessToken: "fixture-token", deviceId: "device-fixture")
        precondition(MockHTTP.requests.last?.httpMethod == "DELETE")
        MockHTTP.responseStatus = 200; MockHTTP.responseBody = "[]"
        let addons = try await api.billingDeviceAddons(accessToken: "fixture-token")
        precondition(addons.isEmpty)
        MockHTTP.responseStatus = 403; MockHTTP.responseBody = #"{"error":{"code":"client_session_forbidden","message":"Use web account"}}"#
        do {
            _ = try await api.billingDeviceAddons(accessToken: "fixture-token")
            preconditionFailure("403 was accepted")
        } catch let error as VEXAPIError { precondition(error.isForbidden && !error.isUnauthorized) }
        MockHTTP.responseStatus = 201; MockHTTP.responseBody = #"{"id":"checkout-fixture","url":"https://fixture.invalid/pay"}"#
        let checkout = try await api.createDeviceAddonCheckout(accessToken: "fixture-token", returnURL: URL(string: "https://fixture.invalid/ok")!, failedURL: URL(string: "https://fixture.invalid/fail")!)
        precondition(checkout.id == "checkout-fixture")
        precondition(MockHTTP.requests.last?.value(forHTTPHeaderField: "Idempotency-Key")?.hasPrefix("native-device-addon-") == true)
        print("PASS: intercepted device rename/delete, empty 204, add-ons, scoped 403 and checkout contracts; external requests=0")
    }
}
