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
    var latencyMs: Double?

    var displayName: String {
        if city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return id.uppercased()
        }
        return "\(flagEmoji ?? "") \(city)".trimmingCharacters(in: .whitespaces)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case countryCode = "country_code"
        case city
        case flagEmoji = "flag_emoji"
        case availability
        case status
        case healthyNodes = "healthy_nodes"
        case latencyMs = "latency_ms"
    }
}

struct SupportTicket: Codable, Equatable, Identifiable {
    var id: String
    var subject: String
    var message: String
    var messages: [SupportMessage]?
    var status: String
    var priority: String?
    var source: String
    var adminNote: String?
    var createdAt: String
    var updatedAt: String
    var closedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case subject
        case message
        case messages
        case status
        case priority
        case source
        case adminNote = "admin_note"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
    }
}

struct SupportMessage: Codable, Equatable, Identifiable {
    var id: String
    var ticketId: String
    var sender: String
    var authorId: String?
    var body: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case ticketId = "ticket_id"
        case sender
        case authorId = "author_id"
        case body
        case createdAt = "created_at"
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
        case vpnAccess = "vpn_access"
    }

    var hasPaidAccess: Bool {
        active || vpnAccess
    }
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
    var name: String
    var meta: String
    var action: String
    var current: Bool
    var disabled: Bool
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
}

enum BillingEntitlementStatus: String, Codable, Equatable {
    case active
    case inactive
    case unknown
}

enum BillingError: LocalizedError {
    case missingCheckoutURL
    case missingPortalURL

    var errorDescription: String? {
        switch self {
        case .missingCheckoutURL:
            return "Платежная ссылка недоступна."
        case .missingPortalURL:
            return "Ссылка управления подпиской недоступна."
        }
    }
}

struct CheckoutSession: Codable, Equatable {
    var id: String
    var planId: String
    var provider: String
    var url: String
    var status: String

    enum CodingKeys: String, CodingKey {
        case id
        case planId = "plan_id"
        case provider
        case url
        case status
    }
}

struct BillingPortalSession: Codable, Equatable {
    var id: String?
    var provider: String?
    var url: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case url
        case createdAt = "created_at"
    }
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
}

struct WireGuardKeyPair: Codable, Equatable {
    var privateKey: String
    var publicKey: String
    var keyEpoch: Int
}

struct SupportSocketEnvelope: Codable, Equatable {
    var type: String
    var ticket: SupportTicket?
    var tickets: [SupportTicket]?
    var message: String?
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static var buildNumber: Int {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return Int(rawValue) ?? 1
    }

    static let channel = "stable"
    static let coreVersion = "0.1.0"
    static let configSchemaVersion = 1
    static let apiClientVersion = "native-macos-1"
    static let routingPolicyVersion = "2026.06.22.1"
    static let defaultBypassRegion = "ru"
}
