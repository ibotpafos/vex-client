// Thin TypeScript mirror of Go response DTOs for API payloads consumed by the client.

export type UserDTO = {
  id: string;
  email: string;
  status?: string;
};

export type AuthResultDTO = {
  user: UserDTO;
  session: {
    access_token: string;
    expires_at?: string;
  };
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
  psk_rotated_at?: string;
  billing_plan_id?: string;
  billing_tier?: string;
  rate_limit_mbps?: number;
  traffic_priority?: number;
  shield_enabled?: boolean;
  assigned_ipv4?: string;
  node_id?: string;
  node_assignment_reason?: string;
  node_assigned_at?: string;
  last_node_change_at?: string;
  endpoint?: string;
  latency_ms?: number;
  created_at?: string;
  revoked_at?: string;
};

export type DeviceUsageResponseDTO = {
  usage?: DeviceUsageDTO[];
};

export type DeviceUsageDTO = {
  device_id: string;
  user_id?: string;
  node_id?: string;
  connection_status?: string;
  connected?: boolean;
  multiple_devices_detected?: boolean;
  latest_handshake_at?: string;
  seconds_since_handshake?: number | null;
  rx_bytes?: number;
  tx_bytes?: number;
  total_bytes?: number;
  rate_limit_mbps?: number;
  traffic_priority?: number;
  rx_rate_bps?: number;
  tx_rate_bps?: number;
};

export type LocationDTO = {
  id: string;
  country_code?: string;
  city?: string;
  flag_emoji?: string;
  availability?: string;
  status?: string;
  healthy_nodes?: number;
  endpoint?: string;
  latency_ms?: number;
};

export type NativeVPNProfileDTO = {
  unchanged?: boolean;
  version?: number;
  revoked?: boolean;
  rotation_required?: boolean;
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
  };
  config?: string;
};

export type RegisterNativeDeviceResultDTO = {
  device_registered?: boolean;
  device: DeviceDTO;
  binding_status?: string;
  trust_level?: string;
};

export type RegisterDevicePushTokenResultDTO = {
  device: DeviceDTO;
};

export type DeviceIdentityChallengeDTO = {
  id: string;
  nonce: string;
  purpose: string;
  expires_at?: string;
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
  created_at: string;
  updated_at: string;
  closed_at?: string;
};

export type EntitlementDTO = {
  active?: boolean;
  plan_id?: string;
  display_name?: string;
  account_status?: string;
  subscription_title?: string;
  subscription_subtitle?: string;
  remaining_text?: string;
  status?: string;
  tier?: string;
  current_period_end?: string;
  effective_expires_at?: string;
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
  updateAvailable?: boolean;
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
  checkedAt?: string;
};

export type AppRemoteConfigResponseDTO = {
  version?: string;
  signature?: string;
  releasedAt?: string;
  platform?: string;
  channel?: string;
  minSupportedBuild?: number;
  recommendedBuild?: number;
  recommendedVersion?: string;
  coreVersion?: string;
  configSchemaVersion?: number;
  minConfigSchemaVersion?: number;
  routingPolicyVersion?: string;
  featureFlags?: Record<string, boolean>;
  incidentBanner?: string;
};
