// Native request/response projections share Go-derived generated-contract types.
// Field selections and optional keys preserve the existing client API.
// Legacy-only fields/nullability remain explicit compatibility rules.
// Type queries keep this projection module fully erased at runtime.
type UserDTOSpec = import('./generated-contract').UserDTOSpec;
type AuthResultDTOSpec = import('./generated-contract').AuthResultDTOSpec;
type EmailOTPChallengeDTOSpec = import('./generated-contract').EmailOTPChallengeDTOSpec;
type DeviceDTOSpec = import('./generated-contract').DeviceDTOSpec;
type DeviceUsageResponseDTOSpec = import('./generated-contract').DeviceUsageResponseDTOSpec;
type DeviceTrafficQuotaDTOSpec = import('./generated-contract').DeviceTrafficQuotaDTOSpec;
type DeviceUsageDTOSpec = import('./generated-contract').DeviceUsageDTOSpec;
type LocationDTOSpec = import('./generated-contract').LocationDTOSpec;
type NativeVPNProfileDTOSpec = import('./generated-contract').NativeVPNProfileDTOSpec;
type StagedDevicePSKProfileDTOSpec = import('./generated-contract').StagedDevicePSKProfileDTOSpec;
type AcknowledgeStagedDevicePSKProfileResultDTOSpec =
  import('./generated-contract').AcknowledgeStagedDevicePSKProfileResultDTOSpec;
type RegisterNativeDeviceResultDTOSpec = import('./generated-contract').RegisterNativeDeviceResultDTOSpec;
type RegisterDevicePushTokenResultDTOSpec = import('./generated-contract').RegisterDevicePushTokenResultDTOSpec;
type DeviceIdentityChallengeDTOSpec = import('./generated-contract').DeviceIdentityChallengeDTOSpec;
export type NativeDeviceRegistrationRequest = import('./generated-contract').NativeDeviceRegistrationRequestSpec;
export type NativeDeviceIdentityChallengeRequest = import('./generated-contract').NativeDeviceIdentityChallengeRequestSpec;
type SupportMessageDTOSpec = import('./generated-contract').SupportMessageDTOSpec;
type SupportTicketDTOSpec = import('./generated-contract').SupportTicketDTOSpec;
type EntitlementDTOSpec = import('./generated-contract').EntitlementDTOSpec;
type BillingPlanDTOSpec = import('./generated-contract').BillingPlanDTOSpec;
type CheckoutSessionDTOSpec = import('./generated-contract').CheckoutSessionDTOSpec;
type PortalSessionDTOSpec = import('./generated-contract').PortalSessionDTOSpec;
type AppUpdateCheckResponseDTOSpec = import('./generated-contract').AppUpdateCheckResponseDTOSpec;
type AppRemoteConfigResponseDTOSpec = import('./generated-contract').AppRemoteConfigResponseDTOSpec;

type WireProjection<
  T,
  RequiredKeys extends keyof T,
  OptionalKeys extends keyof T = never,
> = Required<Pick<T, RequiredKeys>> & Partial<Pick<T, OptionalKeys>>;

type AuthSessionDTO = Partial<Pick<AuthResultDTOSpec['session'], 'id' | 'access_token'>> & {
  expires_at?: AuthResultDTOSpec['session']['expires_at'] | null;
};

// Retain the legacy auth field absent from the current server response.
type AccessGrantSummary = {
  active?: boolean;
  device_limit?: number;
  tier?: string;
};

type DeviceSavedProfile = Partial<Pick<
  NonNullable<DeviceDTOSpec['saved_profiles']>[number],
  'node_id' | 'assigned_ipv4' | 'status' | 'profile_version'
>>;

type NativeAWGConfig = Partial<Pick<
  NonNullable<NativeVPNProfileDTOSpec['amnezia']>,
  'jc' | 'jmin' | 'jmax' | 's1' | 's2' | 's3' | 's4' |
  'h1' | 'h2' | 'h3' | 'h4' | 'i1' | 'i2' | 'i3' | 'i4' | 'i5' |
  'header_protection_key'
>>;

export type UserDTO = WireProjection<
  UserDTOSpec,
  'id' | 'email',
  'status'
>;

export type AuthResultDTO = Omit<WireProjection<
  AuthResultDTOSpec,
  'user' | 'session',
  never
>, 'user' | 'session'> & {
  user: UserDTO;
  session: AuthSessionDTO;
  access_grant?: AccessGrantSummary | null;
};

export type EmailOTPChallengeDTO = WireProjection<
  EmailOTPChallengeDTOSpec,
  'challenge_id',
  'expires_at'
>;

export type DeviceDTO = Omit<WireProjection<
  DeviceDTOSpec,
  'id',
  'user_id' | 'name' | 'protocol' | 'protocol_label' | 'status' | 'provisioning_mode'
  | 'client_key_ownership' | 'external_device_id' | 'platform' | 'app_version' | 'push_provider'
  | 'public_key' | 'crypto_profile' | 'psk_epoch' | 'profile_version' | 'psk_rotated_at'
  | 'billing_plan_id' | 'billing_tier' | 'rate_limit_mbps' | 'traffic_priority' | 'shield_enabled'
  | 'assigned_ipv4' | 'node_id' | 'node_assignment_reason' | 'node_assigned_at'
  | 'last_node_change_at' | 'endpoint' | 'latency_ms' | 'saved_profiles' | 'created_at'
  | 'revoked_at'
>, 'saved_profiles'> & {
  saved_profiles?: DeviceSavedProfile[];
};

export type DeviceUsageResponseDTO = Omit<WireProjection<
  DeviceUsageResponseDTOSpec,
  never,
  'usage' | 'client_ip' | 'current_device_id' | 'current_device_by' | 'traffic_quota'
>, 'usage'> & {
  usage?: DeviceUsageDTO[];
};

export type DeviceTrafficQuotaDTO = WireProjection<
  DeviceTrafficQuotaDTOSpec,
  'device_id' | 'used_bytes' | 'limit_bytes' | 'reset_at' | 'multiplier' | 'limit_reached',
  'effective_rate_limit_mbps'
>;

export type DeviceUsageDTO = WireProjection<
  DeviceUsageDTOSpec,
  'device_id',
  'user_id' | 'node_id' | 'connection_status' | 'connected' | 'multiple_devices_detected'
  | 'latest_handshake_at' | 'seconds_since_handshake' | 'rx_bytes' | 'tx_bytes' | 'total_bytes'
  | 'historical_rx_bytes' | 'historical_tx_bytes' | 'historical_total_bytes'
  | 'last_nonzero_traffic_at' | 'rate_limit_mbps' | 'traffic_priority' | 'rx_rate_bps'
  | 'tx_rate_bps'
>;

export type LocationDTO = WireProjection<
  LocationDTOSpec,
  'id',
  'country_code' | 'city' | 'display_name' | 'flag_emoji' | 'availability' | 'priority' | 'status'
  | 'node_count' | 'healthy_nodes' | 'awg3_nodes' | 'average_load_percent' | 'available_slots'
  | 'capabilities' | 'endpoint' | 'latency_ms'
>;

export type NativeVPNProfileDTO = Omit<WireProjection<
  NativeVPNProfileDTOSpec,
  'version' | 'revoked' | 'rotation_required',
  'unchanged' | 'device_id' | 'client_public_key' | 'client_key_epoch' | 'protocol' | 'server'
  | 'port' | 'server_public_key' | 'preshared_key' | 'assigned_ipv4' | 'dns' | 'allowed_ips'
  | 'bypass_ranges' | 'bypass_domains' | 'routing_policy_version' | 'expires_at' | 'authorization'
  | 'amnezia' | 'amnezia_version' | 'config'
>, 'amnezia'> & {
  amnezia?: NativeAWGConfig | null;
};

export type StagedDevicePSKProfileDTO = Omit<WireProjection<
  StagedDevicePSKProfileDTOSpec,
  'rotation_id' | 'activate' | 'current_version' | 'profile_version' | 'profile_digest'
  | 'deadline_at' | 'profile',
  never
>, 'profile'> & {
  profile: NativeVPNProfileDTO;
};

export type AcknowledgeStagedDevicePSKProfileResultDTO = WireProjection<
  AcknowledgeStagedDevicePSKProfileResultDTOSpec,
  'rotation_id' | 'accepted' | 'replayed',
  never
>;

export type RegisterNativeDeviceResultDTO = Omit<WireProjection<
  RegisterNativeDeviceResultDTOSpec,
  'device',
  'device_registered' | 'binding_status' | 'trust_level'
>, 'device'> & {
  device: DeviceDTO;
};

export type RegisterDevicePushTokenResultDTO = Omit<WireProjection<
  RegisterDevicePushTokenResultDTOSpec,
  never,
  'device'
>, 'device'> & {
  device?: DeviceDTO;
};

export type DeviceIdentityChallengeDTO = Omit<WireProjection<
  DeviceIdentityChallengeDTOSpec,
  'id' | 'nonce' | 'purpose',
  'expires_at'
>, 'expires_at'> & {
  expires_at?: DeviceIdentityChallengeDTOSpec['expires_at'] | null;
};

export type SupportMessageDTO = WireProjection<
  SupportMessageDTOSpec,
  'id' | 'ticket_id' | 'sender' | 'body' | 'created_at',
  'author_id'
>;

export type SupportTicketDTO = Omit<WireProjection<
  SupportTicketDTOSpec,
  'id' | 'subject' | 'message' | 'status' | 'source' | 'created_at' | 'updated_at',
  'user_id' | 'messages' | 'priority' | 'assigned_admin_user_id' | 'admin_note' | 'support_rating'
  | 'support_feedback' | 'support_rated_at' | 'closed_at'
>, 'messages' | 'support_feedback'> & {
  messages?: SupportMessageDTO[];
  support_feedback?: NonNullable<SupportTicketDTOSpec['support_feedback']> | null;
};

export type EntitlementDTO = WireProjection<
  EntitlementDTOSpec,
  never,
  'user_id' | 'active' | 'reason' | 'plan_id' | 'display_name' | 'account_status'
  | 'subscription_title' | 'subscription_subtitle' | 'remaining_text' | 'status' | 'tier'
  | 'current_period_end' | 'effective_expires_at' | 'switch_bonus_status' | 'switch_bonus_days'
  | 'switch_bonus_until' | 'device_limit' | 'active_devices' | 'grace_until' | 'can_create_device'
  | 'vpn_access'
>;

export type BillingPlanDTO = WireProjection<
  BillingPlanDTOSpec,
  'id' | 'amount_cents' | 'currency' | 'interval' | 'device_limit' | 'tier' | 'status',
  'name' | 'provider'
>;

export type CheckoutSessionDTO = WireProjection<
  CheckoutSessionDTOSpec,
  'id' | 'plan_id' | 'provider' | 'url' | 'status',
  never
>;

export type PortalSessionDTO = WireProjection<
  PortalSessionDTOSpec,
  never,
  'id' | 'provider' | 'url' | 'created_at'
>;

export type AppUpdateCheckResponseDTO = Omit<WireProjection<
  AppUpdateCheckResponseDTOSpec,
  'updateAvailable' | 'checkedAt',
  'delivery' | 'required' | 'currentBuildBlocked' | 'latestVersion' | 'latestBuild'
  | 'minSupportedBuild' | 'minConfigSchemaVersion' | 'downloadUrl' | 'changelog' | 'checksumSha256'
  | 'signatureUrl' | 'channel' | 'reason' | 'rolloutPercent'
>, 'delivery'> & {
  delivery?: 'native' | 'ota';
};

export type AppRemoteConfigResponseDTO = WireProjection<
  AppRemoteConfigResponseDTOSpec,
  'platform' | 'channel' | 'checkedAt',
  'version' | 'signature' | 'releasedAt' | 'minSupportedBuild' | 'recommendedBuild'
  | 'recommendedVersion' | 'coreVersion' | 'configSchemaVersion' | 'minConfigSchemaVersion'
  | 'minCoreVersion' | 'supportedApiClientVersions' | 'routingPolicyVersionPrefix'
  | 'routingPolicyVersion' | 'featureFlags' | 'accountFeatureFlags' | 'incidentBanner'
>;

// The desktop app-code exchange shares the server's Go-derived request fields.
export type AppAuthTokenRequest = Pick<
  import('./generated-contract').AppAuthTokenRequestSpec,
  'code' | 'code_verifier'
>;
