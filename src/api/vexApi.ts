import { Platform } from 'react-native';
import { getAppInfo, getOrCreateDeviceId, VEX_API_CLIENT_VERSION, VEX_CONFIG_SCHEMA_VERSION } from '@/native/appInfo';
import { generateWireGuardKeyPair, getOrCreateWireGuardKeyPair, replaceWireGuardKeyPair, type WireGuardKeyPair } from '@/native/vexVpn';
import { nativeVpnDeviceForClient } from '@/vpn/nativeDeviceSelection';
import { defaultVpnRoutingMode, defaultVpnRoutingPolicyVersion, resolvedVpnBypassRegion, type VpnRoutingMode } from '@/vpn/routingPolicy';
import { buildBillingSummary, type BillingPlanOption, type BillingPlanSource, type BillingSummary } from './billingSummary';
import { validateManualUpdatePayloadForBaseUrl, type ManualUpdatePreflightResult } from './updatePreflight';

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

type SupportSocketEnvelope = {
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

const mobileProtocol = 'amneziawg';
const requestTimeoutMs = 30000;
const getRequestRetryCount = 2;
const requestRetryDelayMs = 600;
const shouldLogApiRequests = typeof __DEV__ !== 'undefined' && __DEV__;
let tauriFetchPromise: Promise<typeof import('@tauri-apps/plugin-http').fetch> | null = null;

export const vexApiBaseUrl = trimTrailingSlash(process.env.EXPO_PUBLIC_VEX_API_BASE_URL || 'https://vexguard.app');
const apiRequestBaseUrl = vexApiBaseUrl;

export function hasPaidEntitlement(item: Entitlement | null | undefined): item is Entitlement {
  return Boolean(item?.vpnAccess || item?.active);
}

export async function login(email: string, password: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<ServerAuthResult>('/v1/auth/login', {
    method: 'POST',
    body: { email, password, remember_me: true, device_session: true },
  }));
}

export async function exchangeAppAuthCode(code: string, codeVerifier: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<ServerAuthResult>('/v1/auth/token', {
    method: 'POST',
    body: {
      code,
      code_verifier: codeVerifier,
    },
  }));
}

export async function me(accessToken: string): Promise<User> {
  const user = await jsonRequest<ServerUser>('/v1/auth/me', { accessToken });
  return parseUser(user);
}

export async function refreshSession(accessToken: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<ServerAuthResult>('/v1/auth/refresh', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
  }));
}

export async function entitlement(accessToken: string): Promise<Entitlement> {
  try {
    const item = await jsonRequest<ServerEntitlement>('/v1/billing/entitlement', {
      accessToken,
      suppressErrorLog: true,
    });
    return parseEntitlement(item);
  } catch (error) {
    if (error instanceof Error && error.message === 'not found') {
      return { active: false, vpnAccess: false };
    }
    throw error;
  }
}

export async function billingSummary(accessToken: string): Promise<BillingSummary> {
  const [plans, currentEntitlement] = await Promise.all([
    billingPlans(),
    entitlement(accessToken).catch((): null => null),
  ]);
  return buildBillingSummary(plans, currentEntitlement);
}

async function billingPlans(): Promise<ServerBillingPlan[]> {
  return jsonRequest<ServerBillingPlan[]>('/v1/billing/plans', { suppressErrorLog: true });
}

type CheckoutSessionOptions = {
  failedUrl?: string;
  returnUrl?: string;
};

export async function checkoutSession(accessToken: string, plan: { id: string; provider?: string }, options: CheckoutSessionOptions = {}): Promise<CheckoutSession> {
  const item = await jsonRequest<ServerCheckoutSession>('/v1/billing/checkout-session', {
    method: 'POST',
    accessToken,
    idempotencyKey: `android-checkout-${plan.id}-${Date.now()}`,
    body: {
      plan_id: plan.id,
      provider: plan.provider || 'platega',
      return_url: options.returnUrl || vexApiBaseUrl,
      failed_url: options.failedUrl || vexApiBaseUrl,
    },
  });
  return parseCheckoutSession(item);
}

export async function cancelSubscription(accessToken: string): Promise<Entitlement> {
  const item = await jsonRequest<ServerEntitlement>('/v1/billing/subscription/cancel', {
    method: 'POST',
    accessToken,
    idempotencyKey: `subscription-cancel-${Date.now()}`,
  });
  return parseEntitlement(item);
}

export async function portalSession(accessToken: string): Promise<BillingPortalSession> {
  const item = await jsonRequest<ServerPortalSession>('/v1/billing/portal-session', {
    accessToken,
    suppressErrorLog: true,
  });
  return {
    id: item.id || '',
    provider: item.provider || 'manual',
    url: item.url || '',
    createdAt: item.created_at || undefined,
  };
}

export async function appUpdateCheck(input: {
  platform: string;
  appVersion: string;
  buildNumber: number;
  channel?: string;
  coreVersion?: string;
  deviceId?: string;
  osVersion?: string;
  arch?: string;
  apiClientVersion?: string;
  configSchemaVersion?: number;
}): Promise<AppUpdateCheckResult> {
  const item = await jsonRequest<ServerAppUpdateCheckResponse>('/v1/app/update/check', {
    method: 'POST',
    suppressErrorLog: true,
    body: {
      ...input,
      apiClientVersion: input.apiClientVersion ?? VEX_API_CLIENT_VERSION,
      configSchemaVersion: input.configSchemaVersion ?? VEX_CONFIG_SCHEMA_VERSION,
    },
  });
  return {
    updateAvailable: Boolean(item.updateAvailable),
    required: Boolean(item.required),
    currentBuildBlocked: Boolean(item.currentBuildBlocked),
    latestVersion: item.latestVersion || '',
    latestBuild: item.latestBuild ?? 0,
    minSupportedBuild: item.minSupportedBuild ?? 0,
    minConfigSchemaVersion: item.minConfigSchemaVersion ?? undefined,
    downloadUrl: absolutizeUrl(item.downloadUrl || ''),
    changelog: item.changelog || undefined,
    checksumSha256: item.checksumSha256 || undefined,
    signatureUrl: absolutizeUrl(item.signatureUrl || ''),
    channel: item.channel || undefined,
    reason: item.reason || undefined,
    rolloutPercent: item.rolloutPercent ?? undefined,
    checkedAt: item.checkedAt || undefined,
  };
}

export async function appRemoteConfig(input: {
  platform: string;
  appVersion: string;
  buildNumber: number;
  channel?: string;
  coreVersion?: string;
  deviceId?: string;
  osVersion?: string;
  arch?: string;
  apiClientVersion?: string;
  configSchemaVersion?: number;
}): Promise<AppRemoteConfig> {
  const item = await jsonRequest<ServerAppRemoteConfigResponse>('/v1/app/remote-config', {
    method: 'POST',
    body: {
      ...input,
      apiClientVersion: input.apiClientVersion ?? VEX_API_CLIENT_VERSION,
      configSchemaVersion: input.configSchemaVersion ?? VEX_CONFIG_SCHEMA_VERSION,
    },
  });
  return {
    version: item.version || undefined,
    signature: item.signature || undefined,
    releasedAt: item.releasedAt || undefined,
    platform: item.platform || input.platform,
    channel: item.channel || input.channel || 'stable',
    minSupportedBuild: item.minSupportedBuild ?? 0,
    recommendedBuild: item.recommendedBuild ?? 0,
    recommendedVersion: item.recommendedVersion || undefined,
    coreVersion: item.coreVersion || undefined,
    configSchemaVersion: item.configSchemaVersion ?? 0,
    minConfigSchemaVersion: item.minConfigSchemaVersion ?? 0,
    routingPolicyVersion: item.routingPolicyVersion || undefined,
    featureFlags: item.featureFlags ?? {},
    incidentBanner: item.incidentBanner || undefined,
  };
}

export function validateManualUpdatePayload(input: {
  downloadUrl?: string | null;
  checksumSha256?: string | null;
  signatureUrl?: string | null;
}): ManualUpdatePreflightResult {
  return validateManualUpdatePayloadForBaseUrl(input, vexApiBaseUrl);
}

export async function preparedTunnel(accessToken: string, client: VpnClientDescriptor = currentVpnClient(), options: PreparedTunnelOptions = {}): Promise<PreparedTunnel> {
  try {
    return await managedVpnProfile(accessToken, client, options);
  } catch (error) {
    if (requiresManagedNativeProfile(client)) {
      throw error;
    }
    logApiDebug('managed vpn profile failed, falling back to prepared tunnel:', error instanceof Error ? error.message : error);
  }
  return preparedTunnelFromDeviceConfig(accessToken, client, options);
}

async function preparedTunnelFromDeviceConfig(accessToken: string, client: VpnClientDescriptor = currentVpnClient(), options: PreparedTunnelOptions = {}): Promise<PreparedTunnel> {
  const versionHeaders = await clientVersionHeaders();
  const locationId = normalizeLocationId(options.locationId);
  const [allDevices, runtimeDeviceId] = await Promise.all([vpnDevices(accessToken), getOrCreateDeviceId()]);
  const baseExternalDeviceId = nativeDeviceId(runtimeDeviceId);
  let device = nativeVpnDeviceForClient(allDevices, locationId, baseExternalDeviceId, baseExternalDeviceId);
  device ??= allDevices.find((d) => d.status === 'active' && d.protocol === mobileProtocol && d.name === client.deviceName);

  if (!device) {
    try {
      device = await createDevice(accessToken, client, locationId);
    } catch (error) {
      const fallback = allDevices.find((d) => d.status === 'active' && d.protocol === mobileProtocol);
      if (fallback) {
        logApiDebug('createDevice failed, falling back to existing active device for testing:', fallback.name);
        device = fallback;
      } else {
        throw error;
      }
    }
  }

  const token = await jsonRequest<{ token: string }>(`/v1/devices/${encodeURIComponent(device.id)}/config-token`, {
    method: 'POST',
    accessToken,
    headers: versionHeaders,
  });
  const config = await rawRequest(`/v1/devices/${encodeURIComponent(device.id)}/config?format=conf&token=${encodeURIComponent(token.token)}`, {
    accessToken,
    headers: versionHeaders,
  });
  return { device, config };
}

async function managedVpnProfile(accessToken: string, client: VpnClientDescriptor, options: PreparedTunnelOptions): Promise<PreparedTunnel> {
  const versionHeaders = await clientVersionHeaders();
  const keyPair = await getOrCreateWireGuardKeyPair();
  const locationId = normalizeLocationId(options.locationId);
  const [allDevices, runtimeDeviceId] = await Promise.all([vpnDevices(accessToken), getOrCreateDeviceId()]);
  const baseExternalDeviceId = nativeDeviceId(runtimeDeviceId);
  const externalDeviceId = baseExternalDeviceId;
  let device = nativeVpnDeviceForClient(allDevices, locationId, externalDeviceId, baseExternalDeviceId);
  if (!device) {
    device = await registerNativeDevice(accessToken, client, keyPair, locationId, externalDeviceId);
  }
  if (deviceNeedsLocalKeySync(device, keyPair)) {
    device = await syncManagedVpnKey(accessToken, device.id, keyPair);
  }

  const query = new URLSearchParams({ device_id: device.id });
  query.set('location', locationId);
  const routingMode = options.routingMode ?? defaultVpnRoutingMode;
  query.set('routing_mode', routingMode);
  const bypassRegion = resolvedVpnBypassRegion(routingMode, options.bypassRegion);
  if (bypassRegion) {
    query.set('bypass_region', bypassRegion);
  }
  if (typeof options.knownVersion === 'number' && options.knownVersion > 0) {
    query.set('known_version', String(options.knownVersion));
  }
  const profile = await jsonRequest<ServerManagedVpnProfile>(`/v1/vpn/profile?${query.toString()}`, {
    accessToken,
    headers: versionHeaders,
    suppressErrorLog: true,
  });
  if (profile.revoked) {
    throw new Error('Устройство отключено администратором.');
  }
  if (profile.unchanged) {
    if (!options.cachedConfig) {
      throw new Error('Управляемый VPN-профиль не изменился, но локальный cache пуст.');
    }
    return {
      config: options.cachedConfig,
      device,
      profileVersion: typeof profile.version === 'number' ? profile.version : options.knownVersion,
      routingMode,
      bypassRegion,
      bypassRangesCount: profile.bypass_ranges?.filter(Boolean).length ?? 0,
      bypassDomainsCount: profile.bypass_domains?.filter(Boolean).length ?? 0,
      routingPolicyVersion: profile.routing_policy_version || defaultVpnRoutingPolicyVersion,
      rotationRequired: Boolean(profile.rotation_required),
    };
  }
  const config = profile.config || managedProfileConfig(profile, keyPair);
  return {
    config,
    device: {
      ...device,
      assignedIpv4: profile.assigned_ipv4 || device.assignedIpv4,
      endpoint: managedProfileEndpoint(profile) || device.endpoint,
      protocol: profile.protocol || device.protocol,
    },
    profileVersion: typeof profile.version === 'number' ? profile.version : undefined,
    routingMode,
    bypassRegion,
    bypassRangesCount: profile.bypass_ranges?.filter(Boolean).length ?? 0,
    bypassDomainsCount: profile.bypass_domains?.filter(Boolean).length ?? 0,
    routingPolicyVersion: profile.routing_policy_version || defaultVpnRoutingPolicyVersion,
    rotationRequired: Boolean(profile.rotation_required),
  };
}

export async function vpnDevices(accessToken: string): Promise<VpnDevice[]> {
  const response = await jsonRequest<ServerDevice[]>('/v1/devices', { accessToken });
  return response.map(parseDevice);
}

export async function vpnLocations(accessToken: string): Promise<VpnLocation[]> {
  const response = await jsonRequest<ServerLocation[]>('/v1/locations', { accessToken, suppressErrorLog: true });
  return response.map(parseLocation).filter((location) => location.healthyNodes > 0 && location.availability !== 'retired');
}

export async function vpnDeviceUsage(accessToken: string): Promise<VpnDeviceUsage[]> {
  const response = await jsonRequest<ServerDeviceUsageResponse>('/v1/devices/usage', { accessToken, suppressErrorLog: true });
  return (response.usage ?? []).map(parseDeviceUsage);
}

export async function reportVpnConnect(accessToken: string, tunnel: PreparedTunnel | { device?: VpnDevice; profileVersion?: number }): Promise<void> {
  const deviceId = tunnel.device?.id;
  if (!deviceId) {
    return;
  }
  await rawRequest('/v1/vpn/connect', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
    body: {
      device_id: deviceId,
      profile_version: tunnel.profileVersion,
      protocol: tunnel.device?.protocol,
      client_time: new Date().toISOString(),
    },
  });
}

export async function reportVpnDisconnect(accessToken: string, tunnel: { device?: VpnDevice; profileVersion?: number } | null | undefined, reason = 'user'): Promise<void> {
  const deviceId = tunnel?.device?.id;
  if (!deviceId) {
    return;
  }
  await rawRequest('/v1/vpn/disconnect', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
    body: {
      device_id: deviceId,
      profile_version: tunnel.profileVersion,
      reason,
    },
  });
}

export async function submitClientDiagnostics(accessToken: string, report: ClientDiagnosticsReportInput): Promise<void> {
  await rawRequest('/v1/diagnostics/client', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
    timeout: 12_000,
    body: {
      device_id: report.deviceId,
      platform: report.platform,
      app_version: report.appVersion,
      reason: report.reason,
      status: report.status,
      vpn_state: report.vpnState,
      endpoint: report.endpoint,
      observed_public_ip: report.observedPublicIp,
      dns_ok: report.dnsOk,
      https_ok: report.httpsOk,
      packet_loss_percent: report.packetLossPercent,
      latency_avg_ms: report.latencyAverageMs,
      latency_max_ms: report.latencyMaxMs,
      rx_bytes: report.rxBytes,
      tx_bytes: report.txBytes,
      samples: report.samples,
      samples_json: report.samplesJson,
    },
  });
}

export async function supportTickets(accessToken: string): Promise<SupportTicket[]> {
  const items = await jsonRequest<ServerSupportTicket[] | null>('/v1/support-tickets', {
    accessToken,
    suppressErrorLog: true,
  });
  return (items ?? []).map(parseSupportTicket);
}

export async function createSupportTicket(
  accessToken: string,
  input: { subject: string; message: string; source?: string },
): Promise<SupportTicket> {
  const item = await jsonRequest<ServerSupportTicket>('/v1/support-tickets', {
    accessToken,
    body: {
      message: input.message,
      source: input.source ?? 'mobile',
      subject: input.subject,
    },
    idempotencyKey: `support-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    method: 'POST',
  });
  return parseSupportTicket(item);
}

export function connectSupportSocket(accessToken: string, options: SupportSocketOptions): SupportSocketHandle {
  let closed = false;
  let connectionIssueReported = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let socket: WebSocket | null = null;

  const reportConnectionIssue = (message: string) => {
    if (connectionIssueReported) return;
    connectionIssueReported = true;
    options.onError?.(message);
  };

  const scheduleReconnect = () => {
    if (closed || reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      void connect();
    }, 3000);
  };

  const connect = async () => {
    try {
      const url = await supportWebSocketURL(accessToken);
      if (closed) return;
      socket = new WebSocket(url);
      socket.onopen = () => {
        connectionIssueReported = false;
        options.onOpen?.();
      };
      socket.onmessage = (event) => dispatchSupportSocketEvent(String(event.data), options);
      socket.onclose = scheduleReconnect;
      socket.onerror = () => reportConnectionIssue('Соединение с чатом прервано, переподключаемся.');
    } catch (error) {
      if (!closed) {
        reportConnectionIssue(apiErrorMessage(error, 'Не удалось подключить чат поддержки.'));
        scheduleReconnect();
      }
    }
  };

  void connect();

  return {
    close() {
      closed = true;
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
      }
      socket?.close();
    },
    sendMessage(message) {
      if (!socket || socket.readyState !== WebSocket.OPEN) return false;
      socket.send(JSON.stringify({
        body: message.body,
        subject: message.subject,
        ticket_id: message.ticketId,
        type: 'support.message',
      }));
      return true;
    },
  };
}

async function supportWebSocketURL(accessToken: string) {
  const payload = await jsonRequest<{ ticket?: string }>('/v1/support-ws-ticket', {
    accessToken,
    suppressErrorLog: true,
  });
  if (!payload.ticket?.trim()) {
    throw new Error('Support websocket ticket missing');
  }
  const url = new URL('/v1/support-ws', apiRequestBaseUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.searchParams.set('ticket', payload.ticket);
  return url.toString();
}

function dispatchSupportSocketEvent(data: string, options: SupportSocketOptions) {
  let envelope: SupportSocketEnvelope;
  try {
    envelope = JSON.parse(data) as SupportSocketEnvelope;
  } catch {
    options.onError?.('Получили некорректное событие чата поддержки.');
    return;
  }

  switch (envelope.type) {
    case 'support.snapshot':
      options.onSnapshot?.((envelope.tickets ?? []).map(parseSupportTicket));
      return;
    case 'support.ticket':
      if (envelope.ticket) options.onTicket?.(parseSupportTicket(envelope.ticket));
      return;
    case 'support.error':
      if (envelope.message) options.onError?.(envelope.message);
      return;
  }
}

function apiErrorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

export async function registerDevicePushToken(accessToken: string, deviceId: string, push: { provider: string; token: string }): Promise<VpnDevice> {
  const response = await jsonRequest<{ device: ServerDevice }>('/v1/vpn/push-token', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
    body: {
      device_id: deviceId,
      provider: push.provider,
      token: push.token,
    },
  });
  return parseDevice(response.device);
}

export async function rotateManagedVpnKey(accessToken: string, deviceId: string): Promise<VpnDevice> {
  const keyPair = await generateWireGuardKeyPair();
  if (!keyPair?.publicKey) {
    throw new Error('Локальный WireGuard ключ недоступен.');
  }
  const response = await jsonRequest<{ device: ServerDevice }>('/v1/vpn/rotate-key', {
    method: 'POST',
    accessToken,
    idempotencyKey: `native-rotate-key-${deviceId}-${keyPair.keyEpoch ?? Date.now()}`,
    body: {
      device_id: deviceId,
      public_key: keyPair.publicKey,
      key_epoch: keyPair.keyEpoch ?? 1,
    },
  });
  await replaceWireGuardKeyPair(keyPair);
  return parseDevice(response.device);
}

async function syncManagedVpnKey(accessToken: string, deviceId: string, keyPair: WireGuardKeyPair): Promise<VpnDevice> {
  const response = await jsonRequest<{ device: ServerDevice }>('/v1/vpn/rotate-key', {
    method: 'POST',
    accessToken,
    idempotencyKey: `native-sync-key-${deviceId}-${keyPair.keyEpoch ?? 1}-${keyPair.publicKey}`,
    body: {
      device_id: deviceId,
      public_key: keyPair.publicKey,
      key_epoch: keyPair.keyEpoch ?? 1,
    },
  });
  return parseDevice(response.device);
}

async function createDevice(accessToken: string, client: VpnClientDescriptor, locationId?: string): Promise<VpnDevice> {
  const location = normalizeLocationId(locationId);
  const response = await jsonRequest<{ device: ServerDevice }>('/v1/devices', {
    method: 'POST',
    accessToken,
    idempotencyKey: `${client.idempotencyPrefix}-${location}-device-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    body: {
      name: nativeDeviceName(client),
      location,
      protocol: mobileProtocol,
    },
  });
  return parseDevice(response.device);
}

async function registerNativeDevice(accessToken: string, client: VpnClientDescriptor, keyPair: WireGuardKeyPair | null, locationId: string, externalDeviceId: string): Promise<VpnDevice> {
  if (!keyPair?.publicKey) {
    throw new Error('Локальные ключи WireGuard не сгенерированы. Проверьте настройки устройства.');
  }
  const appInfo = await getAppInfo();
  const response = await jsonRequest<ServerNativeDeviceRegistration>('/v1/devices/register', {
    method: 'POST',
    accessToken,
    idempotencyKey: `native-register-${externalDeviceId}-${locationId}`,
    body: {
      device_id: externalDeviceId,
      device_name: nativeDeviceName(client),
      platform: client.platform || appInfo.platform || Platform.OS,
      app_version: appInfo.version,
      protocol: mobileProtocol,
      location: locationId,
      public_key: keyPair?.publicKey,
      key_epoch: keyPair?.keyEpoch ?? (keyPair ? 1 : undefined),
    },
  });
  return parseDevice(response.device);
}

function isActiveMobileProtocolDevice(device: VpnDevice): boolean {
  return device.status === 'active' && device.protocol === mobileProtocol;
}

function deviceNeedsLocalKeySync(device: VpnDevice, keyPair: WireGuardKeyPair | null): keyPair is WireGuardKeyPair {
  return isManagedClientOwnedDevice(device) &&
    Boolean(keyPair?.publicKey) &&
    normalizedPublicKey(device.publicKey) !== normalizedPublicKey(keyPair?.publicKey);
}

function isManagedClientOwnedDevice(device: VpnDevice): boolean {
  return device.provisioningMode === 'managed_native' || device.clientKeyOwnership === 'client';
}

function normalizedPublicKey(value?: string): string {
  return value?.trim() || '';
}

function normalizeLocationId(locationId?: string): string {
  return locationId?.trim().toLowerCase() || 'de';
}

function nativeDeviceName(client: VpnClientDescriptor): string {
  return client.deviceName;
}

function legacyNativeDeviceNameForLocation(client: VpnClientDescriptor, locationId: string): string {
  return `${client.deviceName} ${locationId.toUpperCase()}`;
}

function nativeDeviceId(deviceId: string): string {
  return deviceId.trim();
}

type VpnClientDescriptor = {
  deviceName: string;
  idempotencyPrefix: string;
  platform: 'android' | 'ios' | 'windows' | 'macos' | 'linux' | 'web';
};

function currentVpnClient(): VpnClientDescriptor {
  if (Platform.OS === 'android') {
    return { deviceName: 'Android', idempotencyPrefix: 'android', platform: 'android' };
  }
  if (Platform.OS === 'ios') {
    return { deviceName: 'iPhone', idempotencyPrefix: 'ios', platform: 'ios' };
  }
  if (isTauriRuntime()) {
    const platform = typeof navigator !== 'undefined' ? `${navigator.platform} ${navigator.userAgent}`.toLowerCase() : '';
    if (platform.includes('win')) {
      return { deviceName: 'Windows', idempotencyPrefix: 'windows', platform: 'windows' };
    }
    if (platform.includes('linux') || platform.includes('x11') || platform.includes('wayland')) {
      return { deviceName: 'Linux', idempotencyPrefix: 'linux', platform: 'linux' };
    }
    if (platform.includes('mac') || platform.includes('darwin')) {
      return { deviceName: 'Mac', idempotencyPrefix: 'macos', platform: 'macos' };
    }
    return { deviceName: 'Desktop', idempotencyPrefix: 'desktop', platform: 'web' };
  }
  return { deviceName: 'Web', idempotencyPrefix: 'web', platform: 'web' };
}

function requiresManagedNativeProfile(client: VpnClientDescriptor): boolean {
  return Platform.OS === 'android' || Platform.OS === 'ios' || client.platform === 'android' || client.platform === 'ios';
}

function isTauriRuntime(): boolean {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}

async function tauriHttpFetch() {
  tauriFetchPromise ??= import('@tauri-apps/plugin-http').then((module) => module.fetch);
  return tauriFetchPromise;
}

async function jsonRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  return JSON.parse(await rawRequest(path, options)) as T;
}

async function rawRequest(path: string, options: RequestOptions = {}): Promise<string> {
  const method = options.method ?? 'GET';
  const maxAttempts = method === 'GET' ? getRequestRetryCount + 1 : 1;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return await rawRequestAttempt(path, options, method);
    } catch (error) {
      lastError = error;
      if (attempt >= maxAttempts || !isRetryableRequestError(error)) {
        throw error;
      }
      await delay(requestRetryDelayMs * attempt);
    }
  }

  throw lastError;
}

async function rawRequestAttempt(path: string, options: RequestOptions, method: string): Promise<string> {
  const controller = new AbortController();
  const timeoutMs = options.timeout ?? requestTimeoutMs;
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const headers: Record<string, string> = {
    Accept: 'application/json',
  };
  if (options.accessToken) {
    headers.Authorization = `Bearer ${options.accessToken}`;
  }
  if (options.idempotencyKey) {
    headers['Idempotency-Key'] = options.idempotencyKey;
  }
  if (options.headers) {
    Object.assign(headers, options.headers);
  }

  const init: RequestInit = {
    headers,
    method,
  };

  if (options.body) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }

  try {
    let response;
    const isTauri = isTauriRuntime();
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Request: [${init.method || 'GET'}] ${apiRequestBaseUrl}${path} isTauri: ${isTauri}`);
    }
    
    if (isTauri) {
      try {
        const tauriFetch = await tauriHttpFetch();
        response = await tauriFetch(`${apiRequestBaseUrl}${path}`, { headers, method, body: init.body, connectTimeout: timeoutMs });
      } catch (err: unknown) {
        if (shouldLogApiRequests && !options.suppressErrorLog) {
          const message = err instanceof Error ? err.message : String(err);
          logApiDebug('Tauri fetch error details:', message);
        }
        throw err;
      }
    } else {
      response = await fetch(`${apiRequestBaseUrl}${path}`, { ...init, signal: controller.signal });
    }
    
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Response: ${response.status} ${response.statusText}`);
    }
    const text = await response.text();
    if (!response.ok) {
      if (shouldLogApiRequests && !options.suppressErrorLog) {
        logApiDebug(`API Error Response: ${text}`);
      }
      throw new Error(parseApiError(text) ?? `HTTP ${response.status}`);
    }
    return text;
  } catch (error: unknown) {
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      const message = error instanceof Error ? error.message : String(error);
      logApiDebug('API Outer Catch Error:', message);
    }
    if (error instanceof Error && error.name === 'AbortError') {
      throw new Error('Превышено время ожидания API.');
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function isRetryableRequestError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }
  const message = error.message.toLowerCase();
  return error.name === 'AbortError'
    || message.includes('fetch request has been canceled')
    || message.includes('превышено время ожидания api')
    || message.includes('network request failed')
    || message.includes('unable to resolve host');
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function logApiDebug(...items: unknown[]) {
  console.log(...items);
}

function parseDevice(item: ServerDevice): VpnDevice {
  return {
    id: item.id,
    name: item.name ?? '',
    status: item.status ?? '',
    assignedIpv4: item.assigned_ipv4 || undefined,
    nodeId: item.node_id || undefined,
    protocol: item.protocol || undefined,
    protocolLabel: item.protocol_label || undefined,
    endpoint: item.endpoint || undefined,
    latencyMs: typeof item.latency_ms === 'number' ? item.latency_ms : undefined,
    publicKey: item.public_key || undefined,
    provisioningMode: item.provisioning_mode || undefined,
    clientKeyOwnership: item.client_key_ownership || undefined,
    externalDeviceId: item.external_device_id || undefined,
    platform: item.platform || undefined,
    pushProvider: item.push_provider || undefined,
    hasPushToken: Boolean(item.has_push_token || item.push_token),
  };
}

function parseDeviceUsage(item: ServerDeviceUsage): VpnDeviceUsage {
  return {
    deviceId: item.device_id,
    connectionStatus: item.connection_status || 'unknown',
    connected: Boolean(item.connected),
    secondsSinceHandshake: typeof item.seconds_since_handshake === 'number' ? item.seconds_since_handshake : undefined,
    rxBytes: typeof item.rx_bytes === 'number' ? item.rx_bytes : 0,
    txBytes: typeof item.tx_bytes === 'number' ? item.tx_bytes : 0,
    totalBytes: typeof item.total_bytes === 'number' ? item.total_bytes : 0,
  };
}

function parseLocation(item: ServerLocation): VpnLocation {
  return {
    id: item.id,
    countryCode: item.country_code || item.id.toUpperCase(),
    city: item.city || item.id.toUpperCase(),
    flagEmoji: item.flag_emoji || undefined,
    availability: item.availability || 'available',
    status: item.status || 'unknown',
    healthyNodes: typeof item.healthy_nodes === 'number' ? item.healthy_nodes : 0,
    latencyMs: typeof item.latency_ms === 'number' ? item.latency_ms : undefined,
  };
}

function managedProfileConfig(profile: ServerManagedVpnProfile, keyPair: WireGuardKeyPair | null): string {
  if (!keyPair?.privateKey) {
    throw new Error('Управляемый VPN-профиль требует локальный ключ устройства.');
  }
  const endpoint = managedProfileEndpoint(profile);
  const required = {
    address: profile.assigned_ipv4,
    endpoint,
    serverPublicKey: profile.server_public_key,
  };
  for (const [name, value] of Object.entries(required)) {
    if (!value) {
      throw new Error(`Управляемый VPN-профиль неполный: ${name}.`);
    }
  }
  const dns = profile.dns?.filter(Boolean);
  const allowedIps = profile.allowed_ips?.filter(Boolean);
  const amnezia = managedProfileAmneziaConfig(profile.amnezia);
  const presharedKey = profile.preshared_key?.trim();
  return `[Interface]
PrivateKey = ${keyPair.privateKey}
Address = ${profile.assigned_ipv4}
DNS = ${(dns?.length ? dns : ['1.1.1.1', '8.8.8.8']).join(', ')}
MTU = 1360
${amnezia}

[Peer]
PublicKey = ${profile.server_public_key}
${presharedKey ? `PresharedKey = ${presharedKey}\n` : ''}Endpoint = ${endpoint}
AllowedIPs = ${(allowedIps?.length ? allowedIps : ['0.0.0.0/0']).join(', ')}
PersistentKeepalive = 25
`;
}

function managedProfileAmneziaConfig(amnezia: ServerManagedVpnProfile['amnezia']): string {
  if (!amnezia) {
    return '';
  }
  const lines: string[] = [];
  const addNumber = (key: string, value?: number) => {
    if (typeof value === 'number' && value !== 0) {
      lines.push(`${key} = ${value}`);
    }
  };
  const addString = (key: string, value?: string) => {
    const normalized = value?.trim();
    if (normalized) {
      lines.push(`${key} = ${normalized}`);
    }
  };
  addNumber('Jc', amnezia.jc);
  addNumber('Jmin', amnezia.jmin);
  addNumber('Jmax', amnezia.jmax);
  addNumber('S1', amnezia.s1);
  addNumber('S2', amnezia.s2);
  addNumber('S3', amnezia.s3);
  addNumber('S4', amnezia.s4);
  addString('H1', amnezia.h1);
  addString('H2', amnezia.h2);
  addString('H3', amnezia.h3);
  addString('H4', amnezia.h4);
  addString('I1', amnezia.i1);
  addString('I2', amnezia.i2);
  addString('I3', amnezia.i3);
  addString('I4', amnezia.i4);
  addString('I5', amnezia.i5);
  return lines.length ? `${lines.join('\n')}\n` : '';
}

function managedProfileEndpoint(profile: ServerManagedVpnProfile): string | undefined {
  if (!profile.server) {
    return undefined;
  }
  if (typeof profile.port === 'number' && profile.port > 0) {
    return `${profile.server}:${profile.port}`;
  }
  return profile.server;
}

function parseAuth(item: ServerAuthResult): AuthSession {
  return {
    user: parseUser(item.user),
    accessToken: item.session.access_token,
    expiresAt: item.session.expires_at || undefined,
  };
}

function parseUser(item: ServerUser): User {
  return {
    id: item.id,
    email: item.email,
    status: item.status ?? '',
  };
}

function parseCheckoutSession(item: ServerCheckoutSession): CheckoutSession {
  return {
    id: item.id,
    planId: item.plan_id,
    provider: item.provider,
    url: item.url,
    status: item.status,
  };
}

function parseEntitlement(item: ServerEntitlement): Entitlement {
  return {
    active: Boolean(item.active),
    planId: item.plan_id || undefined,
    displayName: item.display_name || undefined,
    accountStatus: item.account_status || undefined,
    subscriptionTitle: item.subscription_title || undefined,
    subscriptionSubtitle: item.subscription_subtitle || undefined,
    remainingText: item.remaining_text || undefined,
    status: item.status || undefined,
    tier: item.tier || undefined,
    currentPeriodEnd: item.current_period_end || undefined,
    effectiveExpiresAt: item.effective_expires_at || undefined,
    vpnAccess: Boolean(item.vpn_access),
  };
}

type ServerSupportMessage = {
  id: string;
  ticket_id: string;
  sender: string;
  author_id?: string;
  body: string;
  created_at: string;
};

type ServerSupportTicket = {
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

function parseSupportTicket(item: ServerSupportTicket): SupportTicket {
  return {
    id: item.id,
    subject: item.subject,
    message: item.message,
    messages: item.messages?.map(parseSupportMessage),
    status: item.status,
    priority: item.priority,
    source: item.source,
    adminNote: item.admin_note,
    createdAt: item.created_at,
    updatedAt: item.updated_at,
    closedAt: item.closed_at,
  };
}

function parseSupportMessage(item: ServerSupportMessage): SupportMessage {
  return {
    id: item.id,
    ticketId: item.ticket_id,
    sender: parseSupportSender(item.sender),
    authorId: item.author_id,
    body: item.body,
    createdAt: item.created_at,
  };
}

function parseSupportSender(value: string): SupportMessage['sender'] {
  return value === 'admin' || value === 'system' ? value : 'user';
}

function parseApiError(text: string): string | null {
  try {
    const parsed = JSON.parse(text) as { message?: string };
    return parsed.message?.trim() || null;
  } catch {
    return null;
  }
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '');
}

function absolutizeUrl(value: string): string {
  if (!value) {
    return '';
  }
  if (/^https?:\/\//i.test(value)) {
    return value;
  }
  if (value.startsWith('/')) {
    return `${vexApiBaseUrl}${value}`;
  }
  return `${vexApiBaseUrl}/${value}`;
}

type RequestOptions = {
  accessToken?: string;
  body?: Record<string, unknown>;
  headers?: Record<string, string>;
  idempotencyKey?: string;
  method?: string;
  suppressErrorLog?: boolean;
  timeout?: number;
};

async function clientVersionHeaders(): Promise<Record<string, string>> {
  const [appInfo, deviceId] = await Promise.all([getAppInfo(), getOrCreateDeviceId()]);
  return {
    'X-Vex-Platform': appInfo.platform,
    'X-Vex-App-Version': appInfo.version,
    'X-Vex-Build-Number': appInfo.build || '0',
    'X-Vex-Core-Version': appInfo.coreVersion,
    'X-Vex-Channel': appInfo.channel,
    'X-Vex-Device-ID': deviceId,
    'X-Vex-OS-Version': `${appInfo.platform} ${String(Platform.Version ?? '')}`,
    'X-Vex-API-Client-Version': appInfo.apiClientVersion,
    'X-Vex-Config-Schema-Version': String(appInfo.configSchemaVersion),
  };
}

type ServerDevice = {
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

type ServerDeviceUsageResponse = {
  usage?: ServerDeviceUsage[];
};

type ServerDeviceUsage = {
  device_id: string;
  connection_status?: string;
  connected?: boolean;
  seconds_since_handshake?: number | null;
  rx_bytes?: number;
  tx_bytes?: number;
  total_bytes?: number;
};

type ServerLocation = {
  id: string;
  country_code?: string;
  city?: string;
  flag_emoji?: string;
  availability?: string;
  status?: string;
  healthy_nodes?: number;
  latency_ms?: number;
};

type ServerManagedVpnProfile = {
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

type ServerNativeDeviceRegistration = {
  device_registered?: boolean;
  device: ServerDevice;
};

type ServerUser = {
  id: string;
  email: string;
  status?: string;
};

type ServerAuthResult = {
  user: ServerUser;
  session: {
    access_token: string;
    expires_at?: string;
  };
};

type ServerEntitlement = {
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

type ServerBillingPlan = BillingPlanSource;

type ServerCheckoutSession = {
  id: string;
  plan_id: string;
  provider: string;
  url: string;
  status: string;
};

type ServerPortalSession = {
  id?: string;
  provider?: string;
  url?: string;
  created_at?: string;
};

type ServerAppUpdateCheckResponse = {
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

type ServerAppRemoteConfigResponse = {
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
