import { type BillingPlanOption, type BillingPlanSource, type BillingSummary } from './billingSummary';
import { type ManualUpdatePreflightResult } from './updatePreflight';
import { type VpnRoutingMode } from '@/vpn/routingPolicy';

export type Entitlement = {
  active: boolean;
  planId?: string;
  displayName?: string;
  accountStatus?: string;
  subscriptionTitle?: string;
  subscriptionSubtitle?: string;
  remainingText?: string;
  status?: string;
  tier?: string;
  currentPeriodEnd?: string;
  effectiveExpiresAt?: string;
  vpnAccess: boolean;
};

export type { BillingPlanOption, BillingSummary };

export type CheckoutSession = {
  id: string;
  planId: string;
  provider: string;
  url: string;
  status: string;
};

export type BillingPortalSession = {
  id: string;
  provider: string;
  url: string;
  createdAt?: string;
};

export type AndroidUpdateManifest = {
  enabled: boolean;
  latestVersion: string;
  latestBuild: number;
  minimumBuild: number;
  currentBuild: number;
  updateAvailable: boolean;
  required: boolean;
  apkUrl: string;
  releaseNotes?: string;
  message: string;
};

export type AppUpdateCheckResult = {
  updateAvailable: boolean;
  required: boolean;
  currentBuildBlocked?: boolean;
  latestVersion: string;
  latestBuild: number;
  minSupportedBuild: number;
  minConfigSchemaVersion?: number;
  downloadUrl: string;
  changelog?: string;
  checksumSha256?: string;
  signatureUrl?: string;
  channel?: string;
  reason?: string;
  rolloutPercent?: number;
  checkedAt?: string;
};

export type { ManualUpdatePreflightResult };

export type AppRemoteConfig = {
  version?: string;
  signature?: string;
  releasedAt?: string;
  platform: string;
  channel: string;
  minSupportedBuild: number;
  recommendedBuild: number;
  recommendedVersion?: string;
  coreVersion?: string;
  configSchemaVersion: number;
  minConfigSchemaVersion: number;
  routingPolicyVersion?: string;
  featureFlags: Record<string, boolean>;
  incidentBanner?: string;
};

export type User = {
  id: string;
  email: string;
  status: string;
};

export type AuthSession = {
  user: User;
  accessToken: string;
  expiresAt?: string;
};

export type VpnDevice = {
  id: string;
  name: string;
  status: string;
  assignedIpv4?: string;
  nodeId?: string;
  protocol?: string;
  protocolLabel?: string;
  endpoint?: string;
  latencyMs?: number;
  publicKey?: string;
  provisioningMode?: string;
  clientKeyOwnership?: string;
  externalDeviceId?: string;
  platform?: string;
  pushProvider?: string;
  hasPushToken?: boolean;
};

export type VpnLocation = {
  id: string;
  countryCode: string;
  city: string;
  flagEmoji?: string;
  availability: string;
  status: string;
  healthyNodes: number;
  latencyMs?: number;
};

export type VpnDeviceUsage = {
  deviceId: string;
  connectionStatus: string;
  connected: boolean;
  secondsSinceHandshake?: number;
  rxBytes: number;
  txBytes: number;
  totalBytes: number;
};

export type ClientDiagnosticsReportInput = {
  deviceId?: string;
  platform?: string;
  appVersion?: string;
  reason?: string;
  status?: string;
  vpnState?: string;
  endpoint?: string;
  observedPublicIp?: string;
  dnsOk?: boolean;
  httpsOk?: boolean;
  packetLossPercent?: number;
  latencyAverageMs?: number;
  latencyMaxMs?: number;
  rxBytes?: number;
  txBytes?: number;
  samples?: Record<string, unknown>;
  samplesJson?: string;
};

export type SupportMessage = {
  id: string;
  ticketId: string;
  sender: 'user' | 'admin' | 'system';
  authorId?: string;
  body: string;
  createdAt: string;
};

export type SupportTicket = {
  id: string;
  subject: string;
  message: string;
  messages?: SupportMessage[];
  status: string;
  priority?: string;
  source: string;
  adminNote?: string;
  createdAt: string;
  updatedAt: string;
  closedAt?: string;
};

export type SupportSocketEnvelope = {
  type: string;
  ticket?: ServerSupportTicket;
  tickets?: ServerSupportTicket[];
  message?: string;
};

export type SupportSocketHandle = {
  close: () => void;
  sendMessage: (message: { body: string; subject?: string; ticketId?: string }) => boolean;
};

export type SupportSocketOptions = {
  onError?: (message: string) => void;
  onOpen?: () => void;
  onSnapshot?: (tickets: SupportTicket[]) => void;
  onTicket?: (ticket: SupportTicket) => void;
};

export type PreparedTunnel = {
  device: VpnDevice;
  config: string;
  profileVersion?: number;
  routingMode?: VpnRoutingMode;
  bypassRegion?: string;
  bypassRangesCount?: number;
  bypassDomainsCount?: number;
  routingPolicyVersion?: string;
  rotationRequired?: boolean;
};

export type PreparedTunnelOptions = {
  cachedConfig?: string;
  knownVersion?: number;
  locationId?: string;
  routingMode?: VpnRoutingMode;
  bypassRegion?: string;
};

export type ServerSupportMessage = {
  id: string;
  ticket_id: string;
  sender: string;
  author_id?: string;
  body: string;
  created_at: string;
};

export type ServerSupportTicket = {
  id: string;
  user_id?: string;
  subject: string;
  message: string;
  messages?: ServerSupportMessage[];
  status: string;
  priority?: string;
  assigned_admin_user_id?: string;
  source: string;
  admin_note?: string;
  created_at: string;
  updated_at: string;
  closed_at?: string;
};

export type ServerDevice = {
  id: string;
  name?: string;
  status?: string;
  provisioning_mode?: string;
  client_key_ownership?: string;
  external_device_id?: string;
  platform?: string;
  push_provider?: string;
  push_token?: string;
  has_push_token?: boolean;
  public_key?: string;
  assigned_ipv4?: string;
  node_id?: string;
  protocol?: string;
  protocol_label?: string;
  endpoint?: string;
  latency_ms?: number;
};

export type ServerDeviceUsageResponse = {
  usage?: ServerDeviceUsage[];
};

export type ServerDeviceUsage = {
  device_id: string;
  connection_status?: string;
  connected?: boolean;
  seconds_since_handshake?: number | null;
  rx_bytes?: number;
  tx_bytes?: number;
  total_bytes?: number;
};

export type ServerLocation = {
  id: string;
  country_code?: string;
  city?: string;
  flag_emoji?: string;
  availability?: string;
  status?: string;
  healthy_nodes?: number;
  latency_ms?: number;
};

export type ServerManagedVpnProfile = {
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

export type ServerNativeDeviceRegistration = {
  device_registered?: boolean;
  device: ServerDevice;
};

export type ServerUser = {
  id: string;
  email: string;
  status?: string;
};

export type ServerAuthResult = {
  user: ServerUser;
  session: {
    access_token: string;
    expires_at?: string;
  };
};

export type ServerEntitlement = {
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

export type ServerBillingPlan = BillingPlanSource;

export type ServerCheckoutSession = {
  id: string;
  plan_id: string;
  provider: string;
  url: string;
  status: string;
};

export type ServerPortalSession = {
  id?: string;
  provider?: string;
  url?: string;
  created_at?: string;
};

export type ServerAppUpdateCheckResponse = {
  updateAvailable?: boolean;
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

export type ServerAppRemoteConfigResponse = {
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
