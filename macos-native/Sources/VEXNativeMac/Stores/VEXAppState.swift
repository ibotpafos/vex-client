import Foundation
import Combine
import CryptoKit
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
    @AppStorage("native.smartRoutingEnabled") var smartRoutingEnabled = true {
        didSet { nativeNormalPendingTunnel = nil }
    }
    @AppStorage("native.autoRecoveryEnabled") var autoRecoveryEnabled = true
    @AppStorage("native.biometricUnlockRequired") var biometricUnlockRequired = false
    @AppStorage("native.interfaceLanguage") var interfaceLanguage = "ru"
    @AppStorage("native.remotePushEnabled") private(set) var nativeRemotePushEnabled = false
    @AppStorage("native.remotePushConsentAccount") private var nativeRemotePushConsentAccount = ""

    @Published private(set) var session: AuthSession?
    @Published private(set) var user: VEXUser?
    @Published private(set) var locations: [VpnLocation] = []
    @Published private(set) var entitlement: Entitlement? {
        didSet {
            if entitlement?.hasPaidAccess != true { nativeNormalPendingTunnel = nil }
        }
    }
    @Published private(set) var billingSummary: BillingSummary?
    @Published private(set) var billingPayments: [BillingPayment] = []
    @Published private(set) var deviceAddons: [DeviceAddon] = []
    @Published private(set) var accountDevices: [VpnDevice] = [] {
        didSet {
            if accountDevices != oldValue { nativeNormalPendingTunnel = nil }
        }
    }
    @Published private(set) var deviceManagementRequiresWeb = false
    @Published private(set) var updateCheck: AppUpdateCheckResult?
    @Published private(set) var remoteConfig: AppRemoteConfig?
    @Published private(set) var activeTunnel: PreparedTunnel?
    @Published private(set) var isAuthBusy = false
    @Published private(set) var isWaitingForWebAuth = false
    @Published private(set) var isBillingBusy = false
    @Published private(set) var isDeviceBusy = false
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
    @Published private(set) var nativePushRegistrationError: String?

    private let sessionStore = VEXSessionStore()
    private let api = VEXAPIClient()
    private let billingService = BillingService()
    private let billingSummaryCache = BillingSummaryCache()
    private let diagnosticsService = DiagnosticsService()
    private let autopilotService = VpnAutopilotService()
    private let dynamicRouteEngine = DynamicRouteEngine()
    private let biometricAuth = BiometricAuthService()
    private let profileService = VPNProfileService()
    private let nativeAdmittedProfiles = NativeAdmittedProfileStore()
    private let startupService = StartupService()
    private let nativeUpdater: NativeUpdaterService
    let customerNotifications: CustomerNotificationService
    private let nativePushRegistrar = NativePushAPIRegistrar()
    private lazy var nativePushPSKQueue = NativePushPSKEventQueue()
    private let nativePushIdentityStore = VEXDeviceIdentityStore()
    private lazy var nativePSKStageStore = NativePSKStagedProfileStore()
    private lazy var nativeProtectedPromotionStore = NativeProtectedPromotionStore()
    private lazy var nativePSKConsumer = NativePSKEventConsumer(queue: nativePushPSKQueue, store: nativePSKStageStore)
    private let nativePSKVerifier = NativeVPNProfileAuthorizationVerifier.bundled()
    private weak var nativePSKHelper: VEXHelperModel?
    private var nativePSKPreparedTunnel: PreparedTunnel?
    // Exact sensitive source/candidate material remains memory-only. The private
    // durable nonce/hash/intent record fences repeats and survives coordinator
    // reconstruction; it is never a substitute for signed-profile/root proof.
    // TODO: Reconcile full app-crash material with explicitly authorized ownership
    // transfer on an isolated Mac; do not adopt another process from disk metadata.
    private var nativePSKCommittedPromotion: (
        source: PreparedTunnel, candidate: PreparedTunnel, owner: NativePushPSKEventOwner,
        receipt: NativeProtectedReplacementCoordinator.Receipt, generation: Int,
        isCurrent: @MainActor () -> Bool
    )?
    // Memory-only normal-profile staging. Config contains private key material;
    // never publish, persist, diagnose, or use it as an implicit connect input.
    private var nativeNormalPendingStorage: (tunnel: PreparedTunnel, stagedAt: Date, isCurrent: @MainActor () -> Bool)?
    private var nativeNormalPendingTunnel: PreparedTunnel? {
        get {
            guard let pending = nativeNormalPendingStorage,
                  Date().timeIntervalSince(pending.stagedAt) >= 0,
                  Date().timeIntervalSince(pending.stagedAt) <= 300,
                  let expiresAt = pending.tunnel.normalAuthorizationExpiresAt, expiresAt > Date(),
                  pending.isCurrent() else {
                nativeNormalPendingStorage = nil
                return nil
            }
            return pending.tunnel
        }
        set {
            nativeNormalPendingStorage = nil
            guard let candidate = newValue, let source = activeTunnel,
                  let current = session, let installation = nativePushIdentityStore.existingDeviceId(),
                  canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession,
                  nativePushRegistration.status == .registered,
                  nativePushAccountID == current.user.id,
                  nativePushSessionGeneration == authenticatedSessionGeneration,
                  nativePushDeviceID == source.device.id,
                  let device = accountDevices.first(where: { $0.id == source.device.id }),
                  device.status == "active", device.platform?.lowercased() == "macos",
                  device.provisioningMode == "managed_native", device.clientKeyOwnership == "client",
                  device.protocol?.lowercased() == "amneziawg", device.externalDeviceId == installation,
                  source.device.externalDeviceId == installation,
                  source.device.publicKey == device.publicKey,
                  candidate.device.id == device.id, candidate.device.externalDeviceId == installation,
                  candidate.device.publicKey == device.publicKey,
                  let expiresAt = candidate.normalAuthorizationExpiresAt, expiresAt > Date(),
                  // Smart-profile versions are opaque route fingerprints, not a counter.
                  let sourceVersion = source.profileVersion, sourceVersion > 0,
                  let version = candidate.profileVersion, version > 0,
                  (version != sourceVersion || candidate.config != source.config ||
                   candidate.routingPolicyVersion != source.routingPolicyVersion ||
                   candidate.bypassRangesCount != source.bypassRangesCount || candidate.bypassDomainsCount != source.bypassDomainsCount),
                  candidate.locationId == source.locationId, candidate.locationId == targetLocationId,
                  candidate.routingMode == source.routingMode, candidate.routingMode == routingMode,
                  candidate.bypassRegion == source.bypassRegion,
                  entitlement?.hasPaidAccess == true, !isVpnBusy, !isDeviceBusy,
                  !isServerSelectionBusy, !isNativePSKPreparationBusy else { return }
            let sessionGeneration = authenticatedSessionGeneration
            let profileGeneration = nativeNormalProfileReconciliationGeneration
            let vpnGeneration = vpnOperationGeneration
            let selectedID = selectedLocationId
            let prepared = nativePSKPreparedTunnel
            nativeNormalPendingStorage = (candidate, Date(), { [weak self] in
                guard let self, self.canUseNativeRemotePush, self.nativeRemotePushEnabled,
                      self.nativePushConsentMatchesSession, self.nativePushRegistration.status == .registered,
                      self.nativePushAccountID == current.user.id,
                      self.nativePushSessionGeneration == sessionGeneration,
                      self.nativePushDeviceID == device.id,
                      self.nativePushIdentityStore.existingDeviceId() == installation,
                      self.nativeNormalProfileReconciliationGeneration == profileGeneration,
                      self.vpnOperationGeneration == vpnGeneration,
                      self.activeTunnel == source, self.nativePSKPreparedTunnel == prepared,
                      self.targetLocationId == candidate.locationId, self.selectedLocationId == selectedID,
                      self.routingMode == candidate.routingMode,
                      self.accountDevices.first(where: { $0.id == device.id }) == device,
                      self.entitlement?.hasPaidAccess == true, !self.isVpnBusy, !self.isDeviceBusy,
                      !self.isServerSelectionBusy, !self.isNativePSKPreparationBusy else { return false }
                return (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration,
                    accessToken: current.accessToken, accountID: current.user.id)) != nil
            })
        }
    }
    private var nativePSKRetryTask: Task<Void, Never>?
    private var nativePushEventOwner: NativePushPSKEventOwner?
    @Published private(set) var nativePushEventError: String?
    @Published private(set) var isNativePSKPreparationBusy = false
    lazy var nativePushRegistration = NativePushRegistrationService(registrar: nativePushRegistrar)
    private let nativePushRuntimeAllowed: Bool
    private var nativePushDeviceID: String?
    private var nativePushAccountID: String?
    private var nativePushSessionGeneration: Int?
    private var nativeApplePushToken: Data?
    private var nativePushRegistrationRequested = false
    private var registerNativePushAction: (() -> Void)?
    private var unregisterNativePushAction: (() -> Void)?
    private let authService = PKCEAuthService()
    private var cancellables: Set<AnyCancellable> = []
    private var webAuthTask: Task<Void, Never>?
    private var profileWarmupTask: Task<Void, Never>?
    private var sessionRefreshTask: (accessToken: String, task: Task<Result<AuthSession, Error>, Never>)?
    private var desiredVpnState: DesiredVpnState = .disconnected
    private var vpnOperationGeneration = 0 {
        didSet { nativeNormalPendingTunnel = nil }
    }
    private var activeResiliencePolicy: ResiliencePolicy?
    private var activeResilienceRoute: ResilienceConnectionCandidate?
    private var updateMonitorTask: Task<Void, Never>?
    private var customerRealtimeService: CustomerRealtimeService?
    private var customerFallbackTask: Task<Void, Never>?
    private var customerRealtimeConnected = false
    private var customerRealtimeGeneration = 0
    private var authenticatedSessionGeneration = 0
    private var nativeNormalProfileReconciliationGeneration = 0
    private enum AuthenticatedOperationError: Error { case sessionChanged }
    private var customerNotificationSessionID: String?
    private var customerNotificationPolicy = CustomerNotificationPolicy()
    private var customerRefreshInFlight = false
    private var customerRefreshPending = false
    private var automaticUpdatesPrepared = false
    private var automaticUpdatesStartupTask: Task<Void, Never>?
    private static let updateRefreshIntervalNanoseconds: UInt64 = 15 * 60 * 1_000_000_000
    private static let customerFallbackIntervalNanoseconds: UInt64 = 60 * 1_000_000_000
    private static let automaticUpdatesStartupDelayNanoseconds: UInt64 = 3_000_000_000
    private let automaticUpdatesStartupDelayNanoseconds: UInt64

    init() {
        automaticUpdatesStartupDelayNanoseconds = Self.automaticUpdatesStartupDelayNanoseconds
        customerNotifications = CustomerNotificationService(previewMode: VEXPreviewMode.suppressesRuntime)
        nativePushRuntimeAllowed = !VEXPreviewMode.suppressesRuntime
        if VEXPreviewMode.suppressesRuntime {
            self.nativeUpdater = DisabledNativeUpdaterService()
        } else {
            self.nativeUpdater = NativeUpdaterServiceFactory.make()
        }
        observeNativePushSession()
    }

    init(
        nativeUpdater: NativeUpdaterService,
        automaticUpdatesStartupDelayNanoseconds: UInt64 = 3_000_000_000,
        customerNotifications: CustomerNotificationService? = nil
    ) {
        self.nativeUpdater = nativeUpdater
        self.automaticUpdatesStartupDelayNanoseconds = automaticUpdatesStartupDelayNanoseconds
        // Test/preview callers must explicitly inject a fake to enable delivery;
        // the dependency-injected initializer never resolves the native center.
        self.customerNotifications = customerNotifications ?? CustomerNotificationService(previewMode: true)
        nativePushRuntimeAllowed = false
        observeNativePushSession()
    }

    var canUseNativeRemotePush: Bool {
        nativePushRuntimeAllowed && NativeAPNsCapability.signedEnvironment != nil
    }

    func configureNativePushActions(register: @escaping () -> Void, unregister: @escaping () -> Void) {
        registerNativePushAction = register
        unregisterNativePushAction = unregister
        reconcileNativePushSession()
    }

    func setNativeRemotePushEnabled(_ enabled: Bool) {
        guard nativePushRuntimeAllowed else { return }
        let account = session?.user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        nativeRemotePushEnabled = enabled && canUseNativeRemotePush && account?.isEmpty == false
        nativeRemotePushConsentAccount = nativeRemotePushEnabled ? nativePushConsentFingerprint(account!) : ""
        nativePushRegistrationError = nil
        if !nativeRemotePushEnabled {
            purgeNativePushPSKEvents()
            nativeApplePushToken = nil
            nativePushRegistration.clearAuthenticatedSession()
            if nativePushRegistrationRequested { unregisterNativePushAction?() }
            nativePushRegistrationRequested = false
        }
        reconcileNativePushSession()
    }

    func receivedNativeApplePushToken(_ data: Data) {
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession,
              !data.isEmpty, data.count <= 512 else { return }
        nativeApplePushToken = data
        nativePushRegistrationError = nil
        reconcileNativePushSession()
    }

    func nativeApplePushRegistrationFailed() {
        nativeNormalPendingTunnel = nil
        guard nativeRemotePushEnabled, nativePushConsentMatchesSession else { return }
        nativeApplePushToken = nil
        nativePushRegistrationError = "Не удалось зарегистрировать APNs. Проверьте подпись сборки и повторите попытку."
        nativePushRegistration.clearAuthenticatedSession()
        // Leave the attempt marked: only an explicit retry requests Apple again.
    }

    func retryNativePushRegistration() {
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession else { return }
        nativePushRegistrationError = nil
        if nativeApplePushToken == nil { nativePushRegistrationRequested = false }
        reconcileNativePushSession()
        nativePushRegistration.retryCurrentRegistration()
    }

    var canPrepareNativePSKRotation: Bool {
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession,
              nativePushRegistration.status == .registered, entitlement?.hasPaidAccess == true,
              !isNativePSKPreparationBusy, !isVpnBusy, !isDeviceBusy,
              let helper = nativePSKHelper, !helper.isBusy,
              let current = session, !current.accessToken.isEmpty,
              let deviceID = nativePushDeviceID,
              let previous = activeTunnel ?? nativePSKPreparedTunnel,
              previous.device.id == deviceID, previous.device.status == "active",
              previous.device.platform?.lowercased() == "macos",
              previous.device.provisioningMode == "managed_native",
              previous.device.clientKeyOwnership == "client",
              previous.device.protocol?.lowercased() == "amneziawg",
              previous.awgVersion == 3, (previous.profileVersion ?? 0) > 0,
              previous.locationId == selectedLocationId, previous.routingMode == routingMode,
              nativePushIdentityStore.existingDeviceId() != nil else { return false }
        return true
    }

    /// Foreground, explicit action only; never called by connect/profile polling.
    /// Prepares an inactive server stage. The existing signed consumer owns ACK/cutover.
    func prepareNativePSKRotation() {
        guard canPrepareNativePSKRotation, let current = session,
              let helper = nativePSKHelper, let deviceID = nativePushDeviceID,
              let installation = nativePushIdentityStore.existingDeviceId(),
              let owner = NativePushPSKEventOwner(accountID: current.user.id, installationID: installation),
              let previous = activeTunnel ?? nativePSKPreparedTunnel,
              let version = previous.profileVersion else { return }
        let context = NativePSKPreparation.Context(accountID: owner.accountID, installationID: installation,
            deviceID: deviceID, profileVersion: version, locationID: previous.locationId,
            routingMode: previous.routingMode, bypassRegion: previous.bypassRegion,
            routingPolicyVersion: previous.routingPolicyVersion)
        let sessionGeneration = authenticatedSessionGeneration
        let token = current.accessToken
        let vpnGeneration = vpnOperationGeneration
        let scopeIsCurrent: () -> Bool = { [weak self, weak helper] in
            guard let self, let helper, self.canUseNativeRemotePush, self.nativeRemotePushEnabled,
                  self.nativePushConsentMatchesSession, self.nativePushRegistration.status == .registered,
                  self.entitlement?.hasPaidAccess == true, self.nativePushDeviceID == deviceID,
                  self.selectedLocationId == context.locationID, self.routingMode == context.routingMode,
                  self.vpnOperationGeneration == vpnGeneration, !self.isVpnBusy, !self.isDeviceBusy,
                  !helper.isBusy, (self.activeTunnel ?? self.nativePSKPreparedTunnel) == previous else { return false }
            return (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration,
                        accessToken: token, accountID: owner.accountID)) != nil
        }
        isNativePSKPreparationBusy = true
        nativePushEventError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isNativePSKPreparationBusy = false }
            do {
                try await NativePSKPreparation.prepare(context: context, dependencies: .init(
                    scopeIsCurrent: scopeIsCurrent,
                    prepare: { [api] context, key in
                        try await api.preparePSKRotation(accessToken: token, deviceID: context.deviceID,
                            expectedProfileVersion: context.profileVersion, expectedLocationID: context.locationID,
                            routingMode: context.routingMode, bypassRegion: context.bypassRegion,
                            routingPolicyVersion: context.routingPolicyVersion, idempotencyKey: key)
                    },
                    enqueue: { [weak self] event in
                        guard let self, scopeIsCurrent() else { throw NativePSKPreparation.Failure.scopeChanged }
                        _ = try self.nativePushPSKQueue.enqueue(event, owner: owner)
                        self.nativePushEventOwner = owner
                    },
                    processStagedEvents: { [weak self] in await self?.processNativePSKEvents() }
                ))
            } catch {
                guard scopeIsCurrent() else { return }
                self.nativePushEventError = "Не удалось подготовить смену ключа. Текущий профиль не заменён; повторите явно."
            }
        }
    }

    func receivedNativeRemoteNotification(_ userInfo: [String: Any]) {
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession,
              let aps = userInfo["aps"] as? [String: Any],
              (aps["content-available"] as? NSNumber)?.intValue == 1,
              let currentSession = session else { return }
        let generation = authenticatedSessionGeneration
        let accountID = currentSession.user.id
        let token = currentSession.accessToken
        let ordinaryProfileChange = userInfo["vex"] == nil
        // APS-only receipt remains generic account invalidation. A present vex
        // envelope must validate before any refresh or durable event admission.
        if userInfo["vex"] != nil {
            guard let event = NativePushPSKEvent.parse(userInfo),
                  let managedDeviceID = nativePushDeviceID,
                  event.deviceID == managedDeviceID,
                  let owner = NativePushPSKEventOwner(accountID: accountID, installationID: nativePushIdentityStore.getOrCreateDeviceId()) else { return }
            // A validated key-rotation hint supersedes a normal snapshot too.
            // Do not let an older suspended normal fetch recreate its candidate.
            nativeNormalPendingTunnel = nil
            nativeNormalProfileReconciliationGeneration &+= 1
            do {
                // A duplicate is already durable and may trigger an offline retry.
                _ = try nativePushPSKQueue.enqueue(event, owner: owner)
                nativePushEventOwner = owner
                nativePushEventError = nil
            } catch {
                nativePushEventError = "Не удалось сохранить событие смены ключей. Профиль не применён."
                // Never ACK or consume an event that failed durable admission.
                // Generic account invalidation is still safe: a corrupt inbox
                // must not suppress all account/access refreshes indefinitely.
            }
        }
        if ordinaryProfileChange {
            nativeNormalPendingTunnel = nil
            nativeNormalProfileReconciliationGeneration &+= 1
            // Evict synchronously, before any suspension; never derive a profile
            // or PSK event from the uncorrelated APS payload.
            profileWarmupTask?.cancel()
            try? profileService.invalidateNormalCache(accountID: accountID)
        }
        let profileChangeGeneration = nativeNormalProfileReconciliationGeneration
        Task { [weak self] in
            guard let self, self.canUseNativeRemotePush, self.nativeRemotePushEnabled, self.nativePushConsentMatchesSession,
                  (try? self.ensureAuthenticatedSessionCurrent(generation: generation, accessToken: token, accountID: accountID)) != nil else { return }
            guard !ordinaryProfileChange || self.nativeNormalProfileReconciliationGeneration == profileChangeGeneration else { return }
            await self.refreshCustomerState()
            guard (try? self.ensureAuthenticatedSessionCurrent(generation: generation, accessToken: token, accountID: accountID)) != nil else { return }
            if ordinaryProfileChange {
                await self.reconcileNativeNormalProfileChange(generation: generation, accessToken: token, accountID: accountID, profileChangeGeneration: profileChangeGeneration)
            }
            await self.processNativePSKEvents()
        }
    }

    /// APS is an invalidation hint only. Fetch an authenticated signed snapshot
    /// for the existing registered installation; never create/register a device.
    private func reconcileNativeNormalProfileChange(generation: Int, accessToken: String, accountID: String, profileChangeGeneration: Int) async {
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession,
              nativePushRegistration.status == .registered,
              nativePushAccountID == accountID, nativePushSessionGeneration == generation,
              nativeNormalProfileReconciliationGeneration == profileChangeGeneration,
              entitlement?.hasPaidAccess == true, !isVpnBusy, !isDeviceBusy,
              !isServerSelectionBusy, !isNativePSKPreparationBusy, !Task.isCancelled,
              let deviceID = nativePushDeviceID,
              let installationID = nativePushIdentityStore.existingDeviceId(),
              let device = accountDevices.first(where: { $0.id == deviceID }),
              device.status == "active", device.platform?.lowercased() == "macos",
              device.provisioningMode == "managed_native", device.clientKeyOwnership == "client",
              device.protocol?.lowercased() == "amneziawg", device.externalDeviceId == installationID,
              let locationID = targetLocationId,
              (try? ensureAuthenticatedSessionCurrent(generation: generation, accessToken: accessToken, accountID: accountID)) != nil else { return }
        let selectedID = selectedLocationId
        let mode = routingMode
        let vpnGeneration = vpnOperationGeneration
        let previousActive = activeTunnel
        let previousPrepared = nativePSKPreparedTunnel
        let scopeIsCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self, self.canUseNativeRemotePush, self.nativeRemotePushEnabled,
                  self.nativePushConsentMatchesSession, self.nativePushRegistration.status == .registered,
                  self.nativePushAccountID == accountID, self.nativePushSessionGeneration == generation,
                  self.nativeNormalProfileReconciliationGeneration == profileChangeGeneration,
                  self.nativePushDeviceID == deviceID, self.nativePushIdentityStore.existingDeviceId() == installationID,
                  self.entitlement?.hasPaidAccess == true, !self.isVpnBusy, !self.isDeviceBusy,
                  !self.isServerSelectionBusy, !self.isNativePSKPreparationBusy, !Task.isCancelled,
                  self.targetLocationId == locationID, self.selectedLocationId == selectedID, self.routingMode == mode,
                  self.vpnOperationGeneration == vpnGeneration, self.activeTunnel == previousActive,
                  self.nativePSKPreparedTunnel == previousPrepared,
                  self.accountDevices.first(where: { $0.id == deviceID }) == device else { return false }
            return (try? self.ensureAuthenticatedSessionCurrent(generation: generation, accessToken: accessToken, accountID: accountID)) != nil
        }
        do {
            let prepared = try await profileService.refreshRegisteredNormalProfile(
                accessToken: accessToken, device: device, locationId: locationID,
                routingMode: mode, accountID: accountID,
                validateCurrent: {
                    guard scopeIsCurrent() else { throw AuthenticatedOperationError.sessionChanged }
                })
            guard scopeIsCurrent() else { return }
            // No activeTunnel assignment: its observer would rebind registration.
            if let source = previousActive {
                guard prepared.device.id == source.device.id,
                      prepared.device.externalDeviceId == installationID,
                      source.device.externalDeviceId == installationID,
                      prepared.device.publicKey == source.device.publicKey,
                      prepared.locationId == source.locationId, prepared.routingMode == source.routingMode,
                      prepared.bypassRegion == source.bypassRegion,
                      let sourceVersion = source.profileVersion, sourceVersion > 0,
                      let version = prepared.profileVersion, version > 0,
                      (version != sourceVersion || prepared.config != source.config ||
                       prepared.routingPolicyVersion != source.routingPolicyVersion ||
                       prepared.bypassRangesCount != source.bypassRangesCount || prepared.bypassDomainsCount != source.bypassDomainsCount) else { return }
                nativeNormalPendingTunnel = prepared
                nativePushEventError = nil
                await processNativeNormalPendingProfile()
            } else {
                nativePSKPreparedTunnel = prepared
                nativePushEventError = nil
            }
            // The active-source path uses only the authenticated protected
            // transaction; generic `up` is never a normal-profile cutover.
        } catch {
            guard scopeIsCurrent() else { return }
            nativePushEventError = "Не удалось безопасно обновить VPN-профиль. Активное подключение не изменено."
        }
    }

    /// Reauthorize the signed candidate before a protected helper transaction.
    /// No install, generic up/down, endpoint fallback, or PSK admission/ACK.
    /// Active-profile promotion requires the exact fresh-handshake commit receipt.
    private func nativeAdmittedProfileScope(for tunnel: PreparedTunnel) throws -> NativeAdmittedProfileStore.Scope {
        guard let current = session, let installation = nativePushIdentityStore.existingDeviceId(),
              tunnel.device.externalDeviceId == installation else { throw NativeAdmittedProfileStore.Failure.staleSource }
        return .init(accountID: current.user.id, installationID: installation,
                     sessionGeneration: authenticatedSessionGeneration)
    }

    /// Admission is optional for an ordinary connect (e.g. anti-leak is disabled),
    /// but mandatory for a later protected cutover. Never infer it from UI/cache.
    private func rememberNativeAdmittedProfile(_ tunnel: PreparedTunnel, canonicalConfig: String,
        helper: VEXHelperModel, generation: Int, sessionGeneration: Int?, accessToken token: String?, accountID: String?) async {
        do {
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration,
                                          accessToken: token, accountID: accountID)
            let scope = try nativeAdmittedProfileScope(for: tunnel)
            let isCurrent: @MainActor () -> Bool = { [weak self, weak helper] in
                guard let self, let helper, helper.canUseExistingValidatedHelper,
                      (try? self.nativeAdmittedProfileScope(for: tunnel)) == scope else { return false }
                return (try? self.ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration,
                    accessToken: token, accountID: accountID)) != nil
            }
            guard isCurrent() else { return }
            nativeAdmittedProfiles.clear()
            let owner = try await helper.verifyAdmittedSource(NativeProtectedReplacementCoordinator.digest(canonicalConfig),
                                                              isCurrent: isCurrent)
            guard isCurrent() else { return }
            try nativeAdmittedProfiles.record(tunnel: tunnel, canonicalConfig: canonicalConfig,
                                              ownerTokenSHA256: owner, scope: scope, helper: helper)
        } catch {
            // A denied/missing proof must not disconnect an otherwise verified
            // ordinary connection. Protected replacement remains fail-closed.
        }
    }

    private func processNativeNormalPendingProfile() async {
        guard let candidate = nativeNormalPendingTunnel, let source = activeTunnel,
              let helper = nativePSKHelper, helper.canUseExistingValidatedHelper,
              !helper.isBusy, desiredVpnState == .connected,
              helper.status.isUsableConnectedStatus, tunnel(source, matches: helper.status),
              let current = session,
              let installation = nativePushIdentityStore.existingDeviceId(),
              let device = accountDevices.first(where: { $0.id == source.device.id }) else { return }
        let sessionGeneration = authenticatedSessionGeneration
        let profileGeneration = nativeNormalProfileReconciliationGeneration
        let vpnGeneration = vpnOperationGeneration
        let selectedID = selectedLocationId
        let prepared = nativePSKPreparedTunnel
        guard let admissionScope = try? nativeAdmittedProfileScope(for: source),
              let admittedSource = try? nativeAdmittedProfiles.source(for: source, scope: admissionScope, helper: helper) else { return }
        var expectedCandidate = candidate
        var cutoverStarted = false
        let scopeIsCurrent: @MainActor () -> Bool = { [weak self, weak helper] in
            guard let self, let helper, self.nativePSKHelper === helper,
                  helper.canUseExistingValidatedHelper, (!helper.isBusy || cutoverStarted),
                  self.desiredVpnState == .connected, !Task.isCancelled,
                  (cutoverStarted || (helper.status.isUsableConnectedStatus && self.tunnel(source, matches: helper.status))),
                  self.activeTunnel == source, self.nativePSKPreparedTunnel == prepared,
                  self.nativeNormalPendingTunnel == expectedCandidate,
                  self.nativeNormalProfileReconciliationGeneration == profileGeneration,
                  self.vpnOperationGeneration == vpnGeneration,
                  self.selectedLocationId == selectedID, self.targetLocationId == expectedCandidate.locationId,
                  self.routingMode == expectedCandidate.routingMode,
                  self.nativePushIdentityStore.existingDeviceId() == installation,
                  (try? self.nativeAdmittedProfileScope(for: source)) == admissionScope,
                   self.nativeAdmittedProfiles.isCurrent(admittedSource, scope: admissionScope, helper: helper),
                   self.accountDevices.first(where: { $0.id == device.id }) == device else { return false }
            return (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration,
                accessToken: current.accessToken, accountID: current.user.id)) != nil
        }
        guard scopeIsCurrent() else { return }
        // A retained usable UI status after an unsuccessful read is not evidence.
        guard await helper.refreshStatus(quiet: true), scopeIsCurrent() else { return }
        do {
            let authorized = try await profileService.refreshRegisteredNormalProfile(
                accessToken: current.accessToken, device: device, locationId: candidate.locationId,
                routingMode: candidate.routingMode, accountID: current.user.id,
                validateCurrent: {
                    guard scopeIsCurrent() else { throw AuthenticatedOperationError.sessionChanged }
                })
            guard scopeIsCurrent() else { return }
            // The computed setter rechecks the signed expiry, device/client-key
            // and route tuple and meaningful change against the active source.
            expectedCandidate = authorized
            nativeNormalPendingTunnel = authorized
            guard scopeIsCurrent() else { return }
            let validateCurrent: @MainActor () throws -> Void = {
                guard scopeIsCurrent() else { throw AuthenticatedOperationError.sessionChanged }
            }
            let sourceConfig = admittedSource.canonicalConfig
            let candidateConfig = try await profileService.prepareProtectedHelperConfig(for: authorized, validateCurrent: validateCurrent)
            try validateCurrent()
            cutoverStarted = true
            let receipt = try await helper.replaceProfilePreservingProtection(
                sourceSHA256: NativeProtectedReplacementCoordinator.digest(sourceConfig),
                candidateSHA256: NativeProtectedReplacementCoordinator.digest(candidateConfig),
                sourceOwnerTokenSHA256: admittedSource.ownerTokenSHA256,
                stageCandidate: { [profileService] in
                    try profileService.stageProtectedHelperConfig(candidateConfig, validateCurrent: validateCurrent)
                }, restoreSource: { [profileService] in
                    try profileService.stageProtectedHelperConfig(sourceConfig, validateCurrent: validateCurrent)
                }, isCurrent: scopeIsCurrent)
            try validateCurrent()
            try nativeAdmittedProfiles.record(tunnel: authorized, canonicalConfig: candidateConfig,
                ownerTokenSHA256: receipt.ownerTokenSHA256, scope: admissionScope, helper: helper)
            nativeNormalPendingTunnel = nil
            activeTunnel = authorized
            nativePSKPreparedTunnel = authorized
            activeResilienceRoute = nil
            nativePushEventError = nil
        } catch {
            guard scopeIsCurrent() else { return }
            nativePushEventError = helper.hasPendingProtectedReplacement
                ? "Обновление профиля требует защищённого восстановления. Новый профиль не подтверждён; обычное переподключение запрещено."
                : "Обновление VPN-профиля не завершено. Новый профиль не подтверждён; кандидат сохранён для повторной проверки."
        }
    }

    func configureNativePSKProcessing(using helper: VEXHelperModel) {
        guard nativePushRuntimeAllowed else { return }
        nativePSKHelper = helper
        startNativePSKRetryIfNeeded()
    }

    /// Product-owned foreground retry, not a Codex/production polling loop. No work
    /// occurs without signed APNs capability, explicit account consent and a bound device.
    private func startNativePSKRetryIfNeeded() {
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession,
              nativePSKHelper != nil, nativePSKRetryTask == nil else { return }
        nativePSKRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.canUseNativeRemotePush, self.nativeRemotePushEnabled,
                      self.nativePushConsentMatchesSession else { return }
                await self.processNativePSKEvents()
            }
        }
    }

    private func processNativePSKEvents() async {
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession,
              entitlement?.hasPaidAccess == true,
              !isVpnBusy, !isDeviceBusy, let helper = nativePSKHelper, !helper.isBusy,
              let current = session, let deviceID = nativePushDeviceID,
              let installation = nativePushIdentityStore.existingDeviceId(),
              let owner = NativePushPSKEventOwner(accountID: current.user.id, installationID: installation),
              let previous = nativePSKCommittedPromotion?.source ?? activeTunnel ?? nativePSKPreparedTunnel,
              previous.device.id == deviceID else { return }
        let sessionGeneration = authenticatedSessionGeneration
        let token = current.accessToken
        let selectedID = selectedLocationId
        let requestedRouting = routingMode
        var expectedVpnGeneration = vpnOperationGeneration
        nativePushEventOwner = owner
        let scopeIsCurrent: () -> Bool = { [weak self, weak helper] in
            guard let self, let helper, self.canUseNativeRemotePush, self.nativeRemotePushEnabled,
                  self.nativePushConsentMatchesSession, self.entitlement?.hasPaidAccess == true,
                  self.nativePushDeviceID == deviceID,
                  self.selectedLocationId == selectedID, self.routingMode == requestedRouting,
                  self.vpnOperationGeneration == expectedVpnGeneration,
                  !self.isVpnBusy, !self.isDeviceBusy, !helper.isBusy, !Task.isCancelled else { return false }
            return (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: owner.accountID)) != nil
        }
        await nativePSKConsumer.process(owner: owner, managedDeviceID: deviceID, dependencies: .init(
            scopeIsCurrent: scopeIsCurrent,
            fetchCurrent: { [api] in try await api.currentPSKRotation(accessToken: token, deviceID: deviceID) },
            validate: { [weak self] envelope, event in
                guard let self, scopeIsCurrent() else { throw AuthenticatedOperationError.sessionChanged }
                let verified = try self.nativePSKVerifier.verifyDetailed(envelope, ownerAccountID: owner.accountID,
                    managedDeviceID: deviceID, locationID: previous.locationId, routingMode: previous.routingMode.rawValue,
                    bypassRegion: previous.bypassRegion)
                // cutover may arrive after the staging deadline; signed policy expiry,
                // exact event/version/device/digest and local client-key binding still apply.
                let admissionEvent = NativePushPSKEvent(kind: event.kind, eventID: event.eventID,
                    rotationID: event.rotationID, deviceID: event.deviceID, profileVersion: event.profileVersion, deadlineAt: event.deadlineAt)
                try NativePSKRotationValidation.validate(envelope: verified.envelope, event: admissionEvent,
                    managedDeviceID: deviceID, expectedClientPublicKey: self.profileService.existingStagedPSKClientPublicKey(),
                    requireStagingDeadline: event.kind == .profile_updated)
                // Reuse the helper's pure AWG admission before persisting or ACKing.
                // This builds only in memory and issues no helper/DNS/key creation.
                _ = try self.profileService.prepareStagedPSKProfile(verified, basedOn: previous)
            },
            acknowledge: { [api] envelope in
                try await api.acknowledgePSKRotation(accessToken: token, rotationID: envelope.rotationID,
                    deviceID: deviceID, profileVersion: envelope.profileVersion, profileDigest: envelope.profileDigest)
            },
            activate: { [weak self, weak helper] envelope, _ in
                guard let self, let helper, scopeIsCurrent() else { throw AuthenticatedOperationError.sessionChanged }
                expectedVpnGeneration = try await self.applyNativePSKCutover(envelope, previous: previous, owner: owner,
                    helper: helper, sessionGeneration: sessionGeneration, token: token)
            },
            didFail: { [weak self] error in
                guard let self, scopeIsCurrent() else { return }
                if case NativePSKEventConsumer.Failure.stagedCleanupPending = error {
                    self.nativePushEventError = "Профиль применён; очистка сохранённой копии не завершена и будет повторена при выходе из аккаунта."
                } else if case NativeVPNProfileAuthorizationVerifier.Failure.missingTrustAnchor = error {
                    self.nativePushEventError = "Для смены ключей нужен доверенный публичный ключ сервера в релизной сборке. Событие сохранено."
                } else {
                    self.nativePushEventError = "Смена ключей не завершена. Событие сохранено для безопасного повтора."
                }
            }
        ))
    }

    /// No helper operation is issued for a confirmed idle tunnel. A connected cutover
    /// replaces only our exactly matched active profile and retains anti-leak protection.
    private func applyNativePSKCutover(
        _ envelope: PSKRotationCurrentResponse, previous: PreparedTunnel, owner: NativePushPSKEventOwner,
        helper: VEXHelperModel, sessionGeneration: Int, token: String
    ) async throws -> Int {
        try ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: owner.accountID)
        guard entitlement?.hasPaidAccess == true, !isVpnBusy, !isDeviceBusy, !helper.isBusy else { throw CancellationError() }
        let verified = try nativePSKVerifier.verifyDetailed(envelope, ownerAccountID: owner.accountID,
            managedDeviceID: previous.device.id, locationID: previous.locationId, routingMode: previous.routingMode.rawValue,
            bypassRegion: previous.bypassRegion)
        let next = try profileService.prepareStagedPSKProfile(verified, basedOn: previous)
        if let promotion = nativePSKCommittedPromotion {
            // Reverify the signed envelope against the ORIGINAL source version.
            // The promoted in-memory candidate is not a new rotation source.
            guard promotion.owner == owner, promotion.source == previous,
                  promotion.candidate == next, nativePSKHelper === helper,
                  promotion.isCurrent() else { throw AuthenticatedOperationError.sessionChanged }
            isVpnBusy = true
            defer { isVpnBusy = false }
            let current: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return promotion.isCurrent()
                    && self.nativePSKCommittedPromotion?.receipt == promotion.receipt
            }
            let persistence = try nativePSKPromotionPersistence(previous: previous, next: next, owner: owner,
                helper: helper, generation: promotion.generation, sessionGeneration: sessionGeneration, token: token)
            let admissionScope = try nativeAdmittedProfileScope(for: next)
            guard let material = try nativeAdmittedProfiles.candidate(for: next, scope: admissionScope, helper: helper,
                intentFingerprint: persistence.scopeFingerprint, generation: promotion.generation) else {
                throw NativeAdmittedProfileStore.Failure.missingCandidate
            }
            try await helper.revalidateProtectedCommit(promotion.receipt, isCurrent: current, persistence: persistence)
            guard current() else { throw AuthenticatedOperationError.sessionChanged }
            try profileService.promoteStagedPSKProfile(next, owner: owner)
            try helper.finishProtectedPromotion(promotion.receipt, persistence: persistence, isCurrent: current)
            nativeAdmittedProfiles.forgetCandidate(material)
            nativePSKCommittedPromotion = nil
            nativePushEventError = nil
            return promotion.generation
        }
        // Status is only a hint during an ambiguous transaction. A retained
        // intent must go through scoped material and authenticated root proof,
        // even if the status now shows the candidate or appears idle.
        let hasRetainedIntent = try nativeProtectedPromotionStore.hasRecord(accountID: owner.accountID, installationID: owner.installationID)
        guard helper.status.isUsableConnectedStatus || hasRetainedIntent else {
            guard helper.hasConfirmedIdleStatus, !helper.status.hasManagedNetworkState else { throw CancellationError() }
            try profileService.promoteStagedPSKProfile(next, owner: owner)
            activeTunnel = next
            nativePSKPreparedTunnel = next
            return vpnOperationGeneration
        }
        guard let activeTunnel, activeTunnel == previous,
              (tunnel(previous, matches: helper.status) || hasRetainedIntent),
              helper.canUseExistingValidatedHelper, nativePSKHelper === helper else {
            throw CancellationError() // Never replace an unowned/external active tunnel.
        }
        let admissionScope = try nativeAdmittedProfileScope(for: previous)
        let admittedSource = try nativeAdmittedProfiles.source(for: previous, scope: admissionScope, helper: helper)
        isVpnBusy = true
        defer { isVpnBusy = false }
        desiredVpnState = .connected
        // A retained private intent must use its original generation. A changed
        // user/session scope will fail the exact persisted binding before RPC.
        if !hasRetainedIntent {
            vpnOperationGeneration += 1
        }
        let generation = vpnOperationGeneration
        let persistence = try nativePSKPromotionPersistence(previous: previous, next: next, owner: owner,
            helper: helper, generation: generation, sessionGeneration: sessionGeneration, token: token)
        let selectedID = selectedLocationId
        let targetID = targetLocationId
        let routeMode = routingMode
        let prepared = nativePSKPreparedTunnel
        var candidateCommitted = false
        var candidateMaterial: NativeAdmittedProfileStore.Candidate?
        let scopeIsCurrent: @MainActor () -> Bool = { [weak self, weak helper] in
            guard let self, let helper, self.nativePSKHelper === helper,
                  helper.canUseExistingValidatedHelper, !Task.isCancelled,
                  self.activeTunnel == previous, self.nativePSKPreparedTunnel == prepared,
                   (try? self.nativeAdmittedProfileScope(for: previous)) == admissionScope,
                    (candidateCommitted || self.nativeAdmittedProfiles.isCurrent(admittedSource, scope: admissionScope, helper: helper)),
                    (candidateMaterial.map { self.nativeAdmittedProfiles.isCurrent($0, scope: admissionScope, helper: helper) } ?? true),
                   self.selectedLocationId == selectedID, self.targetLocationId == targetID,
                  self.routingMode == routeMode, self.entitlement?.hasPaidAccess == true else { return false }
            return (try? self.ensureConnectStillDesired(generation: generation,
                sessionGeneration: sessionGeneration, accessToken: token, accountID: owner.accountID)) != nil
        }
        let validateCurrent: @MainActor () throws -> Void = {
            guard scopeIsCurrent() else { throw AuthenticatedOperationError.sessionChanged }
        }
        do {
            let sourceConfig = admittedSource.canonicalConfig
            if let retained = try nativeAdmittedProfiles.candidate(for: next, scope: admissionScope, helper: helper,
                intentFingerprint: persistence.scopeFingerprint, generation: generation, source: admittedSource) {
                candidateMaterial = retained
            } else {
                // TODO: Full app-crash material reconciliation needs signed-profile
                // revalidation and explicit process ownership transfer. Missing
                // memory plus private metadata is not permission to resolve DNS
                // again or adopt a physical candidate from another process.
                guard !hasRetainedIntent else { throw NativeAdmittedProfileStore.Failure.missingCandidate }
                let config = try await profileService.prepareProtectedHelperConfig(for: next, validateCurrent: validateCurrent)
                try validateCurrent()
                candidateMaterial = try nativeAdmittedProfiles.recordCandidate(tunnel: next, canonicalConfig: config,
                    source: admittedSource, scope: admissionScope, helper: helper,
                    intentFingerprint: persistence.scopeFingerprint, generation: generation)
            }
            guard let material = candidateMaterial else { throw NativeAdmittedProfileStore.Failure.missingCandidate }
            let candidateConfig = material.canonicalConfig
            try validateCurrent()
            let receipt = try await helper.replaceProfilePreservingProtection(
                sourceSHA256: NativeProtectedReplacementCoordinator.digest(sourceConfig),
                candidateSHA256: NativeProtectedReplacementCoordinator.digest(candidateConfig),
                sourceOwnerTokenSHA256: admittedSource.ownerTokenSHA256,
                stageCandidate: { [profileService] in
                    try profileService.stageProtectedHelperConfig(candidateConfig, validateCurrent: validateCurrent)
                }, restoreSource: { [profileService] in
                    try profileService.stageProtectedHelperConfig(sourceConfig, validateCurrent: validateCurrent)
                }, isCurrent: scopeIsCurrent, persistence: persistence)
            candidateCommitted = true
            try validateCurrent()
            let admittedCandidate = try nativeAdmittedProfiles.record(tunnel: next, canonicalConfig: candidateConfig,
                ownerTokenSHA256: receipt.ownerTokenSHA256, scope: admissionScope, helper: helper)
            nativePSKCommittedPromotion = (previous, next, owner, receipt, generation, { [weak self, weak helper] in
                guard let self, let helper, self.nativePSKHelper === helper,
                      helper.canUseExistingValidatedHelper, !Task.isCancelled,
                      !self.isDeviceBusy, self.activeTunnel == next, self.nativePSKPreparedTunnel == next,
                       (try? self.nativeAdmittedProfileScope(for: next)) == admissionScope,
                        self.nativeAdmittedProfiles.isCurrent(admittedCandidate, scope: admissionScope, helper: helper),
                        self.nativeAdmittedProfiles.isCurrent(material, scope: admissionScope, helper: helper),
                       self.selectedLocationId == selectedID, self.targetLocationId == targetID,
                      self.routingMode == routeMode, self.entitlement?.hasPaidAccess == true else { return false }
                return (try? self.ensureConnectStillDesired(generation: generation,
                    sessionGeneration: sessionGeneration, accessToken: token, accountID: owner.accountID)) != nil
            })
            try profileService.promoteStagedPSKProfile(next, owner: owner)
            try helper.finishProtectedPromotion(receipt, persistence: persistence, isCurrent: scopeIsCurrent)
            nativeAdmittedProfiles.forgetCandidate(material)
            nativePSKCommittedPromotion = nil
            self.activeTunnel = next
            nativePSKPreparedTunnel = next
            activeResilienceRoute = nil
            nativePushEventError = nil
            return generation
        } catch {
            // The protected coordinator alone owns rollback. A cache error after
            // a confirmed commit must not reconnect the old profile or pretend
            // it is still the active physical tunnel.
            try validateCurrent()
            if candidateCommitted {
                self.activeTunnel = next
                nativePSKPreparedTunnel = next
                activeResilienceRoute = nil
                // Retain the exact receipt/source tuple for authenticated,
                // cache-only retry; no generic reconnect is a valid fallback.
            } else if !helper.hasPendingProtectedReplacement,
                      (try? nativeProtectedPromotionStore.hasRecord(accountID: owner.accountID, installationID: owner.installationID)) == false,
                      let material = candidateMaterial {
                // Only a confirmed source recovery or a pre-mutation failure
                // with no durable intent permits a new candidate preparation.
                nativeAdmittedProfiles.forgetCandidate(material)
            }
            nativePushEventError = helper.hasPendingProtectedReplacement
                ? "Смена ключей требует защищённого восстановления. Обычное переподключение запрещено; событие сохранено."
                : "Смена ключей не завершена полностью. Событие сохранено; обычное переподключение не выполнялось."
            throw error
        }
    }

    private func nativePSKPromotionPersistence(previous: PreparedTunnel, next: PreparedTunnel, owner: NativePushPSKEventOwner,
        helper: VEXHelperModel, generation: Int, sessionGeneration: Int, token: String) throws -> NativeProtectedReplacementCoordinator.Persistence {
        // Full value representations are hashed in memory, not stored or logged.
        // Current process/helper/session/user intent are independently rechecked
        // at every async boundary and by the root peer/owner authentication.
        let scope = NativeProtectedPromotionStore.fingerprint(["vex-psk-promotion-intent-v1", owner.accountID,
            owner.installationID, String(sessionGeneration), NativeProtectedReplacementCoordinator.digest(token),
            String(reflecting: previous), String(reflecting: next), String(describing: ObjectIdentifier(helper)),
            selectedLocationId, targetLocationId ?? "", routingMode.rawValue])
        return try nativeProtectedPromotionStore.persistence(accountID: owner.accountID, installationID: owner.installationID,
            scopeFingerprint: scope, generation: generation)
    }

    private func observeNativePushSession() {
        nativePushRegistration.$status.sink { [weak self] status in
            if status != .registered { self?.nativeNormalPendingTunnel = nil }
        }.store(in: &cancellables)
        nativePushRegistrar.isCurrent = { [weak self] request in
            guard let self, self.canUseNativeRemotePush, self.nativeRemotePushEnabled, self.nativePushConsentMatchesSession,
                  self.nativePushDeviceID == request.deviceID else { return false }
            return (try? self.ensureAuthenticatedSessionCurrent(generation: request.sessionGeneration, accessToken: request.accessToken, accountID: request.accountID)) != nil
        }
        $session.sink { [weak self] _ in
            self?.nativeNormalPendingTunnel = nil
            Task { @MainActor [weak self] in self?.reconcileNativePushSession() }
        }.store(in: &cancellables)
        $activeTunnel.sink { [weak self] tunnel in
            guard let self else { return }
            self.nativeNormalPendingTunnel = nil
            guard let tunnel, let owner = self.session?.user.id else { return }
            self.nativePSKPreparedTunnel = tunnel
            let generation = self.authenticatedSessionGeneration
            Task { @MainActor [weak self] in
                self?.bindNativePushDevice(tunnel.device.id, accountID: owner, generation: generation)
            }
        }.store(in: &cancellables)
    }

    private func bindNativePushDevice(_ deviceID: String, accountID: String, generation: Int) {
        guard nativePushRuntimeAllowed, !deviceID.isEmpty,
              (try? ensureAuthenticatedSessionCurrent(generation: generation, accountID: accountID)) != nil else { return }
        if nativePushDeviceID != deviceID || nativePushAccountID != accountID || nativePushSessionGeneration != generation {
            nativeNormalPendingTunnel = nil
        }
        nativePushDeviceID = deviceID
        nativePushAccountID = accountID
        nativePushSessionGeneration = generation
        reconcileNativePushSession()
    }

    private func reconcileNativePushSession() {
        _ = nativeNormalPendingTunnel // Drop any obsolete memory-only owner scope.
        if let owner = nativePushEventOwner, owner.accountID != session?.user.id {
            nativePSKRetryTask?.cancel()
            nativePSKRetryTask = nil
            nativePSKPreparedTunnel = nil
            purgeNativePushPSKEvents()
        }
        guard canUseNativeRemotePush, nativeRemotePushEnabled, nativePushConsentMatchesSession, let currentSession = session else {
            nativePushRegistration.clearAuthenticatedSession()
            return
        }
        if nativePushAccountID != currentSession.user.id || nativePushSessionGeneration != authenticatedSessionGeneration {
            nativePushRegistration.clearAuthenticatedSession()
            nativePushDeviceID = nil
            nativePushAccountID = currentSession.user.id
            nativePushSessionGeneration = authenticatedSessionGeneration
        }
        startNativePSKRetryIfNeeded()
        nativePushRegistration.setRegistrationEnabled(true)
        if !nativePushRegistrationRequested, registerNativePushAction != nil {
            nativePushRegistrationRequested = true
            registerNativePushAction?()
        }
        if let tokenData = nativeApplePushToken, let deviceID = nativePushDeviceID {
            nativePushRegistration.registerAppleDeviceToken(tokenData, accountID: currentSession.user.id, deviceID: deviceID,
                accessToken: currentSession.accessToken, sessionGeneration: authenticatedSessionGeneration)
        }
    }

    private func nativePushConsentFingerprint(_ accountID: String) -> String {
        SHA256.hash(data: Data(("vex-native-push-consent\u{0}" + accountID).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var nativePushConsentMatchesSession: Bool {
        guard let accountID = session?.user.id.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty else { return false }
        return nativeRemotePushConsentAccount == nativePushConsentFingerprint(accountID)
    }

    private func purgeNativePushPSKEvents() {
        nativePSKCommittedPromotion = nil
        guard nativePushRuntimeAllowed else { return }
        // Read an existing installation only; cleanup must not create an identity
        // or prompt for Keychain access just to remove old metadata.
        let owner = nativePushEventOwner ?? NativePushPSKEventOwner(
            accountID: session?.user.id,
            installationID: nativePushIdentityStore.existingDeviceId()
        )
        guard let owner else { return }
        do {
            // Stages remain after metadata ACK, so an owner tuple index—not the
            // event queue—is authoritative for deleting old secret profiles.
            try nativePSKStageStore.purgeAll(owner: owner)
            try nativeProtectedPromotionStore.purge(accountID: owner.accountID, installationID: owner.installationID)
            try nativePushPSKQueue.purge(owner: owner)
            nativePushEventOwner = nil
            nativePushEventError = nil
        } catch {
            nativePushEventError = "Не удалось удалить локальные события смены ключей. Они не будут применены другой учётной записью."
        }
    }

    private func invalidateNativePushSession(resetConsent: Bool = false) {
        nativeAdmittedProfiles.clear()
        nativePSKCommittedPromotion = nil
        nativeNormalPendingTunnel = nil
        nativePSKRetryTask?.cancel()
        nativePSKRetryTask = nil
        nativePSKPreparedTunnel = nil
        if resetConsent {
            purgeNativePushPSKEvents()
            nativeRemotePushEnabled = false
            nativeRemotePushConsentAccount = ""
        }
        nativePushRegistration.clearAuthenticatedSession()
        nativeApplePushToken = nil
        nativePushDeviceID = nil
        nativePushAccountID = nil
        nativePushSessionGeneration = nil
        nativePushRegistrationError = nil
        if nativePushRegistrationRequested, nativePushRuntimeAllowed { unregisterNativePushAction?() }
        nativePushRegistrationRequested = false
    }

    var selectedLocationId: String {
        get { storedSelectedLocationId }
        set {
            if storedSelectedLocationId != newValue { nativeNormalPendingTunnel = nil }
            storedSelectedLocationId = newValue
        }
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
        nativeUpdater.isEnabled
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
        if let storedSession = sessionStore.loadSession(requiresBiometricAuthentication: biometricUnlockRequired) {
            session = storedSession
            user = storedSession.user
            canUnlockStoredSession = true
            startCustomerRealtime(accessToken: storedSession.accessToken)
        } else if biometricUnlockRequired && biometricAvailability.isAvailable && canUnlockStoredSession {
            statusMessage = "Подтвердите вход по \(biometricAvailability.label)."
            autoLaunchEnabled = startupService.isEnabled()
            await loadUpdate(reportErrors: false)
            await loadRemoteConfig()
            return
        }
        autoLaunchEnabled = startupService.isEnabled()
        await refreshAll()
        await restoreActiveTunnelIfHelperIsConnected(helperStatus)
        scheduleProfileWarmup()
    }

    func refreshAll() async {
        async let updateResult: Void = loadUpdate(reportErrors: false)
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
        async let billingResult = loadBilling(token)
        async let diagnosticsFlush = diagnosticsService.flush(accessToken: token)
        _ = await [userResult, locationsResult, billingResult, updateResult, remoteConfigResult, diagnosticsFlush]
        await processNativePSKEvents()
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
        guard location.isSelectable else {
            statusMessage = NativeLocationSelectionError.unavailable.localizedDescription
            serverSidebarOperation = .failed(statusMessage ?? "Сервер недоступен.")
            return
        }
        applyManualSelection(locationId: location.id)
        statusMessage = "Выбран сервер: \(location.displayName)."
        serverSidebarOperation = .selected("Выбран сервер: \(location.displayName).")
        scheduleProfileWarmup()
    }

    /// Manual selection = pin the location, leave auto mode, warm the cache.
    private func applyManualSelection(locationId: String) {
        selectedLocationId = locationId
        serverSelectionMode = "manual"
        autoServerEnabled = false
        scheduleProfileWarmup()
    }

    func selectAutoServer(using helper: VEXHelperModel) async {
        await performServerSelection(using: helper) {
            self.selectAutoServer()
        }
    }

    func selectLocation(_ location: VpnLocation, using helper: VEXHelperModel) async {
        guard location.isSelectable else {
            statusMessage = NativeLocationSelectionError.unavailable.localizedDescription
            serverSidebarOperation = .failed(statusMessage ?? "Сервер недоступен.")
            return
        }
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
        guard !isDeviceBusy else {
            statusMessage = "Дождитесь завершения операции с устройством."
            return
        }
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
        guard !isVpnBusy, !isDeviceBusy, !helper.isBusy else {
            statusMessage = desiredVpnState == .connected ? "Операция VPN уже выполняется." : "Отменяем подключение VPN."
            return
        }
        let sessionGeneration = authenticatedSessionGeneration
        let accountID = session?.user.id
        isVpnBusy = true
        defer { isVpnBusy = false }

        let tokenResult = await authenticatedAccessToken()
        guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accountID: accountID)) != nil else { return }
        guard let token = tokenResult else {
            statusMessage = "Сначала войдите в аккаунт."
            return
        }
        guard accessToken == token else { return }
        guard let requestToken = await ensureEntitlementForConnect(accessToken: token) else {
            return
        }
        guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: requestToken, accountID: accountID)) != nil else { return }
        guard entitlement?.hasPaidAccess == true else {
            statusMessage = entitlement == nil ? "Не удалось проверить подписку." : "Для VPN нужна активная подписка."
            await submitDiagnostics(reason: "entitlement_missing_before_connect", status: "auth_error", helperStatus: helper.status, samples: ["message": statusMessage ?? ""])
            return
        }
        // Catalog failures are not failed tunnel attempts. Return before the
        // connect catch/cleanup path so an already running tunnel stays intact.
        guard let targetLocationId else {
            statusMessage = NativeLocationSelectionError.unavailable.localizedDescription
            return
        }
        var operationToken = requestToken
        do {
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: operationToken, accountID: accountID)
            statusMessage = "Готовим VPN-профиль."
            let (tunnel, tunnelToken) = try await resolveProfileForAuthenticatedSession(
                accessToken: requestToken,
                locationId: targetLocationId,
                routingMode: routingMode,
                forceRefresh: false,
                prevalidatedEntitlement: entitlement
            )
            operationToken = tunnelToken
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: operationToken, accountID: accountID)
            let connectedTunnel = try await connectWithAutopilot(
                initialTunnel: tunnel,
                accessToken: tunnelToken,
                helper: helper,
                generation: generation,
                sessionGeneration: sessionGeneration,
                accountID: accountID
            )
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: operationToken, accountID: accountID)
            activeTunnel = connectedTunnel
            statusMessage = "VPN подключен через \(selectedLocation?.displayName ?? connectedTunnel.locationId.uppercased())."
            // Reporting is fire-and-forget: the tunnel is already up, so a slow
            // API round-trip must neither hold the busy state nor delay feedback.
            Task { [weak self, api] in
                guard let self,
                    (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: tunnelToken, accountID: accountID)) != nil else { return }
                await api.reportVpnConnect(accessToken: tunnelToken, tunnel: connectedTunnel)
            }
        } catch AuthenticatedOperationError.sessionChanged {
            // Account changes invalidate preparation, not an already active VPN.
            // Never run disconnect cleanup for a stale authentication operation.
            return
        } catch is CancellationError {
            guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: operationToken, accountID: accountID)) != nil else { return }
            await helper.interruptWithDisconnect(releaseAntiLeak: !antiLeakEnabled)
            guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: operationToken, accountID: accountID)) != nil else { return }
            clearActiveTunnelRouteState()
            statusMessage = "Подключение VPN отменено."
        } catch {
            guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: operationToken, accountID: accountID)) != nil else { return }
            statusMessage = connectErrorMessage(error)
            if !error.localizedDescription.contains("VPN_CONFIG_INVALID") {
                await helper.interruptWithDisconnect(releaseAntiLeak: true)
                guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: operationToken, accountID: accountID)) != nil else { return }
                clearActiveTunnelRouteState()
            } else {
                activeResilienceRoute = nil
                activeResiliencePolicy = nil
            }
            await submitDiagnostics(reason: "vpn_connect_failed", status: "error", helperStatus: helper.status, samples: ["error": error.localizedDescription])
        }

        guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: operationToken, accountID: accountID)) != nil else { return }
        if desiredVpnState == .disconnected, helper.status.state != .disconnected {
            await performDisconnectVPN(using: helper, reason: "user", generation: vpnOperationGeneration)
        }
    }

    private func connectWithAutopilot(initialTunnel: PreparedTunnel, accessToken token: String, helper: VEXHelperModel, generation: Int, sessionGeneration: Int? = nil, accountID: String? = nil) async throws -> PreparedTunnel {
        // TODO(autopilot-full-runtime): the extracted await/identity matrix passes;
        // extend throwing rotation/profile/failover cases and run isolated live
        // tunnel acceptance before claiming end-to-end release qualification.
        let authGeneration = sessionGeneration ?? authenticatedSessionGeneration
        let owner = accountID ?? session?.user.id
        func verifyOperation() throws {
            try ensureConnectStillDesired(generation: generation, sessionGeneration: authGeneration, accessToken: token, accountID: owner)
        }
        try verifyOperation()
        let resiliencePolicy: ResiliencePolicy?
        if let freshPolicy = try? await api.resiliencePolicy(accessToken: token) {
            try verifyOperation()
            dynamicRouteEngine.cache(policy: freshPolicy)
            resiliencePolicy = freshPolicy
        } else {
            try verifyOperation()
            resiliencePolicy = dynamicRouteEngine.cachedPolicy()
        }
        activeResiliencePolicy = resiliencePolicy
        activeResilienceRoute = nil
        do {
            return try await connectPreparedTunnel(initialTunnel, helper: helper, generation: generation, resiliencePolicy: resiliencePolicy, sessionGeneration: authGeneration, accessToken: token, accountID: owner)
        } catch {
            try verifyOperation()
            if error is AuthenticatedOperationError || error is CancellationError { throw error }
            if error.localizedDescription.contains("VPN_CONFIG_INVALID") { throw error }
            try verifyOperation()

            let probe = await autopilotService.probe(endpoint: initialTunnel.endpoint)
            try verifyOperation()
            let usage = await autopilotService.usage(accessToken: token, deviceId: initialTunnel.device.id)
            try verifyOperation()
            let healthReasons = autopilotService.healthReasons(status: helper.status, usage: usage)
            let assessment = autopilotService.assess(error: error, healthReasons: healthReasons, status: helper.status, probe: probe)
            statusMessage = assessment.userMessage
            await submitDiagnostics(
                reason: "vpn_autopilot_initial_failed",
                status: assessment.diagnosticStatus,
                helperStatus: helper.status,
                samples: assessment.samples.merging(["error": error.localizedDescription]) { current, _ in current }
            )

            try verifyOperation()
            if initialTunnel.rotationRequired || assessment.cause == .keyOrProfile,
               let rotatedTunnel = try await profileService.rotateKey(accessToken: token, currentTunnel: initialTunnel, writeHelperConfig: false, accountID: owner, validateCurrent: { try verifyOperation() }) {
                try verifyOperation()
                return try await connectPreparedTunnel(rotatedTunnel, helper: helper, generation: generation, resiliencePolicy: resiliencePolicy, sessionGeneration: authGeneration, accessToken: token, accountID: owner)
            }

            return try await VpnAdmissionRecovery.retryFreshProfile(shouldFailover: { !($0 is AuthenticatedOperationError) && !($0 is CancellationError) }) {
                try verifyOperation()
                let freshTunnel = try await profileService.resolveProfile(
                    accessToken: token,
                    locationId: initialTunnel.locationId,
                    routingMode: routingMode,
                    forceRefresh: true,
                    writeHelperConfig: false,
                    accountID: owner,
                    validateCurrent: { try verifyOperation() }
                )
                try verifyOperation()
                return try await connectPreparedTunnel(freshTunnel, helper: helper, generation: generation, resiliencePolicy: resiliencePolicy, sessionGeneration: authGeneration, accessToken: token, accountID: owner)
            } failover: { error in
                try verifyOperation()
                guard allowsAutomaticFailover, assessment.canFailover, let failoverLocation = bestFailoverLocation(excluding: initialTunnel.locationId) else {
                    throw error
                }
                applyManualSelection(locationId: failoverLocation.id)
                let failoverTunnel = try await profileService.resolveProfile(
                    accessToken: token,
                    locationId: failoverLocation.id,
                    routingMode: routingMode,
                    forceRefresh: true,
                    writeHelperConfig: false,
                    accountID: owner,
                    validateCurrent: { try verifyOperation() }
                )
                try verifyOperation()
                await submitDiagnostics(
                    reason: "vpn_autopilot_failover",
                    status: assessment.diagnosticStatus,
                    helperStatus: helper.status,
                    samples: assessment.samples.merging([
                        "previous_location_id": initialTunnel.locationId,
                        "next_location_id": failoverLocation.id,
                    ]) { current, _ in current }
                )
                try verifyOperation()
                return try await connectPreparedTunnel(failoverTunnel, helper: helper, generation: generation, resiliencePolicy: resiliencePolicy, sessionGeneration: authGeneration, accessToken: token, accountID: owner)
            }
        }
    }

    private func connectPreparedTunnel(
        _ tunnel: PreparedTunnel,
        helper: VEXHelperModel,
        generation: Int,
        resiliencePolicy: ResiliencePolicy? = nil,
        sessionGeneration: Int? = nil,
        accessToken token: String? = nil,
        accountID: String? = nil,
        releaseAntiLeakOnFailure: Bool = true,
        allowEndpointFallback: Bool = true
    ) async throws -> PreparedTunnel {
        guard !helper.hasPendingProtectedReplacement else {
            throw NativeProtectedReplacementCoordinator.Failure.recoveryPending
        }
        var lastError: Error = VpnAutopilotRuntimeError.connectFailed("VPN connection failed.")
        try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
        activeResilienceRoute = nil
        try await helper.ensureHelperReady()
        try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)

        var attempts: [(tunnel: PreparedTunnel, route: ResilienceConnectionCandidate?)] = []
        if let resiliencePolicy {
            for candidate in dynamicRouteEngine.orderedCandidates(for: tunnel, policy: resiliencePolicy) {
                if let routedTunnel = tunnel.withEndpoint(candidate.endpoint) {
                    attempts.append((routedTunnel, candidate))
                }
            }
        }
        if allowEndpointFallback {
            attempts.append(contentsOf: autopilotService.fallbackTunnels(for: tunnel).map { ($0, nil) })
        } else {
            // A signed staged policy authorizes one endpoint, not transformed ports/routes.
            attempts = [(tunnel, nil)]
        }

        var seenEndpoints = Set<String>()
        attempts = attempts.filter { item in
            let endpoint = item.tunnel.endpoint ?? item.tunnel.configEndpoint ?? item.tunnel.config
            return seenEndpoints.insert(endpoint.lowercased()).inserted
        }

        var previousRouteTransport: String?
        for item in attempts {
            let attempt = item.tunnel
            let routeTransport = item.route.map(dynamicRouteTransport)
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            let previousStatus = helper.status
            let attemptStartedAt = Date()
            let admittedConfig = try await profileService.writeHelperConfig(for: attempt, validateCurrent: { [weak self] in
                guard let self else { throw AuthenticatedOperationError.sessionChanged }
                try self.ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            })
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            await helper.connect(antiLeakEnabled: antiLeakEnabled)
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            if helper.lastConnectAdmissionRejected {
                throw VpnAutopilotRuntimeError.connectFailed("VPN_CONFIG_INVALID: next profile admission failed")
            }
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            let handshakeVerified = try await verifiedHandshake(
                for: attempt,
                helper: helper,
                previousStatus: previousStatus,
                startedAt: attemptStartedAt,
                generation: generation,
                sessionGeneration: sessionGeneration,
                accessToken: token,
                accountID: accountID
            )
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            if handshakeVerified {
                await rememberNativeAdmittedProfile(attempt, canonicalConfig: admittedConfig, helper: helper,
                    generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
                try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
                activeResilienceRoute = item.route
                if let route = item.route, let resiliencePolicy {
                    dynamicRouteEngine.recordSuccess(route, policy: resiliencePolicy)
                    let connectionEvent = previousRouteTransport == nil ? "connect_succeeded" : "fallback_succeeded"
                    submitRouteDiagnostics(
                        connectionEvent: connectionEvent,
                        transportFrom: previousRouteTransport,
                        transportTo: routeTransport,
                        status: "ok",
                        helperStatus: helper.status,
                    sessionGeneration: sessionGeneration,
                    accessToken: token,
                    accountID: accountID
                    )
                }
                if let endpoint = attempt.endpoint {
                    LastTunnelEndpointStore().save(endpoint, locationId: attempt.locationId)
                }
                return attempt
            }
            if let route = item.route, let resiliencePolicy {
                dynamicRouteEngine.recordFailure(route, policy: resiliencePolicy)
                let connectionEvent = previousRouteTransport == nil ? "connect_failed" : "fallback_failed"
                submitRouteDiagnostics(
                    connectionEvent: connectionEvent,
                    transportFrom: previousRouteTransport,
                    transportTo: routeTransport,
                    status: "error",
                    helperStatus: helper.status,
                    sessionGeneration: sessionGeneration,
                    accessToken: token,
                    accountID: accountID
                )
                previousRouteTransport = routeTransport
            }
            if helper.status.routeOk, helper.status.socketExists, helper.status.latestHandshake == nil, helper.status.rxBytes == 0 {
                lastError = VpnAutopilotRuntimeError.connectFailed("no_handshake: tunnel route is active but peer did not answer")
            } else {
                lastError = VpnAutopilotRuntimeError.connectFailed(helper.message ?? "VPN connection failed.")
            }
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            let teardownConfirmed = await helper.disconnect(releaseAntiLeak: releaseAntiLeakOnFailure)
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            guard teardownConfirmed else {
                throw VpnAutopilotRuntimeError.connectFailed("previous tunnel teardown was not confirmed")
            }
        }
        throw lastError
    }

    private func verifiedHandshake(
        for tunnel: PreparedTunnel,
        helper: VEXHelperModel,
        previousStatus: VpnStatus,
        startedAt: Date,
        generation: Int,
        sessionGeneration: Int? = nil,
        accessToken token: String? = nil,
        accountID: String? = nil
    ) async throws -> Bool {
        let sameExistingTunnel = self.tunnel(tunnel, matches: previousStatus)
        let previousHandshake = previousStatus.latestHandshake ?? 0
        let earliestNewHandshake = UInt64(max(0, Int(startedAt.timeIntervalSince1970) - 2))
        let deadline = Date().addingTimeInterval(8)
        while true {
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            let status = helper.status
            if self.tunnel(tunnel, matches: status), let handshake = status.latestHandshake {
                let recentExistingHandshake = sameExistingTunnel
                    && handshake == previousHandshake
                    && Date().timeIntervalSince1970 - TimeInterval(handshake) < 180
                let newHandshake = handshake >= earliestNewHandshake && handshake > previousHandshake
                if recentExistingHandshake || newHandshake {
                    return true
                }
            }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 400_000_000)
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            await helper.refreshStatus(quiet: true)
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
        }
    }

    private func dynamicRouteTransport(_ candidate: ResilienceConnectionCandidate) -> String {
        switch candidate.pathKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "direct":
            return "awg3_direct"
        case "relay":
            return "awg3_relay"
        default:
            break
        }
        let pathID = candidate.pathId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return pathID.hasPrefix("direct:") ? "awg3_direct" : "awg3_relay"
    }

    private func submitRouteDiagnostics(
        connectionEvent: String,
        transportFrom: String?,
        transportTo: String?,
        status: String,
        helperStatus: VpnStatus?,
        sessionGeneration: Int? = nil,
        accessToken token: String? = nil,
        accountID: String? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            if let sessionGeneration,
                (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) == nil { return }
            await self.submitDiagnostics(
                reason: "dynamic_route",
                status: status,
                helperStatus: helperStatus,
                connectionEvent: connectionEvent,
                transportFrom: transportFrom,
                transportTo: transportTo
            )
        }
    }

    private func clearActiveTunnelRouteState() {
        nativeAdmittedProfiles.clear()
        nativeNormalPendingTunnel = nil
        activeTunnel = nil
        activeResilienceRoute = nil
        activeResiliencePolicy = nil
    }

    func disconnectVPN(using helper: VEXHelperModel, reason: String = "user") async {
        guard !isDeviceBusy else {
            statusMessage = "Дождитесь завершения операции с устройством."
            return
        }
        desiredVpnState = .disconnected
        vpnOperationGeneration += 1
        await performDisconnectVPN(using: helper, reason: reason, generation: vpnOperationGeneration)
    }

    private func performDisconnectVPN(using helper: VEXHelperModel, reason: String, generation: Int) async {
        if helper.status.state == .disconnected, !helper.isBusy {
            clearActiveTunnelRouteState()
            statusMessage = "VPN отключен."
            if desiredVpnState == .connected {
                vpnOperationGeneration += 1
                await performConnectVPN(using: helper, generation: vpnOperationGeneration)
            }
            return
        }
        if isVpnBusy, helper.status.state == .connecting {
            statusMessage = "Отменяем подключение VPN."
            let disconnected = await helper.interruptWithDisconnect(releaseAntiLeak: !antiLeakEnabled)
            isVpnBusy = false
            if disconnected {
                clearActiveTunnelRouteState()
                statusMessage = "VPN отключен."
            } else {
                statusMessage = helper.message ?? "Не удалось подтвердить отключение VPN."
            }
            return
        }
        guard !isVpnBusy, !helper.isBusy else {
            statusMessage = desiredVpnState == .connected ? "Подключим VPN после текущей операции." : "Отключаем VPN."
            return
        }
        isVpnBusy = true
        let disconnected = await helper.disconnect(releaseAntiLeak: !antiLeakEnabled)
        guard disconnected else {
            statusMessage = helper.message ?? "Не удалось подтвердить отключение VPN."
            isVpnBusy = false
            return
        }
        let reportedTunnel = activeTunnel
        clearActiveTunnelRouteState()
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

    private func ensureAuthenticatedSessionCurrent(
        generation: Int,
        accessToken token: String? = nil,
        accountID: String? = nil
    ) throws {
        guard authenticatedSessionGeneration == generation else { throw AuthenticatedOperationError.sessionChanged }
        if let token, session?.accessToken != token { throw AuthenticatedOperationError.sessionChanged }
        if let accountID, session?.user.id != accountID { throw AuthenticatedOperationError.sessionChanged }
    }

    private func ensureConnectStillDesired(
        generation: Int,
        sessionGeneration: Int? = nil,
        accessToken token: String? = nil,
        accountID: String? = nil
    ) throws {
        // Auth invalidation must never enter cancellation/disconnect cleanup.
        if let sessionGeneration {
            try ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)
        }
        guard desiredVpnState == .connected, vpnOperationGeneration == generation else { throw CancellationError() }
    }

    func applySelectedLocationIfConnected(using helper: VEXHelperModel) async {
        guard helper.status.isUsableConnectedStatus else {
            scheduleProfileWarmup()
            return
        }
        _ = await switchConnectedVPNLocation(using: helper)
    }

    private func switchConnectedVPNLocation(using helper: VEXHelperModel) async -> Bool {
        guard !isVpnBusy, !isDeviceBusy, !helper.isBusy else {
            statusMessage = "Дождитесь завершения текущей операции VPN."
            serverSidebarOperation = .failed(statusMessage ?? "VPN занят.")
            return false
        }
        let sessionGeneration = authenticatedSessionGeneration
        let accountID = session?.user.id
        isVpnBusy = true
        defer { isVpnBusy = false }

        let tokenResult = await authenticatedAccessToken()
        guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accountID: accountID)) != nil else { return false }
        guard let token = tokenResult else {
            statusMessage = "Сначала войдите в аккаунт."
            serverSidebarOperation = .failed(statusMessage ?? "Сначала войдите в аккаунт.")
            return false
        }

        guard accessToken == token else { return false }
        let previousTunnel = activeTunnel
        let previousResiliencePolicy = activeResiliencePolicy
        let previousResilienceRoute = activeResilienceRoute
        let previousLocationId = previousTunnel?.locationId ?? selectedLocationId
        guard let nextLocationId = targetLocationId else {
            statusMessage = NativeLocationSelectionError.unavailable.localizedDescription
            serverSidebarOperation = .failed(statusMessage ?? "Сервер недоступен.")
            return false
        }
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
                forceRefresh: false,
                writeHelperConfig: false,
                accountID: accountID,
                validateCurrent: { [weak self] in
                    guard let self else { throw AuthenticatedOperationError.sessionChanged }
                    try self.ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
                }
            )
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            serverSidebarOperation = .connecting
            // The helper admits the complete next profile before replacing the old tunnel.
            let connectedTunnel = try await connectWithAutopilot(
                initialTunnel: nextTunnel,
                accessToken: token,
                helper: helper,
                generation: generation,
                sessionGeneration: sessionGeneration,
                accountID: accountID
            )
            try ensureConnectStillDesired(generation: generation, sessionGeneration: sessionGeneration, accessToken: token, accountID: accountID)
            activeTunnel = connectedTunnel
            serverSidebarOperation = .verifying

            if tunnel(connectedTunnel, matches: helper.status) {
                if let endpoint = connectedTunnel.endpoint {
                    LastTunnelEndpointStore().save(endpoint, locationId: connectedTunnel.locationId)
                }
                statusMessage = "VPN переключен на \(selectedLocation?.displayName ?? connectedTunnel.locationId.uppercased())."
                serverSidebarOperation = .verified(statusMessage ?? "VPN переключен.")
                Task { [weak self, api] in
                    guard let self,
                        (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return }
                    await api.reportVpnDisconnect(accessToken: token, tunnel: previousTunnel, reason: "server_switch")
                    guard (try? self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return }
                    await api.reportVpnConnect(accessToken: token, tunnel: connectedTunnel)
                }
                return true
            }

            throw VpnAutopilotRuntimeError.connectFailed(helper.message ?? "VPN switch failed.")
        } catch AuthenticatedOperationError.sessionChanged {
            return false
        } catch is CancellationError {
            guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return false }
            clearActiveTunnelRouteState()
            statusMessage = "Переключение сервера отменено."
            serverSidebarOperation = .failed(statusMessage ?? "Переключение сервера отменено.")
            return false
        } catch {
            guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return false }
            activeTunnel = previousTunnel
            activeResiliencePolicy = previousResiliencePolicy
            activeResilienceRoute = previousResilienceRoute
            if let previousTunnel, !error.localizedDescription.contains("VPN_CONFIG_INVALID") {
                try? await profileService.writeHelperConfig(for: previousTunnel, validateCurrent: { [weak self] in
                    guard let self else { throw AuthenticatedOperationError.sessionChanged }
                    try self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)
                })
                guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return false }
                await helper.connect(antiLeakEnabled: antiLeakEnabled)
                guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return false }
            } else {
                clearActiveTunnelRouteState()
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
        clearActiveTunnelRouteState()
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
        guard nativeUpdater.isEnabled else {
            statusMessage = "Проверка обновлений временно недоступна."
            return
        }
        // Lazy path: constructs the Sparkle controller on first explicit
        // user action (never during launch drain) and starts the check.
        nativeUpdater.checkForUpdates()
        statusMessage = "Проверяем обновления…"
    }

    func prepareAutomaticUpdatesForStartup() {
        guard !automaticUpdatesPrepared else { return }
        automaticUpdatesPrepared = true
        guard nativeUpdater.isEnabled, nativeUpdater.automaticallyChecksForUpdates else { return }

        // Constructing SPUStandardUpdaterController during app startup triggers
        // a deterministic EXC_BAD_ACCESS in macOS 26's launch-time autorelease
        // drain. Leave the drain first, then make exactly one background check.
        automaticUpdatesStartupTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: automaticUpdatesStartupDelayNanoseconds)
            guard !Task.isCancelled, nativeUpdater.automaticallyChecksForUpdates else { return }
            nativeUpdater.checkForUpdatesInBackground()
        }
    }

    func openSignIn() {
        beginWebAuth(mode: .login)
    }

    func openGoogleSignIn() {
        beginWebAuth(mode: .login, provider: .google)
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

    func setBiometricUnlockRequired(_ required: Bool) {
        biometricUnlockRequired = required
        guard let session else { return }
        do {
            try sessionStore.saveSession(session, requiresBiometricAuthentication: required)
        } catch {
            biometricUnlockRequired.toggle()
            authError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
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
        guard let storedSession = sessionStore.loadSession(
            allowAuthenticationUI: true,
            requiresBiometricAuthentication: biometricUnlockRequired
        ) else {
            authError = "Не удалось загрузить сохраненную сессию."
            statusMessage = authError
            return
        }
        sessionRefreshTask?.task.cancel()
        sessionRefreshTask = nil
        authenticatedSessionGeneration += 1
        session = storedSession
        user = storedSession.user
        startCustomerRealtime(accessToken: storedSession.accessToken)
        statusMessage = "Сохраненная сессия открыта."
        await refreshAll()
    }

    func signOut() {
        resetAuthenticatedState(
            clearsSessionStore: true,
            message: "Вы вышли из аккаунта.",
            authError: nil
        )
    }

    func prepareForTermination() {
        authenticatedSessionGeneration += 1
        invalidateNativePushSession()
        sessionRefreshTask?.task.cancel()
        sessionRefreshTask = nil
        customerRealtimeGeneration += 1
        resetCustomerNotificationSession()
        automaticUpdatesStartupTask?.cancel()
        automaticUpdatesStartupTask = nil
        customerRealtimeService?.stop()
        customerRealtimeService = nil
        customerFallbackTask?.cancel()
        customerFallbackTask = nil
        customerRealtimeConnected = false
        updateMonitorTask?.cancel()
        updateMonitorTask = nil
        profileWarmupTask?.cancel()
        profileWarmupTask = nil
        webAuthTask?.cancel()
        webAuthTask = nil
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
        statusMessage = "Диагностика отправлена."
    }

    func recoverTunnelIfNeeded(using helper: VEXHelperModel) async {
        guard autoRecoveryEnabled, !isDeviceBusy, helper.status.isUsableConnectedStatus, !helper.isBusy else { return }
        let usage: VpnDeviceUsage?
        if let token = accessToken {
            usage = await autopilotService.usage(accessToken: token, deviceId: activeTunnel?.device.id)
        } else {
            usage = nil
        }
        let healthReasons = autopilotService.healthReasons(status: helper.status, usage: usage)
        guard tunnelHealthLooksStale(helper.status) || !healthReasons.isEmpty else { return }
        guard let previousLocationId = activeTunnel?.locationId ?? targetLocationId else {
            statusMessage = NativeLocationSelectionError.unavailable.localizedDescription
            return
        }
        let assessment = autopilotService.assess(healthReasons: healthReasons, status: helper.status)
        if let route = activeResilienceRoute,
           let resiliencePolicy = activeResiliencePolicy,
           runtimeRouteFailureObserved(status: helper.status, healthReasons: healthReasons) {
            dynamicRouteEngine.recordFailure(route, policy: resiliencePolicy)
            submitRouteDiagnostics(
                connectionEvent: "unexpected_disconnect",
                transportFrom: dynamicRouteTransport(route),
                transportTo: nil,
                status: assessment.diagnosticStatus,
                helperStatus: helper.status
            )
        }
        await submitDiagnostics(
            reason: "native_watchdog_stale_tunnel",
            status: assessment.diagnosticStatus,
            helperStatus: helper.status,
            samples: assessment.samples.merging([
                "recovery": "same_exit_route_recovery",
                "previous_location_id": previousLocationId,
                "next_location_id": previousLocationId,
                "alternate_exit_allowed": allowsAutomaticFailover && assessment.canFailover ? "true" : "false",
                "usage_connection_status": usage?.connectionStatus ?? "",
                "usage_seconds_since_handshake": usage?.secondsSinceHandshake.map(String.init) ?? "",
            ]) { current, _ in current }
        )
        statusMessage = assessment.userMessage
        // Keep the current location selected so connectWithAutopilot can try
        // same-exit dynamic candidates (direct -> relay) before it considers an
        // alternate exit. This preserves locality while still allowing the
        // existing autopilot to switch locations if every same-exit path fails.
        await disconnectVPN(using: helper, reason: "watchdog_recovery")
        await connectVPN(using: helper)
    }

    func refreshUpdates() async {
        await loadUpdate(reportErrors: true)
        await loadRemoteConfig()
    }

    func refreshBilling() async {
        guard let token = accessToken else { return }
        await loadBilling(token)
    }

    func createDeviceAddonCheckout() async -> URL? {
        guard !VEXPreviewMode.suppressesRuntime else { return nil }
        if deviceManagementRequiresWeb { return BillingPresentation.billingDashboardURL }
        guard let token = accessToken else { return nil }
        guard !isBillingBusy else { return nil }
        isBillingBusy = true
        billingError = nil
        defer { isBillingBusy = false }

        do {
            let returnURL = BillingPresentation.billingDashboardURL
                .appending(queryItems: [URLQueryItem(name: "payment", value: "device_addon_pending")])
            let failedURL = BillingPresentation.billingDashboardURL
                .appending(queryItems: [URLQueryItem(name: "payment", value: "failed")])
            let checkout = try await api.createDeviceAddonCheckout(
                accessToken: token,
                returnURL: returnURL,
                failedURL: failedURL
            )
            guard let url = URL(string: checkout.url), url.scheme == "https", url.host != nil else {
                throw VEXAPIError.invalidResponse
            }
            return url
        } catch {
            if (error as? VEXAPIError)?.isForbidden == true {
                deviceManagementRequiresWeb = true
                return BillingPresentation.billingDashboardURL
            }
            billingError = error.localizedDescription
            statusMessage = error.localizedDescription
            await submitDiagnostics(reason: "device_addon_checkout_failed", status: "warning", samples: ["error": error.localizedDescription])
            return nil
        }
    }

    func renameDevice(_ device: VpnDevice, name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isDeviceBusy, !VEXPreviewMode.suppressesRuntime else { return }
        isDeviceBusy = true
        defer { isDeviceBusy = false }
        let owner = session?.user.id
        guard let updated = await withSessionRetry(operation: { token in
            try await self.api.renameVpnDevice(accessToken: token, deviceId: device.id, name: trimmedName)
        }), session?.user.id == owner else { return }
        accountDevices = accountDevices.map { $0.id == updated.id ? updated : $0 }
    }

    func canRemoveDevice(_ device: VpnDevice, using helper: VEXHelperModel) -> Bool {
        DeviceRemovalSafety.permitsRemoval(
            confirmedIdle: helper.hasConfirmedIdleStatus && !helper.status.hasManagedNetworkState,
            helperBusy: helper.isBusy,
            vpnBusy: isVpnBusy,
            activeDeviceID: activeTunnel?.device.id,
            requestedDeviceID: device.id
        )
    }

    func removeDevice(_ device: VpnDevice, using helper: VEXHelperModel) async {
        guard !isDeviceBusy, !VEXPreviewMode.suppressesRuntime else { return }
        isDeviceBusy = true
        defer { isDeviceBusy = false }
        // Read-only confirmation prevents a stale alert from revoking a device
        // after a connection started or profile restoration could not identify it.
        await helper.refreshStatus(quiet: true)
        guard canRemoveDevice(device, using: helper) else {
            statusMessage = "Удаление недоступно, пока VPN активен или его состояние не подтверждено. Подключение сохранено."
            return
        }
        let owner = session?.user.id
        guard await withSessionRetry(operation: { token in
            try await self.api.deleteVpnDevice(accessToken: token, deviceId: device.id)
            return true
        }) == true, session?.user.id == owner else { return }
        accountDevices.removeAll { $0.id == device.id }
        await refreshBilling()
    }

    private func loadUser(_ token: String) async {
        guard session?.accessToken == token else { return }
        let operationGeneration = authenticatedSessionGeneration
        await withSessionRetry(operation: { currentToken in
            let loadedUser = try await self.api.me(accessToken: currentToken)
            guard self.authenticatedSessionGeneration == operationGeneration,
                self.session?.accessToken == currentToken else { return () }
            self.user = loadedUser
            return ()
        })
    }

    private func refreshLocations(accessToken token: String) async {
        guard !isLoadingLocations, session?.accessToken == token else { return }
        let operationGeneration = authenticatedSessionGeneration
        isLoadingLocations = true
        locationLoadError = nil
        defer { isLoadingLocations = false }

        do {
            let loadedLocations = try await api.vpnLocations(accessToken: token)
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token else { return }
            locations = loadedLocations
            lastLocationsRefreshAt = Date()
            if selectedLocation == nil, serverSelectionMode != "manual", let first = locations.first {
                selectedLocationId = first.id
            }
        } catch {
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token else { return }
            locationLoadError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func loadBilling(_ token: String) async {
        guard session?.accessToken == token else { return }
        let operationGeneration = authenticatedSessionGeneration
        let billingUserId = user?.id ?? session?.user.id ?? ""
        let cachedSummary = billingSummaryCache.load(userId: billingUserId)
        if billingSummary == nil, let cachedSummary {
            billingSummary = cachedSummary
        }

        // Requests start concurrently; payments are awaited separately
        // so a payments failure never masks the summary/entitlement result.
        async let plansResult = api.billingPlans()
        async let entitlementResult = api.entitlement(accessToken: token)
        async let paymentsResult = api.billingPayments(accessToken: token, limit: 24)
        async let addonsResult = api.billingDeviceAddons(accessToken: token)
        async let devicesResult = api.vpnDevices(accessToken: token)

        do {
            let (plans, currentEntitlement) = try await (plansResult, entitlementResult)
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            entitlement = currentEntitlement
            billingSummary = billingService.buildSummary(plans: plans, entitlement: currentEntitlement)
            if let billingSummary {
                billingSummaryCache.save(userId: billingUserId, summary: billingSummary)
            }
            billingError = nil
        } catch {
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            let fallback = cachedSummary ?? billingService.buildSummary(plans: [], entitlement: entitlement)
            billingSummary = fallback
            billingError = error.localizedDescription
            statusMessage = error.localizedDescription
            await submitDiagnostics(reason: "billing_summary_failed", status: "error", samples: ["error": error.localizedDescription])
        }

        do {
            let loaded = try await paymentsResult
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            billingPayments = loaded
        } catch {
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            billingPayments = []
            if billingError == nil {
                billingError = error.localizedDescription
            }
            await submitDiagnostics(reason: "billing_payments_failed", status: "warning", samples: ["error": error.localizedDescription])
        }

        do {
            let loaded = try await addonsResult
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            deviceAddons = loaded
            deviceManagementRequiresWeb = false
        } catch {
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            deviceAddons = []
            if (error as? VEXAPIError)?.isForbidden == true {
                deviceManagementRequiresWeb = true
            } else {
                await submitDiagnostics(reason: "device_addons_failed", status: "warning", samples: ["error": error.localizedDescription])
            }
        }

        do {
            let loaded = try await devicesResult
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            accountDevices = loaded
        } catch {
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token, session?.user.id == billingUserId else { return }
            accountDevices = []
            await submitDiagnostics(reason: "account_devices_failed", status: "warning", samples: ["error": error.localizedDescription])
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

    /// Shared 401-retry pipeline: runs `operation`, and on an unauthorized
    /// error refreshes the session once and retries with the new token. A
    /// second unauthorized failure expires the session; any other failure is
    /// surfaced through `statusMessage` unless `showsErrors` is false.
    private func withSessionRetry<T>(
        showsErrors: Bool = true,
        operation: (String) async throws -> T
    ) async -> T? {
        let operationGeneration = authenticatedSessionGeneration
        let accountID = session?.user.id
        guard let token = await authenticatedAccessToken(),
            authenticatedSessionGeneration == operationGeneration,
            session?.user.id == accountID, session?.accessToken == token else { return nil }
        do {
            let result = try await operation(token)
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token else { return nil }
            return result
        } catch {
            // A late old-token error is inert: never refresh, retry, report, or
            // expire the replacement session (including same-account re-login).
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token else { return nil }
            guard error.isUnauthorizedAPIError else {
                if showsErrors { statusMessage = error.localizedDescription }
                return nil
            }
            guard let refreshedToken = await refreshSessionForRetry(),
                authenticatedSessionGeneration == operationGeneration,
                session?.user.id == accountID,
                session?.accessToken == refreshedToken else { return nil }
            do {
                let result = try await operation(refreshedToken)
                guard authenticatedSessionGeneration == operationGeneration,
                    session?.accessToken == refreshedToken else { return nil }
                return result
            } catch {
                guard authenticatedSessionGeneration == operationGeneration,
                    session?.accessToken == refreshedToken else { return nil }
                if error.isUnauthorizedAPIError {
                    expireAuthenticatedSession(message: "Сессия истекла. Войдите снова.")
                } else if showsErrors {
                    statusMessage = error.localizedDescription
                }
                return nil
            }
        }
    }

    private func ensureEntitlementForConnect(accessToken token: String) async -> String? {
        guard session?.accessToken == token else { return nil }
        let operationGeneration = authenticatedSessionGeneration
        if entitlement?.hasPaidAccess == true {
            return token
        }
        // On success this returns the token even when access is not paid;
        // the paid-access gate lives in the connect flow itself.
        return await withSessionRetry(operation: { refreshedToken in
            let entitlement = try await self.api.entitlement(accessToken: refreshedToken)
            guard self.authenticatedSessionGeneration == operationGeneration,
                self.session?.accessToken == refreshedToken else {
                throw AuthenticatedOperationError.sessionChanged
            }
            self.entitlement = entitlement
            return refreshedToken
        })
    }

    private func loadUpdate(reportErrors: Bool = false) async {
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
        // Support chat was removed from macOS; kept no-op for preview hooks.
    }
    #endif

    private func beginWebAuth(mode: WebAuthMode, provider: WebAuthProvider? = nil) {
        guard !isAuthBusy, !isWaitingForWebAuth else { return }
        authError = nil
        isWaitingForWebAuth = true
        statusMessage = mode == .register ? "Ожидаем завершение регистрации на сайте." : "Ожидаем подтверждение входа на сайте."
        webAuthTask?.cancel()
        webAuthTask = Task { [weak self] in
            guard let self else { return }
            do {
                let callbackURL = try await authService.startWebAuth(mode: mode, provider: provider)
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
        try sessionStore.saveSession(nextSession, requiresBiometricAuthentication: biometricUnlockRequired)
        sessionRefreshTask?.task.cancel()
        sessionRefreshTask = nil
        authenticatedSessionGeneration += 1
        session = nextSession
        user = nextSession.user
        startCustomerRealtime(accessToken: nextSession.accessToken)
        canUnlockStoredSession = true
        authError = nil
        statusMessage = message
        await refreshAll()
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
        let operationGeneration = authenticatedSessionGeneration
        if let sessionRefreshTask {
            let result = await sessionRefreshTask.task.value
            guard authenticatedSessionGeneration == operationGeneration else { return nil }
            return await applySessionRefreshResult(result, refreshAccessToken: sessionRefreshTask.accessToken)
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
        guard authenticatedSessionGeneration == operationGeneration else { return nil }
        if sessionRefreshTask?.accessToken == refreshAccessToken {
            sessionRefreshTask = nil
        }
        return await applySessionRefreshResult(result, refreshAccessToken: refreshAccessToken)
    }

    private func applySessionRefreshResult(_ result: Result<AuthSession, Error>, refreshAccessToken: String) async -> String? {
        // A refresh can finish after sign-out or another account signs in. Never
        // restore the old session (or its notifications) across that boundary.
        guard session?.accessToken == refreshAccessToken else { return session?.accessToken }
        do {
            let nextSession = try result.get()
            try sessionStore.saveSession(nextSession, requiresBiometricAuthentication: biometricUnlockRequired)
            session = nextSession
            user = nextSession.user
            startCustomerRealtime(accessToken: nextSession.accessToken)
            authError = nil
            statusMessage = "Сессия обновлена."
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
        let operationGeneration = authenticatedSessionGeneration
        let accountID = session?.user.id
        guard session?.accessToken == token else { throw AuthenticatedOperationError.sessionChanged }
        do {
            let tunnel = try await profileService.resolveProfile(
                accessToken: token,
                locationId: locationId,
                routingMode: routingMode,
                forceRefresh: forceRefresh,
                writeHelperConfig: false,
                prevalidatedEntitlement: prevalidatedEntitlement,
                accountID: accountID,
                validateCurrent: { [weak self] in
                    guard let self else { throw AuthenticatedOperationError.sessionChanged }
                    try self.ensureAuthenticatedSessionCurrent(generation: operationGeneration, accessToken: token, accountID: accountID)
                }
            )
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token,
                session?.user.id == accountID else { throw AuthenticatedOperationError.sessionChanged }
            return (tunnel, token)
        } catch {
            guard authenticatedSessionGeneration == operationGeneration,
                session?.accessToken == token,
                session?.user.id == accountID else { throw AuthenticatedOperationError.sessionChanged }
            guard error.isUnauthorizedAPIError else { throw error }
            let refreshResult = await refreshSessionForRetry()
            guard authenticatedSessionGeneration == operationGeneration,
                session?.user.id == accountID else { throw AuthenticatedOperationError.sessionChanged }
            guard let refreshedToken = refreshResult else { throw error }
            guard session?.accessToken == refreshedToken else { throw AuthenticatedOperationError.sessionChanged }
            do {
                let tunnel = try await profileService.resolveProfile(
                    accessToken: refreshedToken,
                    locationId: locationId,
                    routingMode: routingMode,
                    forceRefresh: true,
                    writeHelperConfig: false,
                    accountID: accountID,
                    validateCurrent: { [weak self] in
                        guard let self else { throw AuthenticatedOperationError.sessionChanged }
                        try self.ensureAuthenticatedSessionCurrent(generation: operationGeneration, accessToken: refreshedToken, accountID: accountID)
                    }
                )
                guard authenticatedSessionGeneration == operationGeneration,
                    session?.accessToken == refreshedToken,
                    session?.user.id == accountID else { throw AuthenticatedOperationError.sessionChanged }
                return (tunnel, refreshedToken)
            } catch {
                guard authenticatedSessionGeneration == operationGeneration,
                    session?.accessToken == refreshedToken,
                    session?.user.id == accountID else { throw AuthenticatedOperationError.sessionChanged }
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
        resetAuthenticatedState(
            clearsSessionStore: true,
            message: message,
            authError: message
        )
    }

    /// Single source of truth for tearing down authenticated state. Both
    /// explicit sign-out and session expiry must reset the same fields;
    /// divergence here previously leaked `billingPayments` on sign-out.
    private func resetAuthenticatedState(
        clearsSessionStore: Bool,
        message: String,
        authError: String?
    ) {
        // Invalidate storage only; current helper/VPN/PF state is not touched.
        // The service blocks reuse even when owner-scoped deletion fails.
        try? profileService.invalidateNormalCache(accountID: session?.user.id)
        authenticatedSessionGeneration += 1
        invalidateNativePushSession(resetConsent: true)
        sessionRefreshTask?.task.cancel()
        sessionRefreshTask = nil
        profileWarmupTask?.cancel()
        profileWarmupTask = nil
        customerRealtimeGeneration += 1
        resetCustomerNotificationSession()
        customerRealtimeService?.stop()
        customerRealtimeService = nil
        customerFallbackTask?.cancel()
        customerFallbackTask = nil
        customerRealtimeConnected = false
        if clearsSessionStore {
            try? sessionStore.clearSession()
        }
        session = nil
        user = nil
        clearActiveTunnelRouteState()
        entitlement = nil
        billingSummary = nil
        billingPayments = []
        deviceAddons = []
        accountDevices = []
        deviceManagementRequiresWeb = false
        self.authError = authError
        billingError = nil
        canUnlockStoredSession =
            clearsSessionStore == false
            ? canUnlockStoredSession
            : sessionStore.hasStoredNativeSession()
        statusMessage = message
    }

    private func startCustomerRealtime(accessToken: String) {
        customerRealtimeGeneration += 1
        let streamGeneration = customerRealtimeGeneration
        let accountID = session?.user.id
        if customerNotificationSessionID != accountID {
            resetCustomerNotificationSession()
            customerNotificationSessionID = accountID
        }
        let service = CustomerRealtimeService(
            baseURL: api.baseURL,
            onStatus: { [weak self] connected in
                guard self?.customerRealtimeGeneration == streamGeneration else { return }
                self?.customerRealtimeConnected = connected
            },
            onSessionRejected: { [weak self] in
                guard let self, self.customerRealtimeGeneration == streamGeneration,
                    self.accessToken == accessToken else { return }
                // Invalidate callers queued before rejection, not only delivery
                // already awaiting notification-center IPC. Preserve recent IDs
                // if the refreshed session still belongs to the same account.
                self.customerRealtimeGeneration += 1
                self.customerRealtimeConnected = false
                self.customerNotifications.resetSession()
                _ = await self.refreshSessionForRetry()
            },
            onEvent: { [weak self] event, metadata in
                guard let self, self.customerRealtimeGeneration == streamGeneration,
                    self.accessToken == accessToken else { return }
                if event.type == "customer.session.revoked" {
                    self.customerRealtimeGeneration += 1
                    self.customerRealtimeConnected = false
                    self.customerRealtimeService?.stop()
                    self.resetCustomerNotificationSession()
                    _ = await self.refreshSessionForRetry()
                    return
                }
                guard event.type == "customer.change" || event.type == "customer.resync" else { return }
                if self.customerNotificationSessionID?.isEmpty == false {
                    let payloads = self.customerNotificationPolicy.consume(event: event, metadata: metadata)
                    // Permission-center IPC must not hold up entitlement/account
                    // refresh. Both the stream and delivery service recheck their
                    // generations so queued work cannot cross a session boundary.
                    Task { [weak self] in
                        guard let self, self.customerRealtimeGeneration == streamGeneration,
                            self.accessToken == accessToken else { return }
                        await self.customerNotifications.deliver(payloads)
                    }
                }
                // Refresh account, billing, locations and derived profile inputs.
                // This never changes the desired tunnel state or restarts the tunnel.
                await self.refreshCustomerState()
            }
        )
        customerRealtimeService?.stop()
        customerFallbackTask?.cancel()
        customerRealtimeConnected = false
        customerRealtimeService = service
        service.start(accessToken: accessToken)
        customerFallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.customerFallbackIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                if !self.customerRealtimeConnected {
                    await self.refreshCustomerState()
                }
            }
        }
    }

    private func resetCustomerNotificationSession() {
        customerNotificationPolicy.reset()
        customerNotificationSessionID = nil
        customerNotifications.resetSession()
    }

    private func refreshCustomerState() async {
        if customerRefreshInFlight {
            customerRefreshPending = true
            return
        }
        customerRefreshInFlight = true
        defer { customerRefreshInFlight = false }
        repeat {
            customerRefreshPending = false
            await refreshAll()
        } while customerRefreshPending
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

    private var targetLocationId: String? {
        VpnLocationSelection.targetID(
            locations: locations,
            selectedID: selectedLocationId,
            automatic: autoServerEnabled
        )
    }

    private var allowsAutomaticFailover: Bool {
        autoServerEnabled && serverSelectionMode == "auto"
    }

    private func prepareSelectedProfile(forceRefresh: Bool) async {
        guard let token = accessToken, let targetLocationId else { return }
        let sessionGeneration = authenticatedSessionGeneration
        let accountID = session?.user.id
        do {
            let prepared = try await profileService.resolveProfile(
                accessToken: token,
                locationId: targetLocationId,
                routingMode: routingMode,
                forceRefresh: forceRefresh,
                writeHelperConfig: false,
                accountID: accountID,
                validateCurrent: { [weak self] in
                    guard let self else { throw AuthenticatedOperationError.sessionChanged }
                    try self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)
                }
            )
            guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return }
            activeTunnel = prepared
            statusMessage = "Профиль сервера готов."
        } catch {
            guard (try? ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)) != nil else { return }
            statusMessage = error.localizedDescription
        }
    }

    private func restoreActiveTunnelIfHelperIsConnected(_ helperStatus: VpnStatus?) async {
        guard let helperStatus, helperStatus.isUsableConnectedStatus, activeTunnel == nil else { return }
        await prepareSelectedProfile(forceRefresh: false)
        if let activeTunnel, tunnel(activeTunnel, matches: helperStatus) {
            statusMessage = "VPN подключен через \(selectedLocation?.displayName ?? activeTunnel.locationId.uppercased())."
        } else {
            clearActiveTunnelRouteState()
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
        guard status.isUsableConnectedStatus, let targetLocationId else { return false }
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
        profileWarmupTask?.cancel()
        guard let token = accessToken, let locationId = targetLocationId else { return }
        let mode = routingMode
        let sessionGeneration = authenticatedSessionGeneration
        let accountID = session?.user.id
        profileWarmupTask = Task { [weak self, profileService] in
            do {
                try Task.checkCancellation()
                guard let self else { return }
                try self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)
                // Warmup fills the cache only when it is missing, stale or for a
                // different location/mode; a fresh cached profile resolves with
                // zero network round-trips. A late result stays in its captured
                // account/installation namespace, never in a replacement session.
                let prepared = try await profileService.resolveProfile(
                    accessToken: token,
                    locationId: locationId,
                    routingMode: mode,
                    forceRefresh: false,
                    writeHelperConfig: false,
                    accountID: accountID,
                    validateCurrent: { [weak self] in
                        guard let self else { throw AuthenticatedOperationError.sessionChanged }
                        try self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)
                    }
                )
                try self.ensureAuthenticatedSessionCurrent(generation: sessionGeneration, accessToken: token, accountID: accountID)
                if let accountID {
                    self.bindNativePushDevice(prepared.device.id, accountID: accountID, generation: sessionGeneration)
                }
            } catch is CancellationError {
            } catch {
                // Background warmup is best-effort; foreground connect handles user-visible errors.
            }
        }
    }

    private func submitDiagnostics(
        reason: String,
        status: String,
        helperStatus: VpnStatus? = nil,
        connectionEvent: String? = nil,
        transportFrom: String? = nil,
        transportTo: String? = nil,
        samples: [String: String] = [:]
    ) async {
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
                "selected_location_id": targetLocationId ?? selectedLocationId,
                "routing_mode": routingMode.rawValue,
                "app": "native-macos",
            ]) { current, _ in current },
            connectionEvent: connectionEvent,
            transportFrom: transportFrom,
            transportTo: transportTo
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

    private func runtimeRouteFailureObserved(status: VpnStatus, healthReasons: [NativeTunnelHealthReason]) -> Bool {
        tunnelHealthLooksStale(status)
            || healthReasons.contains(.deviceUsageDegraded)
            || healthReasons.contains(.staleLocalHandshake)
    }

    private func bestFailoverLocation(excluding activeLocationId: String) -> VpnLocation? {
        VpnLocationSelection.fallback(locations: locations, excluding: activeLocationId)
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
