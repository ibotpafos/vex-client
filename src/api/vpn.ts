import { Platform } from 'react-native';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';
import { generateWireGuardKeyPair, replaceWireGuardKeyPair, getOrCreateWireGuardKeyPair, type WireGuardKeyPair } from '@/native/vexVpn';
import { nativeVpnDeviceForClient } from '@/vpn/nativeDeviceSelection';
import { defaultVpnRoutingMode, defaultVpnRoutingPolicyVersion, resolvedVpnBypassRegion } from '@/vpn/routingPolicy';
import { jsonRequest, rawRequest, clientVersionHeaders, isTauriRuntime } from './client';
import { buildCreateDeviceRequest } from './deviceCreateRequest';
import {
  type VpnDevice,
  type VpnLocation,
  type VpnDeviceUsage,
  type PreparedTunnel,
  type PreparedTunnelOptions,
  type ClientDiagnosticsReportInput,
  type ServerDevice,
  type ServerLocation,
  type ServerDeviceUsageResponse,
  type ServerDeviceUsage,
  type ServerManagedVpnProfile,
  type ServerNativeDeviceRegistration,
} from './types';

const mobileProtocol = 'amneziawg';

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
      device = await createDevice(accessToken, client, locationId, baseExternalDeviceId);
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
  const configQuery = new URLSearchParams({
    format: 'conf',
    token: token.token,
    location: locationId,
  });
  const config = await rawRequest(`/v1/devices/${encodeURIComponent(device.id)}/config?${configQuery.toString()}`, {
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

export async function registerDevicePushToken(accessToken: string, deviceId: string, push: { provider: string; token: string }): Promise<VpnDevice> {
  const response = await jsonRequest<{ device: ServerDevice }>('/v1/devices/push-token', {
    method: 'POST',
    accessToken,
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

async function createDevice(accessToken: string, client: VpnClientDescriptor, locationId: string | undefined, externalDeviceId: string): Promise<VpnDevice> {
  const location = normalizeLocationId(locationId);
  const appInfo = await getAppInfo();
  const request = buildCreateDeviceRequest(client, location, externalDeviceId, appInfo);
  const response = await jsonRequest<{ device: ServerDevice }>('/v1/devices', {
    method: 'POST',
    accessToken,
    idempotencyKey: request.idempotencyKey,
    body: request.body,
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

function nativeDeviceId(deviceId: string): string {
  return deviceId.trim();
}

export type VpnClientDescriptor = {
  deviceName: string;
  idempotencyPrefix: string;
  platform: 'android' | 'ios' | 'windows' | 'macos' | 'linux' | 'web';
};

export function currentVpnClient(): VpnClientDescriptor {
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

export function requiresManagedNativeProfile(client: VpnClientDescriptor): boolean {
  return Platform.OS === 'android' || Platform.OS === 'ios' || client.platform === 'android' || client.platform === 'ios';
}

function logApiDebug(...items: unknown[]) {
  console.log(...items);
}

export function parseDevice(item: ServerDevice): VpnDevice {
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

export function parseDeviceUsage(item: ServerDeviceUsage): VpnDeviceUsage {
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

export function parseLocation(item: ServerLocation): VpnLocation {
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

export function managedProfileConfig(profile: ServerManagedVpnProfile, keyPair: WireGuardKeyPair | null): string {
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

export function managedProfileAmneziaConfig(amnezia: ServerManagedVpnProfile['amnezia']): string {
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

export function managedProfileEndpoint(profile: ServerManagedVpnProfile): string | undefined {
  if (!profile.server) {
    return undefined;
  }
  if (typeof profile.port === 'number' && profile.port > 0) {
    return `${profile.server}:${profile.port}`;
  }
  return profile.server;
}
