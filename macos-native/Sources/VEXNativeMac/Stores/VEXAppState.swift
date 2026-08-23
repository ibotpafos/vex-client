import Foundation
import Combine
import SwiftUI

@MainActor
final class VEXAppState: ObservableObject {
    @AppStorage("native.selectedLocationId") private var storedSelectedLocationId = "de"
    @AppStorage("native.serverSidebarFavorites") private var storedServerSidebarFavorites = ""
    @AppStorage("native.serverSidebarFilter") private var storedServerSidebarFilter = ServerSidebarFilter.all.rawValue
    @AppStorage("native.serverSelectionMode") var serverSelectionMode = "auto"
    @AppStorage("native.autoLaunchEnabled") var autoLaunchEnabled = false
    @AppStorage("native.autoServerEnabled") var autoServerEnabled = true
    @AppStorage("native.antiLeakEnabled") var antiLeakEnabled = true
    @AppStorage("native.smartRoutingEnabled") var smartRoutingEnabled = true
    @AppStorage("native.autoRecoveryEnabled") var autoRecoveryEnabled = true
    @AppStorage("native.biometricUnlockRequired") var biometricUnlockRequired = false
    @AppStorage("native.interfaceLanguage") var interfaceLanguage = "ru"

    @Published private(set) var session: AuthSession?
    @Published private(set) var user: VEXUser?
    @Published private(set) var locations: [VpnLocation] = []
    @Published private(set) var supportTickets: [SupportTicket] = []
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var billingSummary: BillingSummary?
    @Published private(set) var billingPayments: [BillingPayment] = []
    @Published private(set) var updateCheck: AppUpdateCheckResult?
    @Published private(set) var remoteConfig: AppRemoteConfig?
    @Published private(set) var activeTunnel: PreparedTunnel?
    @Published private(set) var supportSocketConnected = false
    @Published private(set) var supportSocketReconnecting = false
    @Published private(set) var isAuthBusy = false
    @Published private(set) var isWaitingForWebAuth = false
    @Published private(set) var isBillingBusy = false
    @Published private(set) var isVpnBusy = false
    @Published private(set) var isServerSelectionBusy = false
    @Published private(set) var authError: String?
    @Published private(set) var emailOTPChallengeID: String?
    @Published private(set) var emailOTPChallengeEmail: String?
    @Published private(set) var billingError: String?
    @Published private(set) var biometricAvailability = BiometricAuthAvailability(isAvailable: false, label: "биометрии")
    @Published private(set) var canUnlockStoredSession = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingLocations = false
    @Published private(set) var locationLoadError: String?
    @Published private(set) var lastLocationsRefreshAt: Date?
    @Published private(set) var serverSidebarOperation = ServerSidebarOperationState.idle
    @Published var statusMessage: String?

    private let sessionStore = VEXSessionStore()
    private let api = VEXAPIClient()
    private let billingService = BillingService()
    private let billingSummaryCache = BillingSummaryCache()
    private let diagnosticsService = DiagnosticsService()
    private let autopilotService = VpnAutopilotService()
    private let biometricAuth = BiometricAuthService()
    private let profileService = VPNProfileService()
    private let startupService = StartupService()
    private let nativeUpdater: NativeUpdaterService
    private let authService = PKCEAuthService()
    private let supportSocket = SupportSocketClient()
    private var cancellables: Set<AnyCancellable> = []
    private var webAuthTask: Task<Void, Never>?
    private var profileWarmupTask: Task<Void, Never>?
    private var sessionRefreshTask: (accessToken: String, task: Task<Result<AuthSession, Error>, Never>)?
    private var desiredVpnState: DesiredVpnState = .disconnected
    private var vpnOperationGeneration = 0
    private var updateMonitorTask: Task<Void, Never>?
    private var automaticUpdatesPrepared = false
    private static let updateRefreshIntervalNanoseconds: UInt64 = 15 * 60 * 1_000_000_000

    init() {
        #if DEBUG
        if VEXPreviewMode.suppressesRuntime {
            self.nativeUpdater = DisabledNativeUpdaterService()
        } else {
            self.nativeUpdater = NativeUpdaterServiceFactory.make()
        }
        #else
        self.nativeUpdater = NativeUpdaterServiceFactory.make()
        #endif
    }

    init(nativeUpdater: NativeUpdaterService) {
        self.nativeUpdater = nativeUpdater
    }

    var selectedLocationId: String {
        get { storedSelectedLocationId }
        set { storedSelectedLocationId = newValue }
    }

    var selectedLocation: VpnLocation? {
        locations.first { $0.id == selectedLocationId }
    }

    var favoriteLocationIDs: Set<String> {
        ServerSidebarFavorites.decode(storedServerSidebarFavorites)
    }

    var serverSidebarFilter: ServerSidebarFilter {
        get { ServerSidebarFilter(rawValue: storedServerSidebarFilter) ?? .all }
        set { storedServerSidebarFilter = newValue.rawValue }
    }

    var accountTitle: String {
        user?.email ?? session?.user.email ?? "Войдите в VEX"
    }

    var accessToken: String? {
        session?.accessToken
    }

    var isAuthenticated: Bool {
        accessToken?.isEmpty == false
    }

    var updateReadyText: String? {
        guard let update = updateCheck, hasNewerNativeUpdate else { return nil }
        return "v\(update.latestVersion) готово к установке"
    }

    var availableNativeUpdateVersion: String? {
        guard let update = updateCheck, hasNewerNativeUpdate else { return nil }
        return update.latestVersion
    }

    var hasNewerNativeUpdate: Bool {
        updateCheck?.isNewerThanInstalledApp() == true
    }

    var headerUpdateAction: NativeUpdateAction {
        .sparkleCheck
    }

    var canCheckForNativeUpdates: Bool {
        nativeUpdater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { nativeUpdater.automaticallyChecksForUpdates }
        set { nativeUpdater.automaticallyChecksForUpdates = newValue }
    }

    func start(helperStatus: VpnStatus? = nil) async {
        prepareAutomaticUpdatesForStartup()
        startUpdateMonitoring()
        biometricAvailability = biometricAuth.availability()
        canUnlockStoredSession = sessionStore.hasStoredNativeSession()
        if let storedSession = sessionStore.loadSession() {
            session = storedSession
            user = storedSession.user
            canUnlockStoredSession = true
        } else if biometricUnlockRequired && biometricAvailability.isAvailable && canUnlockStoredSession {
            statusMessage = "Подтвердите вход по \(biometricAvailability.label)."
            autoLaunchEnabled = startupService.isEnabled()
            observeSupportSocket()
            await loadUpdate()
            await loadRemoteConfig()
            return
        }
        autoLaunchEnabled = startupService.isEnabled()
        observeSupportSocket()
        await refreshAll()
        await restoreActiveTunnelIfHelperIsConnected(helperStatus)
        scheduleProfileWarmup()
        connectSupportSocketIfPossible()
    }

    func refreshAll() async {
        async let updateResult: Void = loadUpdate()
        async let remoteConfigResult: Void = loadRemoteConfig()
        guard let token = await authenticatedAccessToken() else {
            _ = await (updateResult, remoteConfigResult)
            statusMessage = "Сессия не найдена. Войдите через браузер."
            return
        }
        isLoading = true
        defer { isLoading = false }

        async let userResult = loadUser(token)
        async let locationsResult: Void = refreshLocations(accessToken: token)
        async let supportResult = loadSupport(token)
        async let billingResult = loadBilling(token)
        async let diagnosticsFlush = diagnosticsService.flush(accessToken: token)
        _ = await [userResult, locationsResult, supportResult, updateResult, remoteConfigResult, billingResult, diagnosticsFlush]
    }

    func refreshLocations() async {
        guard let token = await authenticatedAccessToken() else {
            locationLoadError = "Войдите в VEX, чтобы загрузить серверы."
            return
        }
        await refreshLocations(accessToken: token)
    }

    func selectAutoServer() {
        serverSelectionMode = "auto"
        autoServerEnabled = true
        statusMessage = "Автовыбор сервера включен."
        serverSidebarOperation = .selected("Автовыбор сервера включён.")
        scheduleProfileWarmup()
    }

    func selectLocation(_ location: VpnLocation) async {
        selectedLocationId = location.id
        serverSelectionMode = "manual"
        autoServerEnabled = false
        statusMessage = "Выбран сервер: \(location.displayName)."
        serverSidebarOperation = .selected("Выбран сервер: \(location.displayName).")
        scheduleProfileWarmup()
    }

    func selectAutoServer(using helper: VEXHelperModel) async {
        await performServerSelection(using: helper) {
            self.selectAutoServer()
        }
    }

    func selectLocation(_ location: VpnLocation, using helper: VEXHelperModel) async {
        await performServerSelection(using: helper) {
            await self.selectLocation(location)
        }
    }

    private func performServerSelection(
        using helper: VEXHelperModel,
        selection: @escaping @MainActor () async -> Void
    ) async {
        guard !isServerSelectionBusy, !isVpnBusy, !helper.isBusy else {
            statusMessage = "Дождитесь завершения текущей операции VPN."
            return
        }

        let previousLocationID = selectedLocationId
        let previousSelectionMode = serverSelectionMode
        let previousAutoServerEnabled = autoServerEnabled
        isServerSelectionBusy = true
        defer { isServerSelectionBusy = false }

        await selection()
        guard helper.status.isUsableConnectedStatus else {
            return
        }

        let switched = await switchConnectedVPNLocation(using: helper)
        guard !switched else { return }

        selectedLocationId = previousLocationID
        serverSelectionMode = previousSelectionMode
        autoServerEnabled = previousAutoServerEnabled
        scheduleProfileWarmup()
    }

    func setServerSidebarFilter(_ filter: ServerSidebarFilter) {
        objectWillChange.send()
        serverSidebarFilter = filter
    }

    func isFavoriteLocation(_ locationID: String) -> Bool {
        favoriteLocationIDs.contains(locationID.lowercased())
    }

    func toggleFavoriteLocation(_ locationID: String) {
        let favorites = ServerSidebarFavorites.toggling(locationID, in: favoriteLocationIDs)
        objectWillChange.send()
        storedServerSidebarFavorites = ServerSidebarFavorites.encode(favorites)
    }

    func retryLocationRefresh() async {
        await refreshLocations()
    }

    func acknowledgeServerSidebarOperation(_ operation: ServerSidebarOperationState) {
        guard serverSidebarOperation == operation, !operation.isBusy else { return }
        serverSidebarOperation = .idle
    }

    func toggleVPNPower(using helper: VEXHelperModel) async {
        if isVpnBusy || helper.isBusy {
            switch desiredVpnState {
            case .connected:
                desiredVpnState = .disconnected
                vpnOperationGeneration += 1
                statusMessage = "Отменяем подключение VPN."
                await helper.interruptWithDisconnect(releaseAntiLeak: !antiLeakEnabled)
                isVpnBusy = false
            case .disconnected:
                desiredVpnState = .connected
                vpnOperationGeneration += 1
                statusMessage = "Подключим VPN после отключения."
            }
            return
        }

        switch helper.status.state {
        case .connected:
            if shouldSwitchConnectedTunnel(for: helper.status) {
                _ = await switchConnectedVPNLocation(using: helper)
            } else {
                await disconnectVPN(using: helper)
            }
        case .connecting:
            desiredVpnState = .disconnected
            vpnOperationGeneration += 1
            statusMessage = "Отменяем подключение VPN."
            await helper.interruptWithDisconnect(releaseAntiLeak: !antiLeakEnabled)
            isVpnBusy = false
        case .disconnecting:
            desiredVpnState = .connected
            vpnOperationGeneration += 1
            statusMessage = "Подключим VPN после отключения."
            if !isVpnBusy, !helper.isBusy {
                await performConnectVPN(using: helper, generation: vpnOperationGeneration)
            }
        case .disconnected:
            await connectVPN(using: helper)
        }
    }

    func connectVPN(using helper: VEXHelperModel) async {
        desiredVpnState = .connected
        vpnOperationGeneration += 1
        await performConnectVPN(using: helper, generation: vpnOperationGeneration)
    }

    private func performConnectVPN(using helper: VEXHelperModel, generation: Int) async {
        guard !isVpnBusy, !helper.isBusy else {
            statusMessage = desiredVpnState == .connected ? "Операция VPN уже выполняется." : "Отменяем подключение VPN."
            return
        }
        isVpnBusy = true

        guard let token = await authenticatedAccessToken() else {
            statusMessage = "Сначала войдите в аккаунт."
            isVpnBusy = false
            return
        }
        guard let requestToken = await ensureEntitlementForConnect(accessToken: token) else {
            isVpnBusy = false
            return
        }
        guard entitlement?.hasPaidAccess == true else {
            statusMessage = entitlement == nil ? "Не удалось проверить подписку." : "Для VPN нужна активная подписка."
            await submitDiagnostics(reason: "entitlement_missing_before_connect", status: "auth_error", helperStatus: helper.status, samples: ["message": statusMessage ?? ""])
            isVpnBusy = false
            return
        }
        do {
            try ensureConnectStillDesired(generation: generation)
            statusMessage = "Готовим VPN-профиль."
            let (tunnel, tunnelToken) = try await resolveProfileForAuthenticatedSession(
                accessToken: requestToken,
                locationId: targetLocationId,
                routingMode: routingMode,
                forceRefresh: false,
                prevalidatedEntitlement: entitlement
            )
            try ensureConnectStillDesired(generation: generation)
            let connectedTunnel = try await connectWithAutopilot(
                initialTunnel: tunnel,
                accessToken: tunnelToken,
                helper: helper,
                generation: generation
            )
            try ensureConnectStillDesired(generation: generation)
            activeTunnel = connectedTunnel
            statusMessage = "VPN подключен через \(selectedLocation?.displayName ?? connectedTunnel.locationId.uppercased())."
            // Reporting is fire-and-forget: the tunnel is already up, so a slow
            // API round-trip must neither hold the busy state nor delay feedback.
            Task { [api] in
                await api.reportVpnConnect(accessToken: tunnelToken, tunnel: connectedTunnel)
            }
        } catch is CancellationError {
            await helper.interruptWithDisconnect(releaseAntiLeak: !antiLeakEnabled)
            statusMessage = "Подключение VPN отменено."
        } catch {
            statusMessage = connectErrorMessage(error)
            await helper.interruptWithDisconnect(releaseAntiLeak: true)
            activeTunnel = nil
            await submitDiagnostics(reason: "vpn_connect_failed", status: "error", helperStatus: helper.status, samples: ["error": error.localizedDescription])
        }
        isVpnBusy = false

        if desiredVpnState == .disconnected, helper.status.state != .disconnected {
            await performDisconnectVPN(using: helper, reason: "user", generation: vpnOperationGeneration)
        }
    }

    private func connectWithAutopilot(initialTunnel: PreparedTunnel, accessToken token: String, helper: VEXHelperModel, generation: Int) async throws -> PreparedTunnel {
        activeTunnel = initialTunnel
        do {
            return try await connectPreparedTunnel(initialTunnel, helper: helper, generation: generation)
        } catch {
            try ensureConnectStillDesired(generation: generation)

            let probe = await autopilotService.probe(endpoint: initialTunnel.endpoint)
            let usage = await autopilotService.usage(accessToken: token, deviceId: initialTunnel.device.id)
            let healthReasons = autopilotService.healthReasons(status: helper.status, usage: usage)
            let assessment = autopilotService.assess(error: error, healthReasons: healthReasons, status: helper.status, probe: probe)
            statusMessage = assessment.userMessage
            await submitDiagnostics(
                reason: "vpn_autopilot_initial_failed",
                status: assessment.diagnosticStatus,
                helperStatus: helper.status,
                samples: assessment.samples.merging(["error": error.localizedDescription]) { current, _ in current }
            )

            if initialTunnel.rotationRequired || assessment.cause == .keyOrProfile,
               let rotatedTunnel = try await profileService.rotateKey(accessToken: token, currentTunnel: initialTunnel) {
                try ensureConnectStillDesired(generation: generation)
                return try await connectPreparedTunnel(rotatedTunnel, helper: helper, generation: generation)
            }

            do {
                try ensureConnectStillDesired(generation: generation)
                let freshTunnel = try await profileService.resolveProfile(
                    accessToken: token,
                    locationId: initialTunnel.locationId,
                    routingMode: routingMode,
                    forceRefresh: true
                )
                return try await connectPreparedTunnel(freshTunnel, helper: helper, generation: generation)
            } catch {
                guard allowsAutomaticFailover, assessment.canFailover, let failoverLocation = bestFailoverLocation(excluding: initialTunnel.locationId) else {
                    throw error
                }
                selectedLocationId = failoverLocation.id
                serverSelectionMode = "manual"
                autoServerEnabled = false
                let failoverTunnel = try await profileService.resolveProfile(
                    accessToken: token,
                    locationId: failoverLocation.id,
                    routingMode: routingMode,
                    forceRefresh: true
                )
                try ensureConnectStillDesired(generation: generation)
                await submitDiagnostics(
                    reason: "vpn_autopilot_failover",
                    status: assessment.diagnosticStatus,
                    helperStatus: helper.status,
                    samples: assessment.samples.merging([
                        "previous_location_id": initialTunnel.locationId,
                        "next_location_id": failoverLocation.id,
                    ]) { current, _ in current }
                )
                return try await connectPreparedTunnel(failoverTunnel, helper: helper, generation: generation)
            }
        }
    }

    private func connectPreparedTunnel(_ tunnel: PreparedTunnel, helper: VEXHelperModel, generation: Int) async throws -> PreparedTunnel {
        var lastError: Error = VpnAutopilotRuntimeError.connectFailed("VPN connection failed.")
        try ensureConnectStillDesired(generation: generation)
        try await helper.ensureHelperReady()
        for attempt in autopilotService.fallbackTunnels(for: tunnel) {
            try ensureConnectStillDesired(generation: generation)
            activeTunnel = attempt
            try await profileService.writeHelperConfig(for: attempt)
            await helper.connect(antiLeakEnabled: antiLeakEnabled)
            try ensureConnectStillDesired(generation: generation)
            if helper.status.isUsableConnectedStatus {
                if let endpoint = attempt.endpoint {
                    LastTunnelEndpointStore().save(endpoint, locationId: attempt.locationId)
                }
                return attempt
            }
            if helper.status.routeOk, helper.status.socketExists, helper.status.latestHandshake == nil, helper.status.rxBytes == 0 {
                lastError = VpnAutopilotRuntimeError.connectFailed("no_handshake: tunnel route is active but peer did not answer")
            } else {
                lastError = VpnAutopilotRuntimeError.connectFailed(helper.message ?? "VPN connection failed.")
            }
            await helper.disconnect(releaseAntiLeak: true)
        }
        throw lastError
    }

    func disconnectVPN(using helper: VEXHelperModel, reason: String = "user") async {
        desiredVpnState = .disconnected
        vpnOperationGeneration += 1
        await performDisconnectVPN(using: helper, reason: reason, generation: vpnOperationGeneration)
    }

    private func performDisconnectVPN(using helper: VEXHelperModel, reason: String, generation: Int) async {
        if helper.status.state == .disconnected, !helper.isBusy {
            activeTunnel = nil
            statusMessage = "VPN отключен."
            if desiredVpnState == .connected {
                vpnOperationGeneration += 1
                await performConnectVPN(using: helper, generation: vpnOperationGeneration)
            }
            return
        }
        if isVpnBusy, helper.status.state == .connecting {
            statusMessage = "Отменяем подключение VPN."
            await helper.interruptWithDisconnect(releaseAntiLeak: !antiLeakEnabled)
            isVpnBusy = false
            activeTunnel = nil
            return
        }
        guard !isVpnBusy, !helper.isBusy else {
            statusMessage = desiredVpnState == .connected ? "Подключим VPN после текущей операции." : "Отключаем VPN."
            return
        }
        isVpnBusy = true
        await helper.disconnect(releaseAntiLeak: !antiLeakEnabled)
        let reportedTunnel = activeTunnel
        activeTunnel = nil
        statusMessage = "VPN отключен."
        isVpnBusy = false
        if let token = accessToken {
            Task { [api] in
                await api.reportVpnDisconnect(accessToken: token, tunnel: reportedTunnel, reason: reason)
            }
        }

        if desiredVpnState == .connected {
            vpnOperationGeneration += 1
            await performConnectVPN(using: helper, generation: vpnOperationGeneration)
        }
    }

    private func ensureConnectStillDesired(generation: Int) throws {
        guard desiredVpnState == .connected, vpnOperationGeneration == generation else {
            throw CancellationError()
        }
    }

    func applySelectedLocationIfConnected(using helper: VEXHelperModel) async {
        guard helper.status.isUsableConnectedStatus else {
            scheduleProfileWarmup()
            return
        }
        _ = await switchConnectedVPNLocation(using: helper)
    }

    private func switchConnectedVPNLocation(using helper: VEXHelperModel) async -> Bool {
        guard !isVpnBusy, !helper.isBusy else {
            statusMessage = "Дождитесь завершения текущей операции VPN."
            serverSidebarOperation = .failed(statusMessage ?? "VPN занят.")
            return false
        }
        isVpnBusy = true
        defer { isVpnBusy = false }

        guard let token = await authenticatedAccessToken() else {
            statusMessage = "Сначала войдите в аккаунт."
            serverSidebarOperation = .failed(statusMessage ?? "Сначала войдите в аккаунт.")
            return false
        }

        let previousTunnel = activeTunnel
        let previousLocationId = previousTunnel?.locationId ?? selectedLocationId
        let nextLocationId = targetLocationId
        if let previousTunnel,
           previousTunnel.locationId == nextLocationId,
           tunnel(previousTunnel, matches: helper.status) {
            statusMessage = "Этот сервер уже подключен."
            serverSidebarOperation = .verified(statusMessage ?? "Сервер уже подключён.")
            return true
        }

        desiredVpnState = .connected
        vpnOperationGeneration += 1
        let generation = vpnOperationGeneration
        statusMessage = "Переключаем сервер VPN."
        serverSidebarOperation = .preparingRoute

        do {
            let nextTunnel = try await profileService.resolveProfile(
                accessToken: token,
                locationId: nextLocationId,
                routingMode: routingMode,
                forceRefresh: false
            )
            try ensureConnectStillDesired(generation: generation)
            activeTunnel = nextTunnel
            try await profileService.writeHelperConfig(for: nextTunnel)
            serverSidebarOperation = .connecting
            await helper.disconnect(releaseAntiLeak: false)
            try ensureConnectStillDesired(generation: generation)
            await helper.connect(antiLeakEnabled: antiLeakEnabled)
            try ensureConnectStillDesired(generation: generation)
            serverSidebarOperation = .verifying

            if helper.status.isUsableConnectedStatus {
                if let endpoint = nextTunnel.endpoint {
                    LastTunnelEndpointStore().save(endpoint, locationId: nextTunnel.locationId)
                }
                statusMessage = "VPN переключен на \(selectedLocation?.displayName ?? nextTunnel.locationId.uppercased())."
                serverSidebarOperation = .verified(statusMessage ?? "VPN переключен.")
                Task { [api] in
                    await api.reportVpnDisconnect(accessToken: token, tunnel: previousTunnel, reason: "server_switch")
                    await api.reportVpnConnect(accessToken: token, tunnel: nextTunnel)
                }
                return true
            }

            throw VpnAutopilotRuntimeError.connectFailed(helper.message ?? "VPN switch failed.")
        } catch is CancellationError {
            statusMessage = "Переключение сервера отменено."
            serverSidebarOperation = .failed(statusMessage ?? "Переключение сервера отменено.")
            return false
        } catch {
            activeTunnel = previousTunnel
            if let previousTunnel {
                try? await profileService.writeHelperConfig(for: previousTunnel)
                await helper.connect(antiLeakEnabled: antiLeakEnabled)
            }
            let previousRouteRestored =
                previousTunnel != nil && helper.status.isUsableConnectedStatus
            statusMessage = previousRouteRestored
                ? "Не удалось переключиться на выбранный сервер. Вернули предыдущий."
                : "Не удалось переключиться. Проверьте состояние VPN и повторите попытку."
            serverSidebarOperation = .failed(statusMessage ?? "Не удалось переключиться.")
            await submitDiagnostics(
                reason: "vpn_server_switch_failed",
                status: "error",
                helperStatus: helper.status,
                samples: [
                    "error": error.localizedDescription,
                    "previous_location_id": previousLocationId,
                    "next_location_id": nextLocationId,
                ]
            )
            return false
        }
    }

    func setAutoLaunchEnabled(_ enabled: Bool) {
        do {
            try startupService.setEnabled(enabled)
            autoLaunchEnabled = enabled
            statusMessage = enabled ? "Автозапуск включен." : "Автозапуск выключен."
        } catch {
            autoLaunchEnabled = startupService.isEnabled()
            statusMessage = error.localizedDescription
        }
    }

    func setSmartRoutingEnabled(_ enabled: Bool) {
        smartRoutingEnabled = enabled
        activeTunnel = nil
        statusMessage = enabled
            ? "Умный режим включен. Применится при следующем подключении."
            : "Полный VPN для всего трафика включен."
        scheduleProfileWarmup()
    }

    func setInterfaceLanguage(_ value: String) {
        let normalized = value == "en" ? "en" : "ru"
        interfaceLanguage = normalized
        statusMessage = normalized == "en" ? "Language preference saved." : "Язык интерфейса сохранен."
    }

    func checkForNativeUpdates() {
        guard nativeUpdater.canCheckForUpdates else {
            statusMessage = "Проверка обновлений временно недоступна."
            return
        }
        nativeUpdater.checkForUpdates()
        statusMessage = "Открыли Sparkle проверку обновлений."
    }

    func prepareAutomaticUpdatesForStartup() {
        guard !automaticUpdatesPrepared,
              nativeUpdater.automaticallyChecksForUpdates else {
            return
        }
        automaticUpdatesPrepared = true
        nativeUpdater.startUpdater()
        nativeUpdater.checkForUpdatesInBackground()
    }

    func openSignIn() {
        beginWebAuth(mode: .login)
    }

    func openRegistration() {
        beginWebAuth(mode: .register)
    }

    func cancelWebAuth() {
        webAuthTask?.cancel()
        webAuthTask = nil
        authService.cancelWebAuth()
        isWaitingForWebAuth = false
        isAuthBusy = false
        authError = nil
        statusMessage = "Вход через сайт отменен."
    }

    func requestSignInCode(email: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAuthBusy else { return }
        guard !trimmedEmail.isEmpty else {
            authError = "Введите email."
            statusMessage = authError
            return
        }

        isAuthBusy = true
        authError = nil
        defer { isAuthBusy = false }

        do {
            let challenge = try await api.requestEmailOTP(email: trimmedEmail)
            emailOTPChallengeID = challenge.challengeID
            emailOTPChallengeEmail = trimmedEmail
            statusMessage = "Код отправлен на email."
        } catch {
            authError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func confirmSignInCode(email: String, code: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAuthBusy else { return }
        guard !trimmedEmail.isEmpty, !trimmedCode.isEmpty, let challengeID = emailOTPChallengeID else {
            authError = "Введите код из письма."
            statusMessage = authError
            return
        }

        isAuthBusy = true
        authError = nil
        defer { isAuthBusy = false }

        do {
            let nextSession = try await api.confirmEmailOTP(email: trimmedEmail, challengeID: challengeID, code: trimmedCode)
            emailOTPChallengeID = nil
            emailOTPChallengeEmail = nil
            try await completeSignIn(nextSession, message: "Вход выполнен.")
        } catch {
            authError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func resetEmailOTPChallenge() {
        emailOTPChallengeID = nil
        emailOTPChallengeEmail = nil
    }

    func unlockStoredSessionWithBiometrics() async {
        guard !isAuthBusy else { return }
        guard canUnlockStoredSession else {
            authError = "Сохраненная сессия не найдена."
            return
        }
        isAuthBusy = true
        authError = nil
        defer { isAuthBusy = false }

        let allowed = await biometricAuth.authenticate()
        guard allowed else {
            authError = "Проверка личности отменена."
            statusMessage = authError
            return
        }
        guard let storedSession = sessionStore.loadSession() else {
            authError = "Не удалось загрузить сохраненную сессию."
            statusMessage = authError
            return
        }
        session = storedSession
        user = storedSession.user
        statusMessage = "Сохраненная сессия открыта."
        await refreshAll()
        connectSupportSocketIfPossible()
    }

    func signOut() {
        try? sessionStore.clearSession()
        supportSocket.close()
        session = nil
        user = nil
        activeTunnel = nil
        supportTickets = []
        entitlement = nil
        billingSummary = nil
        authError = nil
        billingError = nil
        canUnlockStoredSession = sessionStore.hasStoredNativeSession()
        statusMessage = "Вы вышли из аккаунта."
    }

    func prepareForTermination() {
        updateMonitorTask?.cancel()
        updateMonitorTask = nil
        profileWarmupTask?.cancel()
        profileWarmupTask = nil
        webAuthTask?.cancel()
        webAuthTask = nil
        supportSocket.close()
    }

    func handleDeepLink(_ url: URL) async {
        if url.scheme == "vexguard", url.host == nil || url.host?.isEmpty == true {
            beginWebAuth(mode: .login)
            return
        }
        guard !isAuthBusy else { return }
        isAuthBusy = true
        defer { isAuthBusy = false }

        await finishWebAuthCallback(url)
    }

    private func finishWebAuthCallback(_ url: URL) async {
        do {
            let verifier = try authService.consumeVerifier(for: url)
            let code = try authService.code(from: url)
            let nextSession = try await api.exchangeAppAuthCode(code: code, codeVerifier: verifier)
            authService.clearVerifier()
            isWaitingForWebAuth = false
            try await completeSignIn(nextSession, message: "Вход через сайт выполнен.")
        } catch {
            isWaitingForWebAuth = false
            authError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func submitManualDiagnostics(using helper: VEXHelperModel) async {
        await submitDiagnostics(reason: "manual_native_diagnostics", status: helper.status.isUsableConnectedStatus ? "ok" : "info", helperStatus: helper.status, samples: ["message": statusMessage ?? helper.message ?? "manual"])
        statusMessage = "Диагностика отправлена."
    }

    func sendSupportDiagnostics(using helper: VEXHelperModel) async {
        guard accessToken != nil else { return }
        let rawDiagnostics: String
        do {
            rawDiagnostics = try await helper.diagnostics()
        } catch {
            rawDiagnostics = "helper diagnostics unavailable: \(error.localizedDescription)"
        }
        let redactedDiagnostics = truncateDiagnosticText(redactSensitiveDiagnostics(rawDiagnostics), limit: 2_800)
        await submitDiagnostics(
            reason: "manual_support_diagnostics",
            status: helper.status.isUsableConnectedStatus ? "ok" : "info",
            helperStatus: helper.status,
            samples: [
                "support_attachment": "true",
                "helper_diagnostics": truncateDiagnosticText(redactedDiagnostics, limit: 900),
            ]
        )
        await sendSupportMessage("""
        Диагностика VEX Native macOS

        Сервер: \(selectedLocation?.displayName ?? targetLocationId)
        VPN: \(helper.status.state.rawValue)
        Endpoint: \(helper.status.endpoint ?? "unknown")
        RX/TX: \(helper.status.rxBytes)/\(helper.status.txBytes)

        \(redactedDiagnostics)
        """)
    }

    func recoverTunnelIfNeeded(using helper: VEXHelperModel) async {
        guard autoRecoveryEnabled, helper.status.isUsableConnectedStatus, !helper.isBusy else { return }
        let usage: VpnDeviceUsage?
        if let token = accessToken {
            usage = await autopilotService.usage(accessToken: token, deviceId: activeTunnel?.device.id)
        } else {
            usage = nil
        }
        let healthReasons = autopilotService.healthReasons(status: helper.status, usage: usage)
        guard tunnelHealthLooksStale(helper.status) || !healthReasons.isEmpty else { return }
        let previousLocationId = targetLocationId
        let assessment = autopilotService.assess(healthReasons: healthReasons, status: helper.status)
        let failoverLocation = allowsAutomaticFailover ? bestFailoverLocation(excluding: previousLocationId) : nil
        if assessment.canFailover, let failoverLocation {
            selectedLocationId = failoverLocation.id
            serverSelectionMode = "manual"
            autoServerEnabled = false
        }
        await submitDiagnostics(
            reason: "native_watchdog_stale_tunnel",
            status: assessment.diagnosticStatus,
            helperStatus: helper.status,
            samples: assessment.samples.merging([
                "recovery": assessment.canFailover && failoverLocation != nil ? "failover_location" : "controlled_reconnect",
                "previous_location_id": previousLocationId,
                "next_location_id": assessment.canFailover ? (failoverLocation?.id ?? previousLocationId) : previousLocationId,
                "usage_connection_status": usage?.connectionStatus ?? "",
                "usage_seconds_since_handshake": usage?.secondsSinceHandshake.map(String.init) ?? "",
            ]) { current, _ in current }
        )
        statusMessage = assessment.userMessage
        await disconnectVPN(using: helper, reason: "watchdog_recovery")
        await connectVPN(using: helper)
    }

    func sendSupportMessage(_ body: String, subject requestedSubject: String? = nil) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = accessToken else { return }
        let subject = normalizedSupportSubject(requestedSubject, fallbackBody: trimmed)
        let pendingTicket = optimisticSupportTicket(subject: subject, body: trimmed)
        supportTickets.insert(pendingTicket, at: 0)
        if supportSocket.send(body: trimmed, subject: subject) {
            statusMessage = "Сообщение отправлено в поддержку."
            return
        }
        do {
            let ticket = try await api.createSupportTicket(
                accessToken: token,
                subject: subject,
                message: trimmed
            )
            replaceOptimisticSupportTicket(pendingTicket, with: ticket)
            statusMessage = "Сообщение отправлено в поддержку."
        } catch {
            supportTickets.removeAll { $0.id == pendingTicket.id }
            statusMessage = error.localizedDescription
        }
    }

    func refreshSupport() async {
        guard let token = accessToken else { return }
        await loadSupport(token)
        connectSupportSocketIfPossible()
    }

    func refreshUpdates() async {
        await loadUpdate()
        await loadRemoteConfig()
    }

    func refreshBilling() async {
        guard let token = accessToken else { return }
        await loadBilling(token)
    }

    func startCheckout(for plan: BillingPlanOption) async {
        guard let token = accessToken else {
            billingError = "Сначала войдите в аккаунт."
            statusMessage = billingError
            return
        }
        guard !plan.disabled, !isBillingBusy else { return }
        isBillingBusy = true
        billingError = nil
        defer { isBillingBusy = false }
        do {
            let quote = try await api.billingPriceQuote(accessToken: token, planID: plan.id)
            if quote.changeType == "downgrade" {
                throw BillingError.downgradeScheduled
            }
            let expectedAmountMinor = quote.changeType == "current" ? plan.amountCents : quote.amountDueMinor
            guard expectedAmountMinor >= 0 else {
                throw BillingError.priceUnavailable
            }
            let checkout = try await api.checkoutSession(
                accessToken: token,
                plan: plan,
                expectedAmountMinor: expectedAmountMinor,
                changeMode: quote.changeType
            )
            guard let url = URL(string: checkout.url), !checkout.url.isEmpty else {
                throw BillingError.missingCheckoutURL
            }
            NSWorkspace.shared.open(url)
            statusMessage = "Открыли оплату в браузере."
        } catch {
            billingError = error.localizedDescription
            statusMessage = error.localizedDescription
            await submitDiagnostics(reason: "billing_checkout_failed", status: "error", samples: ["plan_id": plan.id, "error": error.localizedDescription])
        }
    }

    func cancelSubscription() async {
        guard let token = accessToken else { return }
        guard !isBillingBusy else { return }
        isBillingBusy = true
        billingError = nil
        defer { isBillingBusy = false }
        do {
            entitlement = try await api.cancelSubscription(accessToken: token)
            await loadBilling(token)
            statusMessage = "Подписка отменена. Доступ сохранится до конца оплаченного периода."
        } catch {
            billingError = error.localizedDescription
            statusMessage = error.localizedDescription
            await submitDiagnostics(reason: "billing_cancel_failed", status: "error", samples: ["error": error.localizedDescription])
        }
    }

    func openBillingPortal() async {
        guard let token = accessToken else { return }
        guard !isBillingBusy else { return }
        isBillingBusy = true
        billingError = nil
        defer { isBillingBusy = false }
        do {
            let portal = try await api.portalSession(accessToken: token)
            guard let value = portal.url, let url = URL(string: value), !value.isEmpty else {
                throw BillingError.missingPortalURL
            }
            NSWorkspace.shared.open(url)
            statusMessage = "Открыли управление подпиской."
        } catch {
            billingError = error.localizedDescription
            statusMessage = error.localizedDescription
            await submitDiagnostics(reason: "billing_portal_failed", status: "error", samples: ["error": error.localizedDescription])
        }
    }

    private func loadUser(_ token: String) async {
        do {
            user = try await api.me(accessToken: token)
        } catch {
            if error.isUnauthorizedAPIError {
                guard let refreshedToken = await refreshSessionForRetry() else {
                    return
                }
                do {
                    user = try await api.me(accessToken: refreshedToken)
                } catch {
                    if error.isUnauthorizedAPIError {
                        expireAuthenticatedSession(message: "Сессия истекла. Войдите снова.")
                    } else {
                        statusMessage = error.localizedDescription
                    }
                }
            } else {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func refreshLocations(accessToken token: String) async {
        guard !isLoadingLocations else { return }
        isLoadingLocations = true
        locationLoadError = nil
        defer { isLoadingLocations = false }

        do {
            locations = try await api.vpnLocations(accessToken: token)
            lastLocationsRefreshAt = Date()
            if selectedLocation == nil, serverSelectionMode != "manual", let first = locations.first {
                selectedLocationId = first.id
            }
        } catch {
            locationLoadError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func loadSupport(_ token: String) async {
        do {
            supportTickets = try await api.supportTickets(accessToken: token)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadBilling(_ token: String) async {
        let billingUserId = user?.id ?? session?.user.id ?? ""
        let cachedSummary = billingSummaryCache.load(userId: billingUserId)
        if billingSummary == nil, let cachedSummary {
            billingSummary = cachedSummary
        }

        // All three requests start concurrently; payments are awaited separately
        // so a payments failure never masks the summary/entitlement result.
        async let plansResult = api.billingPlans()
        async let entitlementResult = api.entitlement(accessToken: token)
        async let paymentsResult = api.billingPayments(accessToken: token, limit: 24)

        do {
            let (plans, currentEntitlement) = try await (plansResult, entitlementResult)
            entitlement = currentEntitlement
            billingSummary = billingService.buildSummary(plans: plans, entitlement: currentEntitlement)
            if let billingSummary {
                billingSummaryCache.save(userId: billingUserId, summary: billingSummary)
            }
            billingError = nil
        } catch {
            let fallback = cachedSummary ?? billingService.buildSummary(plans: [], entitlement: entitlement)
            billingSummary = fallback
            billingError = error.localizedDescription
            statusMessage = error.localizedDescription
            await submitDiagnostics(reason: "billing_summary_failed", status: "error", samples: ["error": error.localizedDescription])
        }

        do {
            billingPayments = try await paymentsResult
        } catch {
            billingPayments = []
            if billingError == nil {
                billingError = error.localizedDescription
            }
            await submitDiagnostics(reason: "billing_payments_failed", status: "warning", samples: ["error": error.localizedDescription])
        }
    }

    private func loadRemoteConfig() async {
        do {
            remoteConfig = try await api.appRemoteConfig()
        } catch {
            await submitDiagnostics(reason: "remote_config_failed", status: "warning", samples: ["error": error.localizedDescription])
        }
    }

    private func ensureEntitlementLoaded(accessToken token: String) async {
        if entitlement == nil {
            await loadBilling(token)
        }
    }

    private func ensureEntitlementForConnect(accessToken token: String) async -> String? {
        if entitlement?.hasPaidAccess == true {
            return token
        }
        do {
            entitlement = try await api.entitlement(accessToken: token)
            return token
        } catch {
            guard error.isUnauthorizedAPIError else {
                statusMessage = error.localizedDescription
                return nil
            }
            guard let refreshedToken = await refreshSessionForRetry() else {
                return nil
            }
            do {
                entitlement = try await api.entitlement(accessToken: refreshedToken)
                return refreshedToken
            } catch {
                if error.isUnauthorizedAPIError {
                    expireAuthenticatedSession(message: "Сессия истекла. Войдите снова.")
                } else {
                    statusMessage = error.localizedDescription
                }
                return nil
            }
        }
    }

    private func loadUpdate(reportErrors: Bool = true) async {
        do {
            applyUpdateCheck(try await api.appUpdateCheck())
        } catch {
            if reportErrors {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func startUpdateMonitoring() {
        guard updateMonitorTask == nil else { return }
        updateMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.updateRefreshIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                await self.loadUpdate(reportErrors: false)
            }
        }
    }

    func applyUpdateCheck(_ update: AppUpdateCheckResult?) {
        updateCheck = update
    }

    #if DEBUG
    func configureServerSidebarPreview() {
        locations = FocusPulsePresentation.animationPreviewLocations + [
            VpnLocation(
                id: "nl-amsterdam",
                countryCode: "NL",
                city: "Amsterdam",
                flagEmoji: "🇳🇱",
                availability: "unavailable",
                status: "maintenance",
                healthyNodes: 0,
                latencyMs: nil
            ),
        ]
        lastLocationsRefreshAt = Date()
        selectedLocationId = "fi"
        serverSelectionMode = "manual"
        storedServerSidebarFavorites = "de"
    }

    func configureBillingPreview() {
        let previewUser = VEXUser(id: "preview-user", email: "ilya@vexguard.app", status: "active")
        session = AuthSession(user: previewUser, accessToken: "preview-token", expiresAt: nil, refreshToken: nil)
        user = previewUser
        entitlement = Entitlement(
            active: true,
            planId: "basic_annual",
            displayName: "Базовый",
            accountStatus: nil,
            subscriptionTitle: nil,
            subscriptionSubtitle: nil,
            remainingText: "Осталось 284 дня",
            status: "active",
            tier: "basic",
            currentPeriodEnd: "2027-05-13T12:00:00Z",
            effectiveExpiresAt: nil,
            vpnAccess: true
        )
        let previewPlans = [
            BillingPlan(id: "basic_monthly", name: "Базовый", provider: "platega", amountCents: 19900, currency: "RUB", interval: "monthly", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "basic_quarterly", name: "Базовый", provider: "platega", amountCents: 53730, currency: "RUB", interval: "quarterly", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "basic_semiannual", name: "Базовый", provider: "platega", amountCents: 101490, currency: "RUB", interval: "semiannual", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "basic_annual", name: "Базовый", provider: "platega", amountCents: 179100, currency: "RUB", interval: "annual", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "pro_monthly", name: "Pro", provider: "platega", amountCents: 29900, currency: "RUB", interval: "monthly", deviceLimit: 3, tier: "pro", status: "active"),
            BillingPlan(id: "pro_quarterly", name: "Pro", provider: "platega", amountCents: 80730, currency: "RUB", interval: "quarterly", deviceLimit: 3, tier: "pro", status: "active"),
            BillingPlan(id: "pro_semiannual", name: "Pro", provider: "platega", amountCents: 152490, currency: "RUB", interval: "semiannual", deviceLimit: 3, tier: "pro", status: "active"),
            BillingPlan(id: "pro_annual", name: "Pro", provider: "platega", amountCents: 269100, currency: "RUB", interval: "annual", deviceLimit: 3, tier: "pro", status: "active"),
            BillingPlan(id: "family_monthly", name: "Team", provider: "platega", amountCents: 149900, currency: "RUB", interval: "monthly", deviceLimit: 10, tier: "team", status: "active"),
        ]
        billingSummary = BillingService().buildSummary(plans: previewPlans, entitlement: entitlement)
        billingPayments = [
            BillingPayment(
                id: "preview-payment-1",
                subscriptionId: nil,
                checkoutSessionId: nil,
                planId: "basic_annual",
                provider: "platega",
                amountMinor: 179100,
                currency: "RUB",
                method: "card",
                status: "paid",
                receiptUrl: "https://pay.platega.io/payment/success",
                failureReason: nil,
                refundedAmountMinor: nil,
                refundedAt: nil,
                paidAt: "2026-08-01T12:00:00Z",
                createdAt: "2026-08-01T11:59:00Z"
            ),
            BillingPayment(
                id: "preview-payment-2",
                subscriptionId: nil,
                checkoutSessionId: nil,
                planId: "basic_monthly",
                provider: "platega",
                amountMinor: 19900,
                currency: "RUB",
                method: "card",
                status: "paid",
                receiptUrl: nil,
                failureReason: nil,
                refundedAmountMinor: nil,
                refundedAt: nil,
                paidAt: "2026-07-01T12:00:00Z",
                createdAt: "2026-07-01T11:59:00Z"
            ),
        ]
    }

    func configureSupportPreview() {
        let previewUser = VEXUser(id: "preview-user", email: "preview@vexguard.app", status: "active")
        session = AuthSession(user: previewUser, accessToken: "preview-token", expiresAt: nil, refreshToken: nil)
        user = previewUser
        locations = FocusPulsePresentation.animationPreviewLocations
        supportSocketConnected = true
        supportTickets = [
            SupportTicket(
                id: "preview-ticket",
                subject: "Проверка интерфейса",
                message: "Привет",
                messages: [
                    SupportMessage(
                        id: "preview-message-1",
                        ticketId: "preview-ticket",
                        sender: "admin",
                        authorId: nil,
                        body: "Привет",
                        createdAt: "2026-08-01T12:56:00Z"
                    ),
                    SupportMessage(
                        id: "preview-message-2",
                        ticketId: "preview-ticket",
                        sender: "admin",
                        authorId: nil,
                        body: "как дела",
                        createdAt: "2026-08-01T12:56:30Z"
                    ),
                    SupportMessage(
                        id: "preview-message-3",
                        ticketId: "preview-ticket",
                        sender: "user",
                        authorId: "preview-user",
                        body: "Спасибо, теперь всё работает",
                        createdAt: "2026-08-01T12:57:00Z"
                    ),
                ],
                status: "open",
                priority: "normal",
                source: "macos-native",
                adminNote: nil,
                createdAt: "2026-08-01T12:55:00Z",
                updatedAt: "2026-08-01T12:57:00Z",
                closedAt: nil
            ),
        ]
    }
    #endif

    private func beginWebAuth(mode: WebAuthMode) {
        guard !isAuthBusy, !isWaitingForWebAuth else { return }
        authError = nil
        isWaitingForWebAuth = true
        statusMessage = mode == .register ? "Ожидаем завершение регистрации на сайте." : "Ожидаем подтверждение входа на сайте."
        webAuthTask?.cancel()
        webAuthTask = Task { [weak self] in
            guard let self else { return }
            do {
                let callbackURL = try await authService.startWebAuth(mode: mode)
                guard !Task.isCancelled else { return }
                isAuthBusy = true
                await finishWebAuthCallback(callbackURL)
                isAuthBusy = false
            } catch {
                guard !Task.isCancelled else { return }
                isWaitingForWebAuth = false
                isAuthBusy = false
                authError = error.localizedDescription
                statusMessage = error.localizedDescription
            }
            webAuthTask = nil
        }
    }

    private func completeSignIn(_ nextSession: AuthSession, message: String) async throws {
        try sessionStore.saveSession(nextSession)
        session = nextSession
        user = nextSession.user
        canUnlockStoredSession = true
        authError = nil
        statusMessage = message
        await refreshAll()
        connectSupportSocketIfPossible()
    }

    private func authenticatedAccessToken() async -> String? {
        guard let currentSession = session else { return nil }
        guard currentSession.shouldRefreshSoon else {
            return currentSession.accessToken
        }
        return await refreshSessionForRetry()
    }

    private func refreshSessionForRetry() async -> String? {
        guard let currentSession = session else { return nil }
        if let sessionRefreshTask {
            return await applySessionRefreshResult(
                await sessionRefreshTask.task.value,
                refreshAccessToken: sessionRefreshTask.accessToken
            )
        }
        let refreshAccessToken = currentSession.accessToken
        let task = Task<Result<AuthSession, Error>, Never> { [api] in
            do {
                return .success(try await api.refreshSession(accessToken: refreshAccessToken))
            } catch {
                return .failure(error)
            }
        }
        sessionRefreshTask = (refreshAccessToken, task)
        let result = await task.value
        sessionRefreshTask = nil
        return await applySessionRefreshResult(result, refreshAccessToken: refreshAccessToken)
    }

    private func applySessionRefreshResult(_ result: Result<AuthSession, Error>, refreshAccessToken: String) async -> String? {
        do {
            let nextSession = try result.get()
            try sessionStore.saveSession(nextSession)
            session = nextSession
            user = nextSession.user
            authError = nil
            statusMessage = "Сессия обновлена."
            connectSupportSocketIfPossible()
            return nextSession.accessToken
        } catch {
            if error.isUnauthorizedAPIError {
                if session?.accessToken == refreshAccessToken {
                    expireAuthenticatedSession(message: "Сессия истекла. Войдите снова.")
                } else {
                    return session?.accessToken
                }
            } else {
                statusMessage = "Не удалось обновить сессию: \(error.localizedDescription)"
            }
            return nil
        }
    }

    private func resolveProfileForAuthenticatedSession(
        accessToken token: String,
        locationId: String,
        routingMode: VpnRoutingMode,
        forceRefresh: Bool,
        prevalidatedEntitlement: Entitlement? = nil
    ) async throws -> (PreparedTunnel, String) {
        do {
            let tunnel = try await profileService.resolveProfile(
                accessToken: token,
                locationId: locationId,
                routingMode: routingMode,
                forceRefresh: forceRefresh,
                prevalidatedEntitlement: prevalidatedEntitlement
            )
            return (tunnel, token)
        } catch {
            guard error.isUnauthorizedAPIError else { throw error }
            guard let refreshedToken = await refreshSessionForRetry() else {
                throw error
            }
            do {
                let tunnel = try await profileService.resolveProfile(
                    accessToken: refreshedToken,
                    locationId: locationId,
                    routingMode: routingMode,
                    forceRefresh: true
                )
                return (tunnel, refreshedToken)
            } catch {
                if error.isUnauthorizedAPIError {
                    expireAuthenticatedSession(message: "Сессия истекла. Войдите снова.")
                }
                throw error
            }
        }
    }

    private func connectErrorMessage(_ error: Error) -> String {
        if error.isRateLimitedAPIError {
            return "Слишком много попыток подключения. Подождите минуту и попробуйте снова."
        }
        return error.localizedDescription
    }

    private func expireAuthenticatedSession(message: String) {
        try? sessionStore.clearSession()
        supportSocket.close()
        session = nil
        user = nil
        activeTunnel = nil
        supportTickets = []
        entitlement = nil
        billingSummary = nil
        billingPayments = []
        authError = message
        billingError = nil
        canUnlockStoredSession = false
        statusMessage = message
    }

    private func supportSubject(for body: String) -> String {
        let text = body.replacingOccurrences(of: "\n", with: " ")
        if text.count <= 42 {
            return text
        }
        return String(text.prefix(42))
    }

    private func normalizedSupportSubject(_ requestedSubject: String?, fallbackBody: String) -> String {
        let subject = requestedSubject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return subject.isEmpty ? supportSubject(for: fallbackBody) : subject
    }

    private func optimisticSupportTicket(subject: String, body: String) -> SupportTicket {
        let id = "local-\(UUID().uuidString)"
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let message = SupportMessage(
            id: "\(id)-message",
            ticketId: id,
            sender: "user",
            authorId: user?.id,
            body: body,
            createdAt: createdAt
        )
        return SupportTicket(
            id: id,
            subject: subject,
            message: body,
            messages: [message],
            status: "open",
            priority: nil,
            source: "macos-native",
            adminNote: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            closedAt: nil
        )
    }

    private func replaceOptimisticSupportTicket(_ pendingTicket: SupportTicket, with ticket: SupportTicket) {
        if let index = supportTickets.firstIndex(where: { $0.id == pendingTicket.id }) {
            supportTickets[index] = ticket
        } else {
            upsertSupportTicket(ticket)
        }
    }

    private func supportTicket(_ localTicket: SupportTicket, matchesUserMessageIn remoteTicket: SupportTicket) -> Bool {
        let localBody = localTicket.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localBody.isEmpty else { return false }
        if remoteTicket.message.trimmingCharacters(in: .whitespacesAndNewlines) == localBody {
            return true
        }
        return remoteTicket.messages?.contains { message in
            message.sender.lowercased() == "user" &&
                message.body.trimmingCharacters(in: .whitespacesAndNewlines) == localBody
        } ?? false
    }

    private func redactSensitiveDiagnostics(_ text: String) -> String {
        let patterns = [
            #"(?i)(privatekey|private_key|token|authorization|password)\s*[:=]\s*[^\s]+"#,
            #"(?i)(bearer)\s+[a-z0-9._~+/=-]+"#,
            #"[A-Za-z0-9+/]{40,}={0,2}"#,
        ]
        return patterns.reduce(text) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(in: current, range: range, withTemplate: "[redacted]")
        }
    }

    private func truncateDiagnosticText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))\n...[truncated]"
    }

    private var routingMode: VpnRoutingMode {
        smartRoutingEnabled ? .allExceptRu : .fullTunnel
    }

    private var targetLocationId: String {
        if autoServerEnabled, let first = locations.sorted(by: locationSort).first {
            return first.id
        }
        return selectedLocationId
    }

    private var allowsAutomaticFailover: Bool {
        autoServerEnabled && serverSelectionMode == "auto"
    }

    private func prepareSelectedProfile(forceRefresh: Bool) async {
        guard let token = accessToken else { return }
        do {
            activeTunnel = try await profileService.resolveProfile(
                accessToken: token,
                locationId: targetLocationId,
                routingMode: routingMode,
                forceRefresh: forceRefresh,
                writeHelperConfig: false
            )
            statusMessage = "Профиль сервера готов."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func restoreActiveTunnelIfHelperIsConnected(_ helperStatus: VpnStatus?) async {
        guard let helperStatus, helperStatus.isUsableConnectedStatus, activeTunnel == nil else { return }
        await prepareSelectedProfile(forceRefresh: false)
        if let activeTunnel, tunnel(activeTunnel, matches: helperStatus) {
            statusMessage = "VPN подключен через \(selectedLocation?.displayName ?? activeTunnel.locationId.uppercased())."
        } else {
            activeTunnel = nil
            statusMessage = "VPN уже активен на другом профиле. Выберите сервер или нажмите подключить для переключения."
        }
    }

    private func tunnel(_ tunnel: PreparedTunnel, matches status: VpnStatus) -> Bool {
        guard status.isUsableConnectedStatus, let activeEndpoint = normalizedEndpoint(status.endpoint) else {
            return false
        }
        let candidates = [tunnel.configEndpoint, tunnel.endpoint].compactMap(normalizedEndpoint)
        return candidates.contains(activeEndpoint)
    }

    private func shouldSwitchConnectedTunnel(for status: VpnStatus) -> Bool {
        guard status.isUsableConnectedStatus else { return false }
        if let activeTunnel {
            return activeTunnel.locationId != targetLocationId || !tunnel(activeTunnel, matches: status)
        }
        return serverSelectionMode == "manual"
    }

    private func normalizedEndpoint(_ endpoint: String?) -> String? {
        let value = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? nil : value
    }

    private func scheduleProfileWarmup() {
        guard let token = accessToken else { return }
        let locationId = targetLocationId
        let mode = routingMode
        profileWarmupTask?.cancel()
        profileWarmupTask = Task { [profileService] in
            do {
                // Warmup fills the cache only when it is missing, stale or for a
                // different location/mode; a fresh cached profile resolves with
                // zero network round-trips.
                _ = try await profileService.resolveProfile(
                    accessToken: token,
                    locationId: locationId,
                    routingMode: mode,
                    forceRefresh: false,
                    writeHelperConfig: false
                )
            } catch is CancellationError {
            } catch {
                // Background warmup is best-effort; foreground connect handles user-visible errors.
            }
        }
    }

    private func connectSupportSocketIfPossible() {
        guard let token = accessToken else { return }
        supportSocket.connect(accessToken: token) { [weak self] tickets in
            self?.supportTickets = tickets
        } onTicket: { [weak self] ticket in
            self?.upsertSupportTicket(ticket)
        }
    }

    private func observeSupportSocket() {
        guard cancellables.isEmpty else { return }
        supportSocket.$isConnected
            .sink { [weak self] value in self?.supportSocketConnected = value }
            .store(in: &cancellables)
        supportSocket.$isReconnecting
            .sink { [weak self] value in self?.supportSocketReconnecting = value }
            .store(in: &cancellables)
    }

    private func upsertSupportTicket(_ ticket: SupportTicket) {
        supportTickets.removeAll { existing in
            existing.id.hasPrefix("local-") && supportTicket(existing, matchesUserMessageIn: ticket)
        }
        if let index = supportTickets.firstIndex(where: { $0.id == ticket.id }) {
            supportTickets[index] = ticket
        } else {
            supportTickets.insert(ticket, at: 0)
        }
    }

    private func submitDiagnostics(reason: String, status: String, helperStatus: VpnStatus? = nil, samples: [String: String] = [:]) async {
        guard let token = accessToken else { return }
        let statusValue = helperStatus
        let report = ClientDiagnosticsReport(
            deviceId: activeTunnel?.device.id,
            reason: reason,
            status: status,
            vpnState: statusValue?.state.rawValue ?? "unknown",
            endpoint: statusValue?.endpoint ?? activeTunnel?.device.endpoint,
            latencyAverageMs: selectedLocation?.latencyMs,
            rxBytes: Int64(statusValue?.rxBytes ?? 0),
            txBytes: Int64(statusValue?.txBytes ?? 0),
            samples: samples.merging([
                "selected_location_id": targetLocationId,
                "routing_mode": routingMode.rawValue,
                "app": "native-macos",
            ]) { current, _ in current }
        )
        await diagnosticsService.upload(accessToken: token, report: report)
    }

    private func locationSort(_ left: VpnLocation, _ right: VpnLocation) -> Bool {
        let leftLatency = left.latencyMs ?? Double.greatestFiniteMagnitude
        let rightLatency = right.latencyMs ?? Double.greatestFiniteMagnitude
        if leftLatency != rightLatency {
            return leftLatency < rightLatency
        }
        return left.healthyNodes > right.healthyNodes
    }

    private func tunnelHealthLooksStale(_ status: VpnStatus) -> Bool {
        guard status.isUsableConnectedStatus else { return false }
        guard let latestHandshake = status.latestHandshake else {
            return status.rxBytes == 0 && status.txBytes == 0
        }
        let age = Date().timeIntervalSince1970 - TimeInterval(latestHandshake)
        return age > 180
    }

    private func bestFailoverLocation(excluding activeLocationId: String) -> VpnLocation? {
        let normalizedActive = activeLocationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return locations
            .filter { location in
                location.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != normalizedActive
                    && location.healthyNodes > 0
                    && location.availability != "retired"
            }
            .sorted(by: locationSort)
            .first
    }
}

private enum DesiredVpnState {
    case connected
    case disconnected
}

private enum VpnAutopilotRuntimeError: LocalizedError {
    case connectFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectFailed(let message):
            return message
        }
    }
}
