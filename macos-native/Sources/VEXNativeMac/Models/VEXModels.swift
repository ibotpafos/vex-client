import Foundation

struct AuthSession: Codable, Equatable {
    var user: VEXUser
    var accessToken: String
    var expiresAt: String?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case user
        case accessToken
        case expiresAt
        case refreshToken
    }

    var shouldRefreshSoon: Bool {
        guard let expiresAt,
              let expiryDate = Date.vexISO8601Date(from: expiresAt) else {
            return false
        }
        return expiryDate <= Date().addingTimeInterval(300)
    }
}

private extension Date {
    static func vexISO8601Date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct VEXUser: Codable, Equatable {
    var id: String
    var email: String
    var status: String
}

struct VpnLocation: Codable, Equatable, Identifiable {
    var id: String
    var countryCode: String
    var city: String
    var flagEmoji: String?
    var availability: String
    var status: String
    var healthyNodes: Int
    var awg3Nodes: Int?
    var latencyMs: Double?

    var displayName: String {
        if city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return id.uppercased()
        }
        return "\(flagEmoji ?? "") \(localizedName)".trimmingCharacters(in: .whitespaces)
    }

    var localizedName: String {
        switch countryCode.uppercased() {
        case "DE": return "Германия"
        case "FI": return "Финляндия"
        case "NL": return "Нидерланды"
        case "US": return "США"
        default: return city
        }
    }

    /// Russian status text shared by the home cards and the server sidebar.
    var localizedStatus: String {
        switch status.lowercased() {
        case "active", "online", "healthy":
            return "доступен"
        case "maintenance":
            return "обслуживание"
        default:
            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "статус уточняется" : trimmed
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case countryCode = "country_code"
        case city
        case flagEmoji = "flag_emoji"
        case availability
        case status
        case healthyNodes = "healthy_nodes"
        case awg3Nodes = "awg3_nodes"
        case latencyMs = "latency_ms"
    }
}

struct AppUpdateCheckResult: Codable, Equatable {
    var updateAvailable: Bool
    var required: Bool
    var currentBuildBlocked: Bool?
    var latestVersion: String
    var latestBuild: Int
    var minSupportedBuild: Int
    var minConfigSchemaVersion: Int?
    var downloadUrl: String
    var changelog: String?
    var checksumSha256: String?
    var signatureUrl: String?
    var channel: String?
    var reason: String?
    var rolloutPercent: Int?
    var checkedAt: String?

    enum CodingKeys: String, CodingKey {
        case updateAvailable
        case required
        case currentBuildBlocked
        case latestVersion
        case latestBuild
        case minSupportedBuild
        case minConfigSchemaVersion
        case downloadUrl
        case changelog
        case checksumSha256
        case signatureUrl
        case channel
        case reason
        case rolloutPercent
        case checkedAt
    }

    init(
        updateAvailable: Bool,
        required: Bool,
        currentBuildBlocked: Bool?,
        latestVersion: String,
        latestBuild: Int,
        minSupportedBuild: Int,
        minConfigSchemaVersion: Int?,
        downloadUrl: String,
        changelog: String?,
        checksumSha256: String?,
        signatureUrl: String?,
        channel: String?,
        reason: String?,
        rolloutPercent: Int?,
        checkedAt: String?
    ) {
        self.updateAvailable = updateAvailable
        self.required = required
        self.currentBuildBlocked = currentBuildBlocked
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.minSupportedBuild = minSupportedBuild
        self.minConfigSchemaVersion = minConfigSchemaVersion
        self.downloadUrl = downloadUrl
        self.changelog = changelog
        self.checksumSha256 = checksumSha256
        self.signatureUrl = signatureUrl
        self.channel = channel
        self.reason = reason
        self.rolloutPercent = rolloutPercent
        self.checkedAt = checkedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updateAvailable = try container.decode(Bool.self, forKey: .updateAvailable)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        currentBuildBlocked = try container.decodeIfPresent(Bool.self, forKey: .currentBuildBlocked)
        minConfigSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .minConfigSchemaVersion)
        changelog = try container.decodeIfPresent(String.self, forKey: .changelog)
        checksumSha256 = try container.decodeIfPresent(String.self, forKey: .checksumSha256)
        signatureUrl = try container.decodeIfPresent(String.self, forKey: .signatureUrl)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        rolloutPercent = try container.decodeIfPresent(Int.self, forKey: .rolloutPercent)
        checkedAt = try container.decodeIfPresent(String.self, forKey: .checkedAt)

        guard updateAvailable else {
            latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
                ?? VEXAppInfo.version
            latestBuild = try container.decodeIfPresent(Int.self, forKey: .latestBuild)
                ?? VEXAppInfo.buildNumber
            minSupportedBuild = try container.decodeIfPresent(Int.self, forKey: .minSupportedBuild) ?? 0
            downloadUrl = try container.decodeIfPresent(String.self, forKey: .downloadUrl) ?? ""
            return
        }

        // An advertised update must remain fail-closed: without exact version,
        // build and delivery metadata the UI must not offer an unusable update.
        latestVersion = try container.decode(String.self, forKey: .latestVersion)
        latestBuild = try container.decode(Int.self, forKey: .latestBuild)
        minSupportedBuild = try container.decodeIfPresent(Int.self, forKey: .minSupportedBuild) ?? 0
        downloadUrl = try container.decode(String.self, forKey: .downloadUrl)
    }

    func isNewerThanInstalledApp(currentVersion: String = VEXAppInfo.version) -> Bool {
        guard updateAvailable else { return false }
        let versionOrder = Self.compareVersion(latestVersion, currentVersion)
        if versionOrder == .orderedDescending {
            return true
        }
        if versionOrder == .orderedAscending {
            return false
        }

        // Same public version should not keep the sidebar in an update-ready state.
        // Sparkle can still manage same-version build updates from its own window.
        return false
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = versionParts(lhs)
        let rhsParts = versionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func versionParts(_ value: String) -> [Int] {
        value
            .split { !$0.isNumber }
            .map { Int($0) ?? 0 }
    }
}

struct VpnDevice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var status: String
    var assignedIpv4: String?
    var nodeId: String?
    var `protocol`: String?
    var protocolLabel: String?
    var endpoint: String?
    var latencyMs: Double?
    var publicKey: String?
    var provisioningMode: String?
    var clientKeyOwnership: String?
    var externalDeviceId: String?
    var platform: String?
    var appVersion: String?
    var pushProvider: String?
    var hasPushToken: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case assignedIpv4 = "assigned_ipv4"
        case nodeId = "node_id"
        case `protocol`
        case protocolLabel = "protocol_label"
        case endpoint
        case latencyMs = "latency_ms"
        case publicKey = "public_key"
        case provisioningMode = "provisioning_mode"
        case clientKeyOwnership = "client_key_ownership"
        case externalDeviceId = "external_device_id"
        case platform
        case appVersion = "app_version"
        case pushProvider = "push_provider"
        case hasPushToken = "has_push_token"
    }

    enum DecodeOnlyKeys: String, CodingKey {
        case pushToken = "push_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodeOnly = try decoder.container(keyedBy: DecodeOnlyKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
        assignedIpv4 = try? container.decodeIfPresent(String.self, forKey: .assignedIpv4)
        nodeId = try? container.decodeIfPresent(String.self, forKey: .nodeId)
        `protocol` = try? container.decodeIfPresent(String.self, forKey: .protocol)
        protocolLabel = try? container.decodeIfPresent(String.self, forKey: .protocolLabel)
        endpoint = try? container.decodeIfPresent(String.self, forKey: .endpoint)
        latencyMs = try? container.decodeIfPresent(Double.self, forKey: .latencyMs)
        publicKey = try? container.decodeIfPresent(String.self, forKey: .publicKey)
        provisioningMode = try? container.decodeIfPresent(String.self, forKey: .provisioningMode)
        clientKeyOwnership = try? container.decodeIfPresent(String.self, forKey: .clientKeyOwnership)
        externalDeviceId = try? container.decodeIfPresent(String.self, forKey: .externalDeviceId)
        platform = try? container.decodeIfPresent(String.self, forKey: .platform)
        appVersion = try? container.decodeIfPresent(String.self, forKey: .appVersion)
        pushProvider = try? container.decodeIfPresent(String.self, forKey: .pushProvider)
        let hasPush = (try? container.decodeIfPresent(Bool.self, forKey: .hasPushToken)) ?? false
        let token = try? decodeOnly.decodeIfPresent(String.self, forKey: .pushToken)
        hasPushToken = hasPush || !(token ?? "").isEmpty
    }
}

struct VpnDeviceUsage: Codable, Equatable {
    var deviceId: String
    var connectionStatus: String?
    var connected: Bool?
    var secondsSinceHandshake: Int?
    var rxBytes: Int64?
    var txBytes: Int64?
    var totalBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case connectionStatus = "connection_status"
        case connected
        case secondsSinceHandshake = "seconds_since_handshake"
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case totalBytes = "total_bytes"
    }
}

struct VpnDeviceUsageResponse: Codable, Equatable {
    var usage: [VpnDeviceUsage]?
}

struct ResiliencePolicy: Codable, Equatable {
    var policyVersion: String
    var generatedAt: String
    var expiresAt: String
    var signature: ResiliencePolicySignature
    var probe: ResilienceProbePolicy
    var candidates: [ResilienceConnectionCandidate]

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case generatedAt = "generated_at"
        case expiresAt = "expires_at"
        case signature
        case probe
        case candidates
    }
}

struct ResiliencePolicySignature: Codable, Equatable {
    var status: String
    var alg: String?
    var keyId: String?
    var value: String?
    var signedAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case alg
        case keyId = "key_id"
        case value
        case signedAt = "signed_at"
    }
}

struct ResilienceProbePolicy: Codable, Equatable {
    var connectTimeoutMs: Int
    var maxCandidates: Int
    var failureThreshold: Int?
    var recoveryThreshold: Int?
    var quarantineMs: Int?
    var failbackHoldMs: Int?
    var checks: [String]

    enum CodingKeys: String, CodingKey {
        case connectTimeoutMs = "connect_timeout_ms"
        case maxCandidates = "max_candidates"
        case failureThreshold = "failure_threshold"
        case recoveryThreshold = "recovery_threshold"
        case quarantineMs = "quarantine_ms"
        case failbackHoldMs = "failback_hold_ms"
        case checks
    }
}

struct ResilienceConnectionCandidate: Codable, Equatable, Identifiable {
    var id: String
    var pathId: String?
    var pathKind: String?
    var entryNodeId: String?
    var failureDomain: String?
    var priority: Int?
    var deviceId: String
    var protocolName: String
    var locationId: String
    var nodeId: String
    var endpoint: String
    var healthScore: Int
    var expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case pathId = "path_id"
        case pathKind = "path_kind"
        case entryNodeId = "entry_node_id"
        case failureDomain = "failure_domain"
        case priority
        case deviceId = "device_id"
        case protocolName = "protocol"
        case locationId = "location_id"
        case nodeId = "node_id"
        case endpoint
        case healthScore = "health_score"
        case expiresAt = "expires_at"
    }
}

struct DeviceIdentityChallenge: Codable, Equatable {
    var id: String
    var nonce: String
    var purpose: String
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case nonce
        case purpose
        case expiresAt = "expires_at"
    }
}

struct Entitlement: Codable, Equatable {
    var active = false
    var planId: String?
    var displayName: String?
    var accountStatus: String?
    var subscriptionTitle: String?
    var subscriptionSubtitle: String?
    var remainingText: String?
    var status: String?
    var tier: String?
    var currentPeriodEnd: String?
    var effectiveExpiresAt: String?
    var deviceLimit = 0
    var baseDeviceLimit: Int?
    var addonDeviceSlots: Int?
    var maxDeviceLimit: Int?
    var canBuyDeviceAddon = false
    var deviceAddonPriceMinor: Int?
    var deviceAddonCurrency: String?
    var activeDevices = 0
    var canCreateDevice = false
    var vpnAccess = false

    enum CodingKeys: String, CodingKey {
        case active
        case planId = "plan_id"
        case displayName = "display_name"
        case accountStatus = "account_status"
        case subscriptionTitle = "subscription_title"
        case subscriptionSubtitle = "subscription_subtitle"
        case remainingText = "remaining_text"
        case status
        case tier
        case currentPeriodEnd = "current_period_end"
        case effectiveExpiresAt = "effective_expires_at"
        case deviceLimit = "device_limit"
        case baseDeviceLimit = "base_device_limit"
        case addonDeviceSlots = "addon_device_slots"
        case maxDeviceLimit = "max_device_limit"
        case canBuyDeviceAddon = "can_buy_device_addon"
        case deviceAddonPriceMinor = "device_addon_price_minor"
        case deviceAddonCurrency = "device_addon_currency"
        case activeDevices = "active_devices"
        case canCreateDevice = "can_create_device"
        case vpnAccess = "vpn_access"
    }

    init(
        active: Bool = false,
        planId: String? = nil,
        displayName: String? = nil,
        accountStatus: String? = nil,
        subscriptionTitle: String? = nil,
        subscriptionSubtitle: String? = nil,
        remainingText: String? = nil,
        status: String? = nil,
        tier: String? = nil,
        currentPeriodEnd: String? = nil,
        effectiveExpiresAt: String? = nil,
        deviceLimit: Int = 0,
        baseDeviceLimit: Int? = nil,
        addonDeviceSlots: Int? = nil,
        maxDeviceLimit: Int? = nil,
        canBuyDeviceAddon: Bool = false,
        deviceAddonPriceMinor: Int? = nil,
        deviceAddonCurrency: String? = nil,
        activeDevices: Int = 0,
        canCreateDevice: Bool = false,
        vpnAccess: Bool = false
    ) {
        self.active = active
        self.planId = planId
        self.displayName = displayName
        self.accountStatus = accountStatus
        self.subscriptionTitle = subscriptionTitle
        self.subscriptionSubtitle = subscriptionSubtitle
        self.remainingText = remainingText
        self.status = status
        self.tier = tier
        self.currentPeriodEnd = currentPeriodEnd
        self.effectiveExpiresAt = effectiveExpiresAt
        self.deviceLimit = deviceLimit
        self.baseDeviceLimit = baseDeviceLimit
        self.addonDeviceSlots = addonDeviceSlots
        self.maxDeviceLimit = maxDeviceLimit
        self.canBuyDeviceAddon = canBuyDeviceAddon
        self.deviceAddonPriceMinor = deviceAddonPriceMinor
        self.deviceAddonCurrency = deviceAddonCurrency
        self.activeDevices = activeDevices
        self.canCreateDevice = canCreateDevice
        self.vpnAccess = vpnAccess
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        planId = try container.decodeIfPresent(String.self, forKey: .planId)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        accountStatus = try container.decodeIfPresent(String.self, forKey: .accountStatus)
        subscriptionTitle = try container.decodeIfPresent(String.self, forKey: .subscriptionTitle)
        subscriptionSubtitle = try container.decodeIfPresent(String.self, forKey: .subscriptionSubtitle)
        remainingText = try container.decodeIfPresent(String.self, forKey: .remainingText)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        currentPeriodEnd = try container.decodeIfPresent(String.self, forKey: .currentPeriodEnd)
        effectiveExpiresAt = try container.decodeIfPresent(String.self, forKey: .effectiveExpiresAt)
        deviceLimit = try container.decodeIfPresent(Int.self, forKey: .deviceLimit) ?? 0
        baseDeviceLimit = try container.decodeIfPresent(Int.self, forKey: .baseDeviceLimit)
        addonDeviceSlots = try container.decodeIfPresent(Int.self, forKey: .addonDeviceSlots)
        maxDeviceLimit = try container.decodeIfPresent(Int.self, forKey: .maxDeviceLimit)
        canBuyDeviceAddon = try container.decodeIfPresent(Bool.self, forKey: .canBuyDeviceAddon) ?? false
        deviceAddonPriceMinor = try container.decodeIfPresent(Int.self, forKey: .deviceAddonPriceMinor)
        deviceAddonCurrency = try container.decodeIfPresent(String.self, forKey: .deviceAddonCurrency)
        activeDevices = try container.decodeIfPresent(Int.self, forKey: .activeDevices) ?? 0
        canCreateDevice = try container.decodeIfPresent(Bool.self, forKey: .canCreateDevice) ?? false
        vpnAccess = try container.decodeIfPresent(Bool.self, forKey: .vpnAccess) ?? active
    }

    var hasPaidAccess: Bool {
        active || vpnAccess
    }

    var remainingDeviceSlots: Int {
        max(deviceLimit - activeDevices, 0)
    }
}

struct DeviceAddon: Codable, Equatable, Identifiable {
    var id: String
    var subscriptionId: String
    var checkoutSessionId: String
    var paymentId: String?
    var provider: String
    var status: String
    var quantity: Int
    var unitAmountMinor: Int
    var amountMinor: Int
    var currency: String
    var startsAt: String
    var expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case subscriptionId = "subscription_id"
        case checkoutSessionId = "checkout_session_id"
        case paymentId = "payment_id"
        case provider
        case status
        case quantity
        case unitAmountMinor = "unit_amount_minor"
        case amountMinor = "amount_minor"
        case currency
        case startsAt = "starts_at"
        case expiresAt = "expires_at"
    }
}

struct DeviceAddonCheckoutSession: Decodable, Equatable {
    var id: String
    var url: String
}

struct BillingPlan: Codable, Equatable, Identifiable {
    var id: String
    var name: String?
    var provider: String?
    var amountCents: Int
    var currency: String
    var interval: String
    var deviceLimit: Int
    var tier: String
    var status: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case amountCents = "amount_cents"
        case currency
        case interval
        case deviceLimit = "device_limit"
        case tier
        case status
    }
}

struct BillingPlanOption: Codable, Equatable, Identifiable {
    var id: String
    var provider: String
    var tier: String
    var name: String
    var meta: String
    var action: String
    var current: Bool
    var disabled: Bool
    var months: Int
    var amountCents: Int
    var currency: String
    var deviceLimit: Int
}

struct BillingPlanFamily: Codable, Equatable, Identifiable {
    var id: String { tier }
    var tier: String
    var name: String
    var deviceLimit: Int
    var plans: [BillingPlanOption]
}

struct BillingSummary: Codable, Equatable {
    var title: String
    var subtitle: String
    var emptyMessage: String
    var entitlementStatus: BillingEntitlementStatus
    var currentPlan: BillingPlanOption?
    var currentPeriodEnd: String?
    var effectiveExpiresAt: String?
    var remainingText: String?
    var status: String?
    var plans: [BillingPlanOption]
    var families: [BillingPlanFamily]
}

enum BillingEntitlementStatus: String, Codable, Equatable {
    case active
    case inactive
    case unknown
}

struct BillingPayment: Codable, Equatable, Identifiable {
    var id: String
    var subscriptionId: String?
    var checkoutSessionId: String?
    var planId: String?
    var provider: String
    var amountMinor: Int
    var currency: String
    var method: String
    var status: String
    var receiptUrl: String?
    var failureReason: String?
    var refundedAmountMinor: Int?
    var refundedAt: String?
    var paidAt: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case subscriptionId = "subscription_id"
        case checkoutSessionId = "checkout_session_id"
        case planId = "plan_id"
        case provider
        case amountMinor = "amount_minor"
        case currency
        case method
        case status
        case receiptUrl = "receipt_url"
        case failureReason = "failure_reason"
        case refundedAmountMinor = "refunded_amount_minor"
        case refundedAt = "refunded_at"
        case paidAt = "paid_at"
        case createdAt = "created_at"
    }
}

struct ClientDiagnosticsReport: Codable, Equatable {
    var deviceId: String?
    var platform: String = "macos"
    var appVersion: String = "\(VEXAppInfo.version)+\(VEXAppInfo.buildNumber)"
    var reason: String
    var status: String
    var vpnState: String
    var endpoint: String?
    var dnsOk: Bool = true
    var httpsOk: Bool = true
    var latencyAverageMs: Double?
    var rxBytes: Int64
    var txBytes: Int64
    var samples: [String: String]
    var connectionEvent: String? = nil
    var transportFrom: String? = nil
    var transportTo: String? = nil

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case platform
        case appVersion = "app_version"
        case reason
        case status
        case vpnState = "vpn_state"
        case endpoint
        case dnsOk = "dns_ok"
        case httpsOk = "https_ok"
        case latencyAverageMs = "latency_avg_ms"
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case samples
        case connectionEvent = "connection_event"
        case transportFrom = "transport_from"
        case transportTo = "transport_to"
    }
}

extension Encodable {
    func dictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

enum VpnRoutingMode: String, Codable, Equatable {
    case allExceptRu = "all_except_ru"
    case fullTunnel = "full_tunnel"
}

struct PreparedTunnel: Equatable {
    var device: VpnDevice
    var config: String
    var locationId: String
    var profileVersion: Int?
    var routingMode: VpnRoutingMode
    var bypassRegion: String?
    var bypassRangesCount: Int
    var bypassDomainsCount: Int
    var routingPolicyVersion: String
    var rotationRequired: Bool
    var awgVersion: Int = 3
}

struct ManagedVpnProfile: Codable, Equatable {
    var unchanged: Bool?
    var version: Int?
    var revoked: Bool?
    var rotationRequired: Bool?
    var deviceId: String?
    var `protocol`: String?
    var server: String?
    var port: Int?
    var serverPublicKey: String?
    var presharedKey: String?
    var assignedIpv4: String?
    var dns: [String]?
    var allowedIps: [String]?
    var bypassRanges: [String]?
    var bypassDomains: [String]?
    var routingPolicyVersion: String?
    var amnezia: ManagedVpnAmnezia?
    var amneziaVersion: Int?
    var config: String?

    enum CodingKeys: String, CodingKey {
        case unchanged
        case version
        case revoked
        case rotationRequired = "rotation_required"
        case deviceId = "device_id"
        case `protocol`
        case server
        case port
        case serverPublicKey = "server_public_key"
        case presharedKey = "preshared_key"
        case assignedIpv4 = "assigned_ipv4"
        case dns
        case allowedIps = "allowed_ips"
        case bypassRanges = "bypass_ranges"
        case bypassDomains = "bypass_domains"
        case routingPolicyVersion = "routing_policy_version"
        case amnezia
        case amneziaVersion = "amnezia_version"
        case config
    }
}

struct ManagedVpnAmnezia: Codable, Equatable {
    var jc: Int?
    var jmin: Int?
    var jmax: Int?
    var s1: Int?
    var s2: Int?
    var s3: Int?
    var s4: Int?
    var h1: String?
    var h2: String?
    var h3: String?
    var h4: String?
    var i1: String?
    var i2: String?
    var i3: String?
    var i4: String?
    var i5: String?
    var headerProtectionKey: String?
    var contentPaddingAddition: String?
    var rekeyAfterTime: String?
    var rekeyTimeout: String?
    var rejectAfterTime: String?
    var keepaliveTimeout: String?
    var maxHandshakeAttempts: String?
    var randomTrailers: String?
    var disableCookies: String?

    enum CodingKeys: String, CodingKey {
        case jc, jmin, jmax, s1, s2, s3, s4
        case h1, h2, h3, h4, i1, i2, i3, i4, i5
        case headerProtectionKey = "header_protection_key"
        case contentPaddingAddition = "content_padding_addition"
        case rekeyAfterTime = "rekey_after_time"
        case rekeyTimeout = "rekey_timeout"
        case rejectAfterTime = "reject_after_time"
        case keepaliveTimeout = "keepalive_timeout"
        case maxHandshakeAttempts = "max_handshake_attempts"
        case randomTrailers = "random_trailers"
        case disableCookies = "disable_cookies"
    }
}

struct WireGuardKeyPair: Codable, Equatable {
    var privateKey: String
    var publicKey: String
    var keyEpoch: Int
}

struct AppRemoteConfig: Codable, Equatable {
    var version: String?
    var signature: String?
    var releasedAt: String?
    var platform: String?
    var channel: String?
    var minSupportedBuild: Int?
    var recommendedBuild: Int?
    var recommendedVersion: String?
    var coreVersion: String?
    var configSchemaVersion: Int?
    var minConfigSchemaVersion: Int?
    var routingPolicyVersion: String?
    var featureFlags: [String: Bool]?
    var incidentBanner: String?
}

struct VEXAppInfo: Equatable {
    static var version: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--render-ui-preview"),
           let previewVersion = ProcessInfo.processInfo.environment["VEX_PREVIEW_APP_VERSION"],
           !previewVersion.isEmpty {
            return previewVersion
        }
        #endif
        return bundleString("CFBundleShortVersionString") ?? "0.1.0"
    }

    static var buildNumber: Int {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--render-ui-preview"),
           let previewBuild = ProcessInfo.processInfo.environment["VEX_PREVIEW_APP_BUILD"],
           let buildNumber = Int(previewBuild) {
            return buildNumber
        }
        #endif
        let rawValue = bundleString("CFBundleVersion") ?? "1"
        return Int(rawValue) ?? 1
    }

    static let channel = "stable"
    static let coreVersion = "0.1.0"
    static let configSchemaVersion = 1
    static let apiClientVersion = "native-macos-1"
    static let routingPolicyVersion = "2026.06.22.1"
    static let defaultBypassRegion = "ru"

    private static func bundleString(_ key: String) -> String? {
        let bundles = [
            Bundle(identifier: "app.vex.vpn.native"),
            Bundle.main,
        ]
        return bundles
            .compactMap { $0?.object(forInfoDictionaryKey: key) as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
