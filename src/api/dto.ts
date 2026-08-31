// Thin TypeScript mirror of Go response DTOs for API payloads consumed by the client.
//
// Contract: every type below is guarded by src/api/generated-contract.ts, which
// is GENERATED from the VPN repo's openapi.yaml (Go DTO structs). If you change
// a field here and the server shape does not match, `npm run typecheck` fails.
// To refresh the generated contract run, from the VPN repo:
//   python3 scripts/generate_openapi_schemas.py --client

export type UserDTO = {
  id: string;
  email: string;
  status?: string;
};

export type AuthResultDTO = {
  user: UserDTO;
  session: {
    id?: string;
    access_token?: string;
    expires_at?: string | null;
  };
  access_grant?: AccessGrantSummary | null;
};

type AccessGrantSummary = {
  active?: boolean;
  device_limit?: number;
  tier?: string;
};

export type EmailOTPChallengeDTO = {
  challenge_id: string;
  expires_at?: string;
};

export type DeviceDTO = {
  id: string;
  user_id?: string;
  name?: string;
  protocol?: string;
  protocol_label?: string;
  status?: string;
  provisioning_mode?: string;
  client_key_ownership?: string;
  external_device_id?: string;
  platform?: string;
  app_version?: string;
  push_provider?: string;
  public_key?: string;
  crypto_profile?: string;
  psk_epoch?: number;
  profile_version?: number;
  psk_rotated_at?: string | null;
  billing_plan_id?: string;
  billing_tier?: string;
  rate_limit_mbps?: number | null;
  traffic_priority?: number;
  shield_enabled?: boolean;
  assigned_ipv4?: string;
  node_id?: string;
  node_assignment_reason?: string;
  node_assigned_at?: string | null;
  last_node_change_at?: string | null;
  endpoint?: string;
  latency_ms?: number | null;
  saved_profiles?: DeviceSavedProfile[];
  created_at?: string;
  revoked_at?: string | null;
};

type DeviceSavedProfile = {
  node_id?: string;
  assigned_ipv4?: string;
  status?: string;
  profile_version?: number;
};

export type DeviceUsageResponseDTO = {
  usage?: DeviceUsageDTO[];
  client_ip?: string;
  current_device_id?: string;
  current_device_by?: string;
};

export type DeviceUsageDTO = {
  device_id: string;
  user_id?: string;
  node_id?: string;
  connection_status?: string;
  connected?: boolean;
  multiple_devices_detected?: boolean;
  latest_handshake_at?: string | null;
  seconds_since_handshake?: number | null;
  rx_bytes?: number;
  tx_bytes?: number;
  total_bytes?: number;
  historical_rx_bytes?: number;
  historical_tx_bytes?: number;
  historical_total_bytes?: number;
  last_nonzero_traffic_at?: string | null;
  rate_limit_mbps?: number | null;
  traffic_priority?: number;
  rx_rate_bps?: number | null;
  tx_rate_bps?: number | null;
};

export type LocationDTO = {
  id: string;
  country_code?: string;
  city?: string;
  flag_emoji?: string;
  availability?: string;
  priority?: number;
  status?: string;
  node_count?: number;
  healthy_nodes?: number;
  awg3_nodes?: number;
  average_load_percent?: number;
  available_slots?: number;
  endpoint?: string;
  latency_ms?: number | null;
};

export type NativeVPNProfileDTO = {
  unchanged?: boolean;
  version: number;
  revoked: boolean;
  rotation_required: boolean;
  device_id?: string;
  protocol?: string;
  server?: string;
  port?: number;
  server_public_key?: string;
  preshared_key?: string;
  assigned_ipv4?: string;
  dns?: string[];
  allowed_ips?: string[];
  bypass_ranges?: string[];
  bypass_domains?: string[];
  routing_policy_version?: string;
  expires_at?: string | null;
  authorization?: {
    key_id: string;
    algorithm: 'ECDSA_P256_SHA256_DER';
    payload_base64: string;
    signature_base64: string;
  };
  amnezia?: {
    jc?: number;
    jmin?: number;
    jmax?: number;
    s1?: number;
    s2?: number;
    s3?: number;
    s4?: number;
    h1?: string;
    h2?: string;
    h3?: string;
    h4?: string;
    i1?: string;
    i2?: string;
    i3?: string;
    i4?: string;
    i5?: string;
    header_protection_key?: string;
  } | null;
  amnezia_version?: number;
  config?: string;
};

export type StagedDevicePSKProfileDTO = {
  rotation_id: string;
  activate: false;
  current_version: number;
  profile_version: number;
  profile_digest: string;
  deadline_at: string;
  profile: NativeVPNProfileDTO;
};

export type AcknowledgeStagedDevicePSKProfileResultDTO = {
  rotation_id: string;
  accepted: boolean;
  replayed: boolean;
};

export type RegisterNativeDeviceResultDTO = {
  device_registered?: boolean;
  device: DeviceDTO;
  binding_status?: string;
  trust_level?: string;
};

export type RegisterDevicePushTokenResultDTO = {
  device?: DeviceDTO;
};

export type DeviceIdentityChallengeDTO = {
  id: string;
  nonce: string;
  purpose: string;
  expires_at?: string | null;
};

export type SupportMessageDTO = {
  id: string;
  ticket_id: string;
  sender: string;
  author_id?: string;
  body: string;
  created_at: string;
};

export type SupportTicketDTO = {
  id: string;
  user_id?: string;
  subject: string;
  message: string;
  messages?: SupportMessageDTO[];
  status: string;
  priority?: string;
  assigned_admin_user_id?: string;
  source: string;
  admin_note?: string;
  support_rating?: number | null;
  support_feedback?: string | null;
  support_rated_at?: string | null;
  created_at: string;
  updated_at: string;
  closed_at?: string | null;
};

export type EntitlementDTO = {
  user_id?: string;
  active?: boolean;
  reason?: string;
  plan_id?: string;
  display_name?: string;
  account_status?: string;
  subscription_title?: string;
  subscription_subtitle?: string;
  remaining_text?: string;
  status?: string;
  tier?: string;
  current_period_end?: string | null;
  effective_expires_at?: string | null;
  switch_bonus_status?: string;
  switch_bonus_days?: number;
  switch_bonus_until?: string | null;
  device_limit?: number;
  active_devices?: number;
  grace_until?: string | null;
  can_create_device?: boolean;
  vpn_access?: boolean;
};

export type BillingPlanDTO = {
  id: string;
  name?: string;
  provider?: string;
  amount_cents: number;
  currency: string;
  interval: string;
  device_limit: number;
  tier: string;
  status: string;
};

export type CheckoutSessionDTO = {
  id: string;
  plan_id: string;
  provider: string;
  url: string;
  status: string;
};

export type PortalSessionDTO = {
  id?: string;
  provider?: string;
  url?: string;
  created_at?: string;
};

export type AppUpdateCheckResponseDTO = {
  updateAvailable: boolean;
  delivery?: 'native' | 'ota';
  required?: boolean;
  currentBuildBlocked?: boolean;
  latestVersion?: string;
  latestBuild?: number;
  minSupportedBuild?: number;
  minConfigSchemaVersion?: number;
  downloadUrl?: string;
  changelog?: string;
  checksumSha256?: string;
  signatureUrl?: string;
  channel?: string;
  reason?: string;
  rolloutPercent?: number;
  checkedAt: string;
};

export type AppRemoteConfigResponseDTO = {
  version?: string;
  signature?: string;
  releasedAt?: string | null;
  platform: string;
  channel: string;
  minSupportedBuild?: number;
  recommendedBuild?: number;
  recommendedVersion?: string;
  coreVersion?: string;
  configSchemaVersion?: number;
  minConfigSchemaVersion?: number;
  minCoreVersion?: string;
  supportedApiClientVersions?: string[];
  routingPolicyVersionPrefix?: string;
  routingPolicyVersion?: string;
  featureFlags?: Record<string, boolean>;
  incidentBanner?: string;
  checkedAt: string;
};
