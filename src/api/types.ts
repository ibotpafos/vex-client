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
  delivery?: 'native' | 'ota';
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
  keyEpoch?: number;
  provisioningMode?: string;
  clientKeyOwnership?: string;
  externalDeviceId?: string;
  platform?: string;
  pushProvider?: string;
};

export type VpnLocation = {
  id: string;
  countryCode: string;
  city: string;
  flagEmoji?: string;
  availability: string;
  status: string;
  healthyNodes: number;
  endpoint?: string;
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
  connectionEvent?: 'connect_started' | 'connect_succeeded' | 'connect_failed' |
    'fallback_started' | 'fallback_succeeded' | 'fallback_failed' |
    'reconnect_started' | 'reconnect_succeeded' | 'reconnect_failed' |
    'unexpected_disconnect';
  connectDurationMs?: number;
  transportFrom?: 'awg3_udp443' | 'awg3' | 'awg2' | 'wireguard' | 'openvpn' | 'unknown';
  transportTo?: 'awg3_udp443' | 'awg3' | 'awg2' | 'wireguard' | 'openvpn' | 'unknown';
  sessionUptimeSeconds?: number;
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

export type ClientConnectionTelemetryInput = Pick<ClientDiagnosticsReportInput,
  'connectionEvent' | 'connectDurationMs' | 'transportFrom' | 'transportTo' | 'sessionUptimeSeconds'>;

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
