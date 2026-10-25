import { Platform } from 'react-native';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';
import { deviceIdentitySignaturePayload, getOrCreateDeviceIdentity } from '@/native/deviceIdentity';
import { generateWireGuardKeyPair, replaceWireGuardKeyPair, getOrCreateWireGuardKeyPair, supportsNativeRoutingPolicy, type WireGuardKeyPair } from '@/native/vexVpn';
import { nativeVpnDeviceForClient } from '@/vpn/nativeDeviceSelection';
import { isKeyEpochMismatchError, nextManagedKeyEpoch } from '@/vpn/keyEpochRecovery';
import { defaultVpnRoutingMode, defaultVpnRoutingPolicyVersion, resolvedVpnBypassRegion } from '@/vpn/routingPolicy';
import { devicePushTokenPath } from '@/notifications/pushRegistration';
import { jsonRequest, rawRequest, clientVersionHeaders } from './client';
import { ApiRequestError, isApiRequestCancelled, requireRequestActive } from './error';
import { withRequestCancellation } from './requestCancellation';
import { buildCreateDeviceRequest } from './deviceCreateRequest';
import { clientDiagnosticsRequestBody } from './clientDiagnosticsRequest';
import { getOrCreateNativeDeviceRegistration } from './nativeDeviceRegistration';
import { me } from './auth';
import { clearPendingVpnAccountKeyPair, confirmVpnAccountRegistration, getOrCreateVpnAccountIdentity, pendingVpnAccountKeyPair, rememberVpnAccountDevice, renewVpnAccountInstallation, savePendingVpnAccountKeyPair, saveVpnAccountKeyPair, vpnAccountRegistrationIdempotencyKey, withVpnAccountIdentity, type VpnAccountIdentity, type VpnAccountIdentityOptions } from '../native/vpnAccountIdentity';
import {
  type VpnDevice,
  type VpnLocation,
  type VpnDeviceUsage,
  type VpnDeviceUsageSnapshot,
  type VpnTrafficQuota,
  type PreparedTunnel,
  type PreparedTunnelOptions,
  type ClientDiagnosticsReportInput,
} from './types';
import {
  type DeviceDTO,
  type DeviceIdentityChallengeDTO,
  type DeviceTrafficQuotaDTO,
  type DeviceUsageDTO,
  type DeviceUsageResponseDTO,
  type LocationDTO,
  type NativeVPNProfileDTO,
  type StagedDevicePSKProfileDTO,
  type AcknowledgeStagedDevicePSKProfileResultDTO,
  type RegisterDevicePushTokenResultDTO,
  type RegisterNativeDeviceResultDTO,
  type NativeDeviceRegistrationRequest,
  type NativeDeviceIdentityChallengeRequest,
  type NativeVPNKeyRotationInput,
  type NativeVPNConnectionEventInput,
  type NativeVPNPushTokenInput,
  type NativeVPNPSKRotationACKInput,
} from './dto';
import { managedProfileAmneziaConfig } from '../vpn/amneziaConfig';
import { withManagedProfileAWGCapability } from '../vpn/profileCapabilities';
import type { VpnProfile } from '../vpn/profile';
import type { StagedDevicePSKProfile } from '../vpn/devicePskRotation';
import { normalizeLocationCatalog } from '../vpn/locationCatalog';
import { requireVpnLocationId } from '../vpn/locationId';
import { canRevalidateDevice } from '../vpn/profileRevalidation';
import { SessionOperationSupersededError } from '../vpn/sessionOperation';
import { nativeRoutingParameters, routingAuthorization } from '../vpn/nativeRoutingPolicy';
import { isPositiveSafeInteger, isNonnegativeSafeInteger } from '../vpn/profileNumbers';

const mobileProtocol = 'amneziawg';

// A legacy path is eligible only after a local pre-dispatch capability failure
// or a recognized legacy rejection from the managed-profile endpoint itself.
class LegacyProfileFallbackError extends Error {
  readonly originalError: Error;

  constructor(originalError: Error) {
    super('Managed VPN profile is unavailable for this legacy client.');
    this.originalError = originalError;
  }
}

export async function preparedTunnel(accessToken: string, client: VpnClientDescriptor = currentVpnClient(), options: PreparedTunnelOptions = {}): Promise<PreparedTunnel> {
  requireProfileRequest(options);
  try {
    return await managedVpnProfile(accessToken, client, options);
  } catch (error) {
    requireProfileRequest(options);
    const originalError = error instanceof LegacyProfileFallbackError ? error.originalError : error;
    if (originalError instanceof SessionOperationSupersededError || isApiRequestCancelled(originalError)) throw originalError;
    if (!(error instanceof LegacyProfileFallbackError) || requiresManagedNativeProfile(client)) {
      throw originalError;
    }
    logApiDebug('managed profile unavailable for legacy client; using device config');
  }
  return preparedTunnelFromDeviceConfig(accessToken, client, options);
}

async function preparedTunnelFromDeviceConfig(accessToken: string, client: VpnClientDescriptor = currentVpnClient(), options: PreparedTunnelOptions = {}): Promise<PreparedTunnel> {
  requireProfileRequest(options);
  const versionHeaders = await withRequestCancellation(clientVersionHeaders, options.signal);
  requireProfileRequest(options);
  const locationId = normalizeLocationId(options.locationId);
  const [allDevices, runtimeDeviceId] = await withRequestCancellation(() => Promise.all([vpnDevices(accessToken, options.signal), getOrCreateDeviceId()]), options.signal);
  requireProfileRequest(options);
  const baseExternalDeviceId = nativeDeviceId(runtimeDeviceId);
  let device = nativeVpnDeviceForClient(allDevices, locationId, baseExternalDeviceId, baseExternalDeviceId);
  device ??= allDevices.find((d) => d.status === 'active' && d.protocol === mobileProtocol && d.name === client.deviceName);

  if (!device) {
    try {
      requireProfileRequest(options);
      device = await createDevice(accessToken, client, locationId, baseExternalDeviceId, options);
      requireProfileRequest(options);
    } catch (error) {
      requireProfileRequest(options);
      if (isApiRequestCancelled(error)) throw error;
      const fallback = allDevices.find((d) => d.status === 'active' && d.protocol === mobileProtocol);
      if (fallback) {
        logApiDebug('createDevice failed, falling back to existing active device for testing:', fallback.name);
        device = fallback;
      } else {
        throw error;
      }
    }
  }

  requireProfileRequest(options);
  const token = await jsonRequest<{ token: string }>(`/v1/devices/${encodeURIComponent(device.id)}/config-token`, {
    method: 'POST',
    accessToken,
    headers: versionHeaders,
  });
  requireProfileRequest(options);
  const configQuery = new URLSearchParams({
    format: 'conf',
    token: token.token,
    location: locationId,
  });
  const config = await rawRequest(`/v1/devices/${encodeURIComponent(device.id)}/config?${configQuery.toString()}`, {
    accessToken,
    headers: versionHeaders,
    // Config issuance can also assign or reconcile a peer.
    retryCount: 0,
    ...(options.signal ? { signal: options.signal } : {}),
  });
  requireProfileRequest(options);
  return { device, config };
}

async function managedVpnProfile(accessToken: string, client: VpnClientDescriptor, options: PreparedTunnelOptions): Promise<PreparedTunnel> {
  const requireCurrentOperation = () => requireProfileRequest(options);
  const isCurrentProfileOperation = () => { requireCurrentOperation(); return true; };
  requireCurrentOperation();
  const startedAtMs = Date.now();
  const locationId = normalizeLocationId(options.locationId);
  const [versionHeaders, initialKeyPair, runtimeDeviceId, account] = await withRequestCancellation(() => Promise.all([
    clientVersionHeaders(), requiresManagedNativeProfile(client) ? Promise.resolve(null) : getOrCreateWireGuardKeyPair(), getOrCreateDeviceId(),
    // Start setup inside the observed aggregate. Cancellation before this
    // callback runs must not leave an eager account promise unobserved.
    requiresManagedNativeProfile(client)
      ? vpnAccountOptions(accessToken, client, locationId, options.userId, options.isCurrentSessionOperation, options.signal)
        .then(async accountOptions => ({ accountOptions, accountIdentity: await getOrCreateVpnAccountIdentity(accountOptions) }))
      : Promise.resolve(undefined),
  ]), options.signal);
  requireCurrentOperation();
  const accountOptions = account?.accountOptions, accountIdentity = account?.accountIdentity;
  const resolutionTiming = { startedAtMs, localPrepareMs: Math.max(0, Date.now() - startedAtMs), deviceLookupMs: 0, profileRequestMs: 0 };
  const requestProfile = async (deviceId: string, knownVersion?: number) => {
    const started = Date.now();
    try {
      requireCurrentOperation();
      const response = await requestManagedVpnProfile(accessToken, deviceId, locationId, routingMode, bypassRegion, versionHeaders, knownVersion);
      requireCurrentOperation();
      if (!response.revoked && response.version !== undefined && !isPositiveSafeInteger(response.version)) {
        throw new Error('Сервер вернул некорректную версию VPN-профиля.');
      }
      return response;
    } finally {
      resolutionTiming.profileRequestMs += Math.max(0, Date.now() - started);
    }
  };
  let keyPair = accountIdentity?.keyPair ?? initialKeyPair;
  const pendingAccountKeyPair = accountIdentity ? await pendingVpnAccountKeyPair(accountIdentity.keyScope, options.isCurrentSessionOperation) : undefined;
  requireCurrentOperation();
  const baseExternalDeviceId = nativeDeviceId(accountIdentity?.externalDeviceId ?? runtimeDeviceId);
  const externalDeviceId = baseExternalDeviceId;
  const routingMode = options.routingMode ?? defaultVpnRoutingMode;
  const bypassRegion = resolvedVpnBypassRegion(routingMode, options.bypassRegion);
  const routingPolicy = supportsNativeRoutingPolicy() && routingMode === 'all_except_ru'
    ? jsonRequest<{ authorization?: unknown }>(`/v1/vpn/routing-policy?region=ru&platform=${Platform.OS}&schema_version=2`, {
      accessToken, headers: versionHeaders, retryCount: 0, timeout: 5_000, suppressErrorLog: true,
      ...(options.signal ? { signal: options.signal } : {}),
    }).then(result => routingAuthorization(result.authorization)).catch(() => undefined)
    : Promise.resolve(undefined);
  let device: VpnDevice | undefined;
  let profile: NativeVPNProfileDTO | undefined;
  let revalidateCachedConfig = false;
  const cachedDevice = options.cachedDevice;
  if (accountOptions && cachedDevice?.userId && cachedDevice.userId !== accountOptions.userId) throw new Error('VPN-устройство принадлежит другому аккаунту.');
  if (!pendingAccountKeyPair && !accountIdentity?.legacyRegistrationPending && options.cachedConfig && isPositiveSafeInteger(options.knownVersion) &&
      cachedDevice && isPositiveSafeInteger(cachedDevice.keyEpoch) &&
      canRevalidateDevice(cachedDevice, cachedDevice, keyPair?.publicKey ?? '') &&
      nativeVpnDeviceForClient([cachedDevice], locationId, externalDeviceId, baseExternalDeviceId)) {
    // A cached device is only a request hint. The authorized profile response
    // must confirm its exact key identity before we can skip /v1/devices.
    const candidate = await requestProfile(cachedDevice.id, options.knownVersion)
      .catch((error: unknown) => {
        // Older servers may omit the error code for a deleted cache hint.
        // Keep the existing one full lookup before deciding on legacy fallback.
        const responseError = error instanceof LegacyProfileFallbackError ? error.originalError : error;
        if (responseError instanceof ApiRequestError && responseError.status === 404) return null;
        throw error;
      });
    if (candidate?.revoked) throw new Error('Устройство отключено администратором.');
    if (candidate && candidate.device_id === cachedDevice.id && candidate.client_public_key === keyPair?.publicKey &&
        candidate.client_key_epoch === cachedDevice.keyEpoch &&
        (!candidate.unchanged || (!candidate.rotation_required && candidate.version === options.knownVersion))) {
      device = cachedDevice;
      profile = candidate;
      revalidateCachedConfig = true;
    }
  }
  if (!device || !profile) {
    // Older servers and changed/replaced identities retain the full lookup and
    // transactional key-recovery path. Unconditional repair always enters here.
    const lookupStarted = Date.now();
    const allDevices = accountIdentity?.ownedDevices ?? await vpnDevices(accessToken, options.signal);
    requireCurrentOperation();
    if (accountOptions && allDevices.some(item => item.userId && item.userId !== accountOptions.userId)) throw new Error('Список VPN-устройств принадлежит другому аккаунту.');
    resolutionTiming.deviceLookupMs = Math.max(0, Date.now() - lookupStarted);
    device = nativeVpnDeviceForClient(allDevices, locationId, externalDeviceId, baseExternalDeviceId);
    if (accountOptions && device && !isVpnAccountDeviceId(device.id)) {
      throw new Error('Не удалось подтвердить VPN-устройство этого аккаунта.');
    }
    if (!device || accountIdentity?.legacyRegistrationPending) {
      // Registration/key confirmation is owned by the session transaction.
      // A cancelled borrower must not interrupt its durable receipt or key.
      device = await getOrCreateNativeDeviceRegistration(
        accessToken,
        externalDeviceId,
        () => accountOptions && accountIdentity
          ? registerAccountNativeDevice(accessToken, client, locationId, accountOptions, allDevices)
          : registerNativeDevice(accessToken, client, keyPair, locationId, externalDeviceId, options.isCurrentSessionOperation),
      );
      requireCurrentOperation();
      if (accountOptions) {
        keyPair = (await getOrCreateVpnAccountIdentity(accountOptions)).keyPair;
        requireCurrentOperation();
      }
    }
    if (accountOptions && device.userId && device.userId !== accountOptions.userId) throw new Error('VPN-устройство принадлежит другому аккаунту.');
    if (accountOptions && (pendingAccountKeyPair || !device.publicKey)) {
      // This recovery belongs to the profile request. Reuse the account
      // owner's fences for both session and caller cancellation, while the
      // shared registration above retains its independent durable receipt.
      const recoveryOptions: VpnAccountIdentityOptions = {
        ...accountOptions,
        isCurrentSessionOperation: isCurrentProfileOperation,
      };
      const recovered = await withVpnAccountDevice(accessToken, device.id, recoveryOptions, async (currentDevice, identity) => {
        const pending = await pendingVpnAccountKeyPair(identity.keyScope, recoveryOptions.isCurrentSessionOperation);
        requireCurrentOperation();
        if (!pending) {
          if (currentDevice.publicKey || identity.confirmedKeyDeviceId === undefined) {
            return { device: currentDevice, keyPair: identity.keyPair };
          }
          if (identity.legacyRegistrationPending || !isAccountKeyRecoveryDevice(currentDevice, recoveryOptions) || !isPositiveSafeInteger(currentDevice.keyEpoch)) {
            throw new VpnProfileKeyChangedError();
          }
          if (identity.confirmedKeyDeviceId === currentDevice.id && currentDevice.keyEpoch < (identity.keyPair.keyEpoch ?? 1)) {
            throw new VpnProfileKeyChangedError();
          }
          // The receipt selects known material; an omitted list field still
          // needs a fresh noncreating proof, including at the same counter.
          const confirmed = await confirmVpnAccountDeviceKey(accessToken, currentDevice, identity, identity.keyPair.publicKey, { client, options: recoveryOptions });
          const keyPair = { ...identity.keyPair, keyEpoch: currentDevice.keyEpoch };
          await saveVpnAccountKeyPair(identity.keyScope, keyPair, recoveryOptions.isCurrentSessionOperation, currentDevice.id);
          return { device: confirmed, keyPair };
        }
        const result = await rotateVpnAccountDeviceKey(accessToken, currentDevice, identity, pending, recoveryOptions.isCurrentSessionOperation, { client, options: recoveryOptions });
        if (!identity.legacyRegistrationPending) await clearPendingVpnAccountKeyPair(identity.keyScope, recoveryOptions.isCurrentSessionOperation);
        return result;
      });
      requireCurrentOperation();
      device = recovered.device;
      keyPair = recovered.keyPair;
    }
    if (deviceNeedsLocalKeySync(device, keyPair)) {
      try {
        device = await syncManagedVpnKey(accessToken, device.id, keyPair);
        requireCurrentOperation();
      } catch (error) {
        requireCurrentOperation();
        if (!isKeyEpochMismatchError(error)) {
          throw error;
        }
        // Web authorization can create a placeholder before the native key.
        // Recover through the normal transactional rotation to the next epoch.
        device = await rotateManagedVpnKey(accessToken, device.id, device.keyEpoch, isCurrentProfileOperation, accountOptions?.userId);
        requireCurrentOperation();
        keyPair = accountOptions ? (await getOrCreateVpnAccountIdentity(accountOptions)).keyPair : await getOrCreateWireGuardKeyPair();
        requireCurrentOperation();
      }
    }
    revalidateCachedConfig = Boolean(options.cachedConfig) && isPositiveSafeInteger(options.knownVersion) && canRevalidateDevice(options.cachedDevice, device, keyPair?.publicKey ?? '');
    profile = await requestProfile(device.id, revalidateCachedConfig ? options.knownVersion : undefined);
  }
  if (profile.revoked) {
    throw new Error('Устройство отключено администратором.');
  }
  if (accountOptions) {
    const current = await getOrCreateVpnAccountIdentity(accountOptions);
    requireCurrentOperation();
    if (current.keyPair.publicKey !== keyPair?.publicKey || current.keyPair.privateKey !== keyPair?.privateKey || current.keyPair.keyEpoch !== keyPair?.keyEpoch) throw new SessionOperationSupersededError();
  }
  if ((profile.device_id !== undefined && profile.device_id !== device.id) ||
      (profile.client_public_key !== undefined && profile.client_public_key !== keyPair?.publicKey) ||
      (profile.client_key_epoch !== undefined && (!Number.isSafeInteger(profile.client_key_epoch) || profile.client_key_epoch < 1 || profile.client_key_epoch < (device.keyEpoch ?? 0)))) throw new Error('Сервер вернул профиль другого ключа VPN.');
  const authorization = await routingPolicy;
  requireCurrentOperation();
  if (profile.unchanged) {
    if (!revalidateCachedConfig || !options.cachedConfig) {
      throw new Error('Управляемый VPN-профиль не изменился, но локальный cache пуст.');
    }
    if (profile.version !== undefined && profile.version !== options.knownVersion) {
      throw new Error('Сервер вернул несовпадающую версию VPN-профиля.');
    }
    return {
      config: options.cachedConfig,
      routingParameters: supportsNativeRoutingPolicy() ? nativeRoutingParameters(options.cachedConfig, routingMode, authorization) : undefined,
      resolutionTiming,
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
    resolutionTiming,
    config,
    routingParameters: supportsNativeRoutingPolicy() ? nativeRoutingParameters(config, routingMode, authorization) : undefined,
    device: {
      ...device,
      keyEpoch: profile.client_key_epoch ?? device.keyEpoch,
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

function requestManagedVpnProfile(
  accessToken: string, deviceId: string, locationId: string, routingMode: string,
  bypassRegion: string | undefined, headers: Record<string, string>, knownVersion?: number,
): Promise<NativeVPNProfileDTO> {
  const routed = supportsNativeRoutingPolicy();
  // Destination policy belongs to the native router. Its encrypted transport
  // must include RU even when an older server ignores the v2 capability. Do not
  // let a v1 unchanged acknowledgement resurrect a cached split AllowedIPs set.
  const query = withManagedProfileAWGCapability(new URLSearchParams({device_id: deviceId, location: locationId, routing_mode: routed ? 'full_tunnel' : routingMode}));
  if (routed) query.set('routing_policy_version', '2');
  if (!routed && bypassRegion) query.set('bypass_region', bypassRegion);
  if (!routed && isPositiveSafeInteger(knownVersion)) query.set('known_version', String(knownVersion));
  // Profile GET can assign a node or reconcile its peer. Once dispatched, it
  // owns the queue slot through completion, like registration/key writes. Only
  // the caller wait is cancellable; guard before/after this operation instead.
  return jsonRequest<NativeVPNProfileDTO>(`/v1/vpn/profile?${query.toString()}`, {accessToken, headers, suppressErrorLog:true, retryCount:0})
    .catch((error: unknown) => {
      // Coded API errors (including current owned-device404) remain authoritative.
      // A failure from setup, registration or another route cannot reach here.
      const legacyMessage = error instanceof ApiRequestError ? error.message.trim().toLowerCase() : '';
      const unsupported = error instanceof ApiRequestError && !error.code && (
        (error.status === 404 && legacyMessage === '404 page not found') ||
        (error.status === 405 && legacyMessage === 'method not allowed') ||
        (error.status === 501 && legacyMessage === 'not implemented')
      );
      if (unsupported) throw new LegacyProfileFallbackError(error);
      throw error;
    });
}

export async function vpnDevices(accessToken: string, signal?: AbortSignal): Promise<VpnDevice[]> {
  const response = await jsonRequest<DeviceDTO[]>('/v1/devices', { accessToken, ...(signal ? { signal } : {}) });
  return response.map(parseDevice);
}

export async function vpnLocations(accessToken: string, signal?: AbortSignal): Promise<VpnLocation[]> {
  const response = await jsonRequest<LocationDTO[]>('/v1/locations', { accessToken, suppressErrorLog: true, ...(signal ? { signal } : {}) });
  return normalizeLocationCatalog(response);
}

export async function vpnDeviceUsage(accessToken: string, signal?: AbortSignal): Promise<VpnDeviceUsage[]> {
  return (await vpnDeviceUsageSnapshot(accessToken, undefined, signal)).usage;
}

export async function vpnDeviceUsageSnapshot(accessToken: string, deviceId?: string, signal?: AbortSignal): Promise<VpnDeviceUsageSnapshot> {
  const query = new URLSearchParams();
  if (deviceId?.trim()) {
    query.set('device_id', deviceId.trim());
  }
  const path = query.size > 0 ? `/v1/devices/usage?${query.toString()}` : '/v1/devices/usage';
  const response = await jsonRequest<DeviceUsageResponseDTO>(path, { accessToken, suppressErrorLog: true, ...(signal ? { signal } : {}) });
  return {
    usage: (response.usage ?? []).map(parseDeviceUsage),
    currentDeviceId: response.current_device_id || undefined,
    currentDeviceBy: response.current_device_by || undefined,
    trafficQuota: response.traffic_quota ? parseDeviceTrafficQuota(response.traffic_quota) : undefined,
  };
}

export async function vpnResiliencePolicy(accessToken: string, signal?: AbortSignal): Promise<unknown> {
  return jsonRequest<unknown>('/v1/resilience/policy', {
    accessToken,
    ...(signal ? { signal } : {}),
    retryCount: 0,
    suppressErrorLog: true,
    timeout: 2_500,
  });
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
    } satisfies NativeVPNConnectionEventInput,
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
    } satisfies NativeVPNConnectionEventInput,
  });
}

export async function submitClientDiagnostics(accessToken: string, report: ClientDiagnosticsReportInput, timeout = 12_000): Promise<{ id: string }> {
  return jsonRequest<{ id: string }>('/v1/diagnostics/client', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
    timeout,
    body: clientDiagnosticsRequestBody(report),
  });
}

export async function registerDevicePushToken(accessToken: string, deviceId: string, push: { provider: string; token: string }): Promise<VpnDevice> {
  const response = await jsonRequest<RegisterDevicePushTokenResultDTO>(devicePushTokenPath, {
    method: 'POST',
    accessToken,
    body: {
      device_id: deviceId,
      provider: push.provider,
      token: push.token,
    } satisfies NativeVPNPushTokenInput,
  });
  return parseDevice(response.device || ({} as DeviceDTO));
}

export async function fetchStagedDevicePSKProfile(accessToken: string, currentProfile: VpnProfile, userId?: string, isCurrentSessionOperation?: () => boolean): Promise<StagedDevicePSKProfile> {
  requireCurrentSession(isCurrentSessionOperation);
  const device = currentProfile.device;
  if (!device?.id) {
    throw new Error('VPN-устройство для staged PSK профиля не найдено.');
  }
  const query = new URLSearchParams({ device_id: device.id, platform: currentVpnClient().platform });
  const response = await jsonRequest<StagedDevicePSKProfileDTO>(`/v1/vpn/psk-rotations/current?${query.toString()}`, {
    accessToken,
    headers: await clientVersionHeaders(),
    suppressErrorLog: true,
    // Fetching staged material advances its durable state. An uncertain
    // response belongs to explicit recovery, even though this is a GET.
    retryCount: 0,
  });
  requireCurrentSession(isCurrentSessionOperation);
  if (response.activate !== false || !isPositiveSafeInteger(response.profile_version) || !isPositiveSafeInteger(response.profile.version) || response.profile_version !== response.profile.version) {
    throw new Error('Сервер вернул некорректный staged AmneziaWG профиль.');
  }
  const client = currentVpnClient();
  const identity = requiresManagedNativeProfile(client)
    ? await getOrCreateVpnAccountIdentity(await vpnAccountOptions(accessToken, client, currentProfile.locationId, userId, isCurrentSessionOperation))
    : undefined;
  requireCurrentSession(isCurrentSessionOperation);
  const keyPair = identity?.keyPair ?? await getOrCreateWireGuardKeyPair();
  requireCurrentSession(isCurrentSessionOperation);
  if ((response.profile.device_id !== undefined && response.profile.device_id !== device.id) ||
      (response.profile.client_public_key !== undefined && response.profile.client_public_key !== keyPair?.publicKey) ||
      (response.profile.client_key_epoch !== undefined && (!Number.isSafeInteger(response.profile.client_key_epoch) || response.profile.client_key_epoch < 1 || response.profile.client_key_epoch < (device.keyEpoch ?? 0)))) throw new Error('Сервер вернул staged профиль другого ключа VPN.');
  const config = response.profile.config || managedProfileConfig(response.profile, keyPair);
  return {
    rotationId: response.rotation_id,
    deviceId: device.id,
    profileVersion: response.profile_version,
    profileDigest: response.profile_digest,
    profile: {
      ...currentProfile,
      cacheSavedAtMs: Date.now(),
      config,
      device: {
        ...device,
        keyEpoch: response.profile.client_key_epoch ?? device.keyEpoch,
        assignedIpv4: response.profile.assigned_ipv4 || device.assignedIpv4,
        endpoint: managedProfileEndpoint(response.profile) || device.endpoint,
        protocol: response.profile.protocol || device.protocol,
      },
      profileVersion: response.profile_version,
      rotationRequired: false,
      source: 'api',
    },
  };
}

export async function acknowledgeStagedDevicePSKProfile(
  accessToken: string,
  staged: StagedDevicePSKProfile,
): Promise<void> {
  const response = await jsonRequest<AcknowledgeStagedDevicePSKProfileResultDTO>(
    `/v1/vpn/psk-rotations/${encodeURIComponent(staged.rotationId)}/ack`,
    {
      method: 'POST',
      accessToken,
      idempotencyKey: `psk-stage-ack-${staged.rotationId}-${staged.profileVersion}`,
      body: {
        device_id: staged.deviceId,
        profile_version: staged.profileVersion,
        profile_digest: staged.profileDigest,
      } satisfies NativeVPNPSKRotationACKInput,
    },
  );
  if (!response.accepted || response.rotation_id !== staged.rotationId) {
    throw new Error('Сервер не подтвердил staged AmneziaWG профиль.');
  }
}

type AccountKeyRotationResult = { device: VpnDevice; keyPair: WireGuardKeyPair };

export class VpnProfileKeyChangedError extends Error {
  readonly code = 'VPN_PROFILE_KEY_CHANGED';
  constructor() { super('Ключ VPN-профиля изменился. Обновите профиль перед подключением.'); }
}

type ProfileKeyAdmissionOptions = Pick<PreparedTunnelOptions, 'userId' | 'isCurrentSessionOperation' | 'signal'>;

export async function withCurrentVpnProfileKey<T>(accessToken: string, profile: VpnProfile, operation: () => Promise<T>, options: ProfileKeyAdmissionOptions = {}): Promise<T> {
  requireProfileRequest(options);
  const client = currentVpnClient();
  if (!requiresManagedNativeProfile(client)) return operation();
  if (!accessToken.trim()) throw new Error('Сначала войдите в аккаунт.');
  const accountOptions = { ...await vpnAccountOptions(accessToken, client, profile.locationId, options.userId, options.isCurrentSessionOperation, options.signal),
    // Admission may read an existing mapping; only preparation may create or
    // migrate one. resolveAccountIdentity calls this before allocating a key.
    loadOwnedDevices: async (): Promise<VpnDevice[]> => { throw new VpnProfileKeyChangedError(); },
  };
  return withVpnAccountIdentity(accountOptions, async identity => {
    const pending = await pendingVpnAccountKeyPair(identity.keyScope, options.isCurrentSessionOperation);
    requireProfileRequest(options);
    const device = profile.device;
    const externalDeviceId = nativeDeviceId(identity.externalDeviceId);
    const privateKeys = Array.from(profile.config.matchAll(/^[ \t]*PrivateKey[ \t]*=[ \t]*([^\r\n]*)\r?$/gim), match => match[1].trim());
    if (pending || identity.legacyRegistrationPending || !device ||
        (device.userId && device.userId !== accountOptions.userId) ||
        (identity.confirmedKeyDeviceId !== undefined && device.id !== identity.confirmedKeyDeviceId) ||
        !nativeVpnDeviceForClient([device], profile.locationId, externalDeviceId, externalDeviceId) ||
        (device.publicKey !== undefined && device.publicKey !== identity.keyPair.publicKey) ||
        (device.keyEpoch !== undefined && (!isNonnegativeSafeInteger(device.keyEpoch) || (device.keyEpoch > 0 && device.keyEpoch < (identity.keyPair.keyEpoch ?? 1)))) ||
        privateKeys.length !== 1 || privateKeys[0] !== identity.keyPair.privateKey) throw new VpnProfileKeyChangedError();
    // Rotation and native dispatch share the account owner. Keep it until the
    // real native promise settles, even when its caller stops waiting.
    return operation();
  });
}

export async function vpnProfileKeyIsCurrent(accessToken: string, profile: VpnProfile, options: ProfileKeyAdmissionOptions = {}): Promise<boolean> {
  try { return await withCurrentVpnProfileKey(accessToken, profile, async () => true, options); }
  catch (error) { if (error instanceof VpnProfileKeyChangedError) return false; throw error; }
}

async function withVpnAccountDevice<T>(accessToken: string, deviceId: string, options: VpnAccountIdentityOptions, use: (device: VpnDevice, identity: VpnAccountIdentity) => Promise<T>): Promise<T> {
  return withVpnAccountIdentity(options, async identity => {
    const device = (await vpnDevices(accessToken)).find(row => row.id === deviceId);
    requireCurrentSession(options.isCurrentSessionOperation);
    if (!device || (device.userId && device.userId !== options.userId)) throw new Error('Не удалось подтвердить VPN-устройство этого аккаунта.');
    return use(device, identity);
  });
}

export async function rotateManagedVpnKey(accessToken: string, deviceId: string, serverCurrentEpoch?: number, isCurrentSessionOperation?: () => boolean, userId?: string): Promise<VpnDevice> {
  requireCurrentSession(isCurrentSessionOperation);
  // Account setup may persist keys. Reject an unusable server identity first.
  if (serverCurrentEpoch !== undefined) nextManagedKeyEpoch(undefined, serverCurrentEpoch);
  const client = currentVpnClient();
  const accountOptions = requiresManagedNativeProfile(client)
    ? await vpnAccountOptions(accessToken, client, undefined, userId, isCurrentSessionOperation)
    : undefined;
  if (accountOptions) {
    return withVpnAccountDevice(accessToken, deviceId, accountOptions, async (device, identity) => {
      const pending = await pendingVpnAccountKeyPair(identity.keyScope, isCurrentSessionOperation);
      requireCurrentSession(isCurrentSessionOperation);
      // A stale second caller must not generate another key after the first
      // owner has completed. Pending material is reconciled instead.
      if (!pending && serverCurrentEpoch !== undefined && device.keyEpoch !== undefined && device.keyEpoch !== serverCurrentEpoch) throw new SessionOperationSupersededError();
      const result = await rotateVpnAccountDeviceKey(accessToken, device.keyEpoch === undefined ? { ...device, keyEpoch: serverCurrentEpoch } : device, identity, pending, isCurrentSessionOperation, { client, options: accountOptions });
      if (!identity.legacyRegistrationPending) await clearPendingVpnAccountKeyPair(identity.keyScope, isCurrentSessionOperation);
      return result.device;
    });
  }
  return rotateUnscopedVpnKey(accessToken, deviceId, serverCurrentEpoch, isCurrentSessionOperation);
}

async function rotateUnscopedVpnKey(accessToken: string, deviceId: string, serverCurrentEpoch?: number, isCurrentSessionOperation?: () => boolean): Promise<VpnDevice> {
  requireCurrentSession(isCurrentSessionOperation);
  const generatedKeyPair = await generateWireGuardKeyPair({ independentEpoch: serverCurrentEpoch !== undefined });
  requireCurrentSession(isCurrentSessionOperation);
  if (!generatedKeyPair?.publicKey) {
    throw new Error('Локальный WireGuard ключ недоступен.');
  }
  const keyPair = {
    ...generatedKeyPair,
    keyEpoch: nextManagedKeyEpoch(generatedKeyPair.keyEpoch, serverCurrentEpoch),
  };
  return commitManagedVpnKey(accessToken, deviceId, keyPair, isCurrentSessionOperation);
}

async function commitManagedVpnKey(accessToken: string, deviceId: string, keyPair: WireGuardKeyPair, isCurrentSessionOperation?: () => boolean, identity?: VpnAccountIdentity): Promise<VpnDevice> {
  requireCurrentSession(isCurrentSessionOperation);
  const response = await jsonRequest<{ device: DeviceDTO }>('/v1/vpn/rotate-key', {
    method: 'POST',
    accessToken,
    idempotencyKey: `native-rotate-key-${deviceId}-${keyPair.keyEpoch ?? Date.now()}`,
    retryCount: 0,
    body: {
      device_id: deviceId,
      public_key: keyPair.publicKey,
      key_epoch: keyPair.keyEpoch ?? 1,
    } satisfies NativeVPNKeyRotationInput,
  });
  requireCurrentSession(isCurrentSessionOperation);
  if (response.device.id !== deviceId || response.device.public_key !== keyPair.publicKey || response.device.psk_epoch !== keyPair.keyEpoch) throw new Error('Сервер не подтвердил новый ключ VPN.');
  if (identity) await saveVpnAccountKeyPair(identity.keyScope, keyPair, isCurrentSessionOperation, deviceId);
  else await replaceWireGuardKeyPair(keyPair);
  requireCurrentSession(isCurrentSessionOperation);
  return parseDevice(response.device);
}

type AccountKeyIntent = NonNullable<Awaited<ReturnType<typeof pendingVpnAccountKeyPair>>>;
type AccountKeyRecovery = { client: VpnClientDescriptor; options: VpnAccountIdentityOptions };

function isVpnAccountDeviceId(value: unknown): value is string {
  return typeof value === 'string' && /^[a-zA-Z0-9._-]{1,160}$/.test(value);
}

function requirePendingKeyOwner(identity: VpnAccountIdentity, pending: AccountKeyIntent | undefined): void {
  if (pending && identity.keyPair.publicKey !== pending.publicKey) {
    const ownsBase = pending.ownerPublicKey !== undefined
      ? identity.keyPair.publicKey === pending.ownerPublicKey
      : (identity.keyPair.keyEpoch ?? 0) < (pending.keyEpoch ?? 1);
    if (!ownsBase) throw new Error('Подтверждённый локальный ключ изменился после подготовки ротации VPN.');
  }
}

function isAccountKeyRecoveryDevice(device: VpnDevice, options: VpnAccountIdentityOptions): boolean {
  return device.userId === options.userId && device.platform === options.platform && device.status === 'active' &&
    device.protocol === mobileProtocol && device.provisioningMode === 'managed_native' && device.clientKeyOwnership === 'client';
}

async function confirmVpnAccountDeviceKey(accessToken: string, device: VpnDevice, identity: VpnAccountIdentity, publicKey: string, recovery: AccountKeyRecovery): Promise<VpnDevice> {
  const { client, options } = recovery;
  if (!isPositiveSafeInteger(device.keyEpoch)) throw new Error('Не удалось подтвердить версию нового VPN-устройства.');
  const confirmed = await registerNativeDevice(accessToken, client, { publicKey, keyEpoch: device.keyEpoch }, options.locationId,
    identity.externalDeviceId, options.isCurrentSessionOperation, identity.installationId, options.userId, true, { deviceId: device.id });
  requireCurrentSession(options.isCurrentSessionOperation);
  if (confirmed.id !== device.id || !isAccountKeyRecoveryDevice(confirmed, options) ||
      confirmed.publicKey !== publicKey || confirmed.keyEpoch !== device.keyEpoch) {
    throw new Error('Сервер не подтвердил замену VPN-устройства.');
  }
  return confirmed;
}

async function reconcilePendingKeyBase(accessToken: string, device: VpnDevice, identity: VpnAccountIdentity, pending: AccountKeyIntent, recovery: AccountKeyRecovery | undefined): Promise<{ device: VpnDevice; pending: AccountKeyIntent }> {
  const basePublicKey = pending.basePublicKey || identity.keyPair.publicKey;
  if (!recovery || pending.deviceId !== device.id || pending.deviceId !== (identity.confirmedDeviceId ?? identity.legacyOwnedDeviceId) ||
      !isAccountKeyRecoveryDevice(device, recovery.options) || !isPositiveSafeInteger(device.keyEpoch) ||
      (device.publicKey && device.publicKey !== pending.publicKey && device.publicKey !== basePublicKey)) {
    throw new Error('Не удалось подтвердить исходный серверный ключ незавершённой ротации VPN.');
  }
  let confirmed: VpnDevice;
  try {
    // A lost rotation response may already have installed the durable pair.
    // These signed requests only read the existing binding/key tuple.
    confirmed = await confirmVpnAccountDeviceKey(accessToken, device, identity, pending.publicKey, recovery);
  } catch (error) {
    requireCurrentSession(recovery.options.isCurrentSessionOperation);
    // Only the established, definitive read-only conflict permits a second
    // proof. Network/unknown results and malformed receipts retain the intent.
    if (!(error instanceof ApiRequestError) || error.status !== 409 || error.code !== 'conflict' ||
        error.message !== 'device_rebind_required' || basePublicKey === pending.publicKey) throw error;
    confirmed = await confirmVpnAccountDeviceKey(accessToken, device, identity, basePublicKey, recovery);
  }
  return { device: confirmed, pending: { ...pending,
    basePublicKey: confirmed.publicKey === pending.publicKey ? pending.basePublicKey : confirmed.publicKey } };
}

async function reconcilePendingKeyTarget(accessToken: string, device: VpnDevice, identity: VpnAccountIdentity, pending: AccountKeyIntent, recovery: AccountKeyRecovery | undefined): Promise<{ device: VpnDevice; pending: AccountKeyIntent }> {
  if (!recovery || pending.deviceId !== (identity.confirmedDeviceId ?? identity.legacyOwnedDeviceId)) {
    // TODO(account-key-recovery): older orphan journals without a recorded or
    // migrated source device need an explicit owner-confirmed recovery flow.
    throw new Error('Незавершённая ротация относится к другому VPN-устройству.');
  }
  const { options } = recovery;
  const owned = await vpnDevices(accessToken);
  requireCurrentSession(options.isCurrentSessionOperation);
  // A still-active target remains the owner of its original intent. Account
  // membership alone cannot transfer that intent to another installation.
  if (owned.some(row => row.userId && row.userId !== options.userId) || owned.some(row => row.id === pending.deviceId && row.status === 'active')) {
    throw new Error('Не удалось подтвердить замену прежнего VPN-устройства.');
  }
  const replacement = owned.find(row => row.id === device.id);
  if (!replacement || !isAccountKeyRecoveryDevice(replacement, options) ||
      !isPositiveSafeInteger(replacement.keyEpoch) ||
      (replacement.publicKey !== identity.keyPair.publicKey && replacement.publicKey !== pending.publicKey)) {
    throw new Error('Не удалось подтвердить ключ нового VPN-устройства.');
  }
  const requestPair = replacement.publicKey === pending.publicKey ? pending : identity.keyPair;
  if (replacement.publicKey === pending.publicKey && replacement.keyEpoch < (pending.keyEpoch ?? 1)) {
    throw new Error('Не удалось подтвердить версию нового VPN-устройства.');
  }
  const confirmed = await confirmVpnAccountDeviceKey(accessToken, replacement, identity, requestPair.publicKey, recovery);
  const transferred = { ...pending, deviceId: confirmed.id,
    basePublicKey: confirmed.publicKey === pending.publicKey ? pending.basePublicKey : confirmed.publicKey,
    ownerPublicKey: pending.ownerPublicKey ?? identity.keyPair.publicKey,
    keyEpoch: confirmed.publicKey === pending.publicKey ? pending.keyEpoch : nextManagedKeyEpoch(pending.keyEpoch, confirmed.keyEpoch) };
  // Persist the proven target before rotation or active-key promotion. A lost
  // registration reply leaves the original journal and active pair intact.
  await savePendingVpnAccountKeyPair(identity.keyScope, transferred, options.isCurrentSessionOperation);
  await rememberVpnAccountDevice(options, identity, confirmed.id);
  return { device: confirmed, pending: transferred };
}

async function rotateVpnAccountDeviceKey(accessToken: string, device: VpnDevice, identity: VpnAccountIdentity, pending: Awaited<ReturnType<typeof pendingVpnAccountKeyPair>>, isCurrentSessionOperation?: () => boolean, recovery?: AccountKeyRecovery): Promise<AccountKeyRotationResult> {
  requireCurrentSession(isCurrentSessionOperation);
  if (!isVpnAccountDeviceId(device.id)) throw new Error('Не удалось подтвердить VPN-устройство этого аккаунта.');
  requirePendingKeyOwner(identity, pending);
  if (pending?.deviceId && pending.deviceId !== device.id) {
    ({ device, pending } = await reconcilePendingKeyTarget(accessToken, device, identity, pending, recovery));
  }
  if (pending && device.publicKey !== pending.publicKey && (
    (pending.basePublicKey === '' && (Boolean(device.publicKey) || (device.keyEpoch !== undefined && device.keyEpoch + 1 !== pending.keyEpoch))) ||
    (pending.basePublicKey !== '' && !device.publicKey)
  )) {
    ({ device, pending } = await reconcilePendingKeyBase(accessToken, device, identity, pending, recovery));
  }
  if (pending && device.publicKey === pending.publicKey && Number.isSafeInteger(device.keyEpoch) && (device.keyEpoch ?? 0) >= (pending.keyEpoch ?? 1)) {
    // A lost rotation response must not discard its only private key. The
    // signed, owner-filtered response confirms this exact durable intent.
    const confirmed = { ...pending, keyEpoch: device.keyEpoch };
    await saveVpnAccountKeyPair(identity.keyScope, confirmed, isCurrentSessionOperation, device.id);
    return { device, keyPair: confirmed };
  }
  const boundIntent = pending?.deviceId && pending.basePublicKey !== undefined && pending.ownerPublicKey !== undefined;
  // A target-only journal can be upgraded only while the confirmed local pair
  // is still older and matches the owned server row. It cannot elect a newer
  // local owner as the base of an earlier intent.
  const olderTargetIntent = pending?.deviceId && pending.basePublicKey === undefined && pending.ownerPublicKey === undefined &&
    (identity.keyPair.keyEpoch ?? 0) < (pending.keyEpoch ?? 1) && device.publicKey === identity.keyPair.publicKey;
  if (pending && ((!boundIntent && !olderTargetIntent && !identity.legacyRegistrationPending) || (device.publicKey ?? '') !== (pending.basePublicKey ?? identity.keyPair.publicKey))) {
    throw new Error('Не удалось подтвердить прежний ключ незавершённой ротации VPN.');
  }
  if (!pending) {
    pending = await generateWireGuardKeyPair({ independentEpoch: device.keyEpoch !== undefined }) ?? undefined;
    requireCurrentSession(isCurrentSessionOperation);
    if (!pending) throw new Error('Локальный WireGuard ключ недоступен.');
    if (recovery) identity = await rememberVpnAccountDevice(recovery.options, identity, device.id);
  }
  pending = {
    ...pending,
    deviceId: device.id,
    basePublicKey: pending.basePublicKey ?? device.publicKey ?? '',
    ownerPublicKey: pending.ownerPublicKey ?? identity.keyPair.publicKey,
    keyEpoch: nextManagedKeyEpoch(pending.keyEpoch, device.keyEpoch),
  };
  // Keep the last confirmed active pair until the server accepts the next one.
  // The journal is durable before POST and reuses the same key after restart.
  await savePendingVpnAccountKeyPair(identity.keyScope, pending, isCurrentSessionOperation);
  const rotated = await commitManagedVpnKey(accessToken, device.id, pending, isCurrentSessionOperation, identity);
  return { device: rotated, keyPair: pending };
}

async function vpnAccountOptions(accessToken: string, client: VpnClientDescriptor, locationId?: string, userId?: string, isCurrentSessionOperation?: () => boolean, signal?: AbortSignal): Promise<VpnAccountIdentityOptions> {
  requireCurrentSession(isCurrentSessionOperation);
  requireRequestActive(signal);
  const accountId = userId?.trim() || (await me(accessToken, signal)).id;
  requireRequestActive(signal);
  requireCurrentSession(isCurrentSessionOperation);
  const platform = client.platform === 'ios' || Platform.OS === 'ios' ? 'ios' : 'android';
  return { userId: accountId, platform, locationId: locationId?.trim() || '', loadOwnedDevices: () => vpnDevices(accessToken), isCurrentSessionOperation };
}

function requireProfileRequest(options: PreparedTunnelOptions): void {
  requireCurrentSession(options.isCurrentSessionOperation);
  requireRequestActive(options.signal);
}

function requireCurrentSession(isCurrentSessionOperation?: () => boolean): void {
  if (isCurrentSessionOperation && !isCurrentSessionOperation()) {
    throw new SessionOperationSupersededError();
  }
}

async function syncManagedVpnKey(accessToken: string, deviceId: string, keyPair: WireGuardKeyPair): Promise<VpnDevice> {
  const response = await jsonRequest<{ device: DeviceDTO }>('/v1/vpn/rotate-key', {
    method: 'POST',
    accessToken,
    idempotencyKey: `native-sync-key-${deviceId}-${keyPair.keyEpoch ?? 1}-${keyPair.publicKey}`,
    body: {
      device_id: deviceId,
      public_key: keyPair.publicKey,
      key_epoch: keyPair.keyEpoch ?? 1,
    } satisfies NativeVPNKeyRotationInput,
  });
  return parseDevice(response.device);
}

async function createDevice(accessToken: string, client: VpnClientDescriptor, locationId: string | undefined, externalDeviceId: string, options: PreparedTunnelOptions = {}): Promise<VpnDevice> {
  const location = normalizeLocationId(locationId);
  requireProfileRequest(options);
  const appInfo = await withRequestCancellation(getAppInfo, options.signal);
  requireProfileRequest(options);
  const request = buildCreateDeviceRequest(client, location, externalDeviceId, appInfo);
  const response = await jsonRequest<{ device: DeviceDTO }>('/v1/devices', {
    method: 'POST',
    accessToken,
    idempotencyKey: request.idempotencyKey,
    body: request.body,
  });
  return parseDevice(response.device);
}

async function registerAccountNativeDevice(accessToken: string, client: VpnClientDescriptor, locationId: string, options: VpnAccountIdentityOptions, ownedDevices: VpnDevice[]): Promise<VpnDevice> {
  const register = async (scope: VpnAccountIdentity) => {
    let requestPair = scope.keyPair;
    let pendingDeviceId: string | undefined;
    if (scope.legacyRegistrationPending) {
      const pending = await pendingVpnAccountKeyPair(scope.keyScope, options.isCurrentSessionOperation);
      const live = nativeVpnDeviceForClient(ownedDevices, locationId, scope.externalDeviceId, scope.externalDeviceId);
      const compatible = live && (!live.userId || live.userId === options.userId) &&
        (!live.platform || live.platform === options.platform) &&
        (!live.provisioningMode || live.provisioningMode === 'managed_native') &&
        (!live.clientKeyOwnership || live.clientKeyOwnership === 'client') &&
        (live.provisioningMode === 'managed_native' || live.clientKeyOwnership === 'client') &&
        Number.isSafeInteger(live.keyEpoch) && (live.keyEpoch ?? 0) > 0;
      if (compatible) {
        if (pending && live.publicKey === pending.publicKey) {
          // Indexed creation-header replay checks the current public key and
          // server PSK epoch. Use the journal only as signed request intent;
          // the active private pair remains unchanged until server proof.
          requestPair = { ...pending, keyEpoch: live.keyEpoch };
          pendingDeviceId = live.id;
        } else if (live.publicKey === requestPair.publicKey) requestPair = { ...requestPair, keyEpoch: live.keyEpoch };
      }
    }
    const registered = await registerNativeDevice(accessToken, client, requestPair, locationId, scope.externalDeviceId, options.isCurrentSessionOperation, scope.installationId, options.userId, Boolean(scope.legacyRegistrationPending));
    if (pendingDeviceId && registered.id !== pendingDeviceId) throw new Error('Сервер подтвердил другое VPN-устройство.');
    return registered;
  };
  return withVpnAccountIdentity(options, async current => {
    let scope = current;
    let device: VpnDevice;
    try { device = await register(scope); }
    catch (error) {
      requireCurrentSession(options.isCurrentSessionOperation);
      const foreignRows = ownedDevices.some(item => item.userId && item.userId !== options.userId);
      if (!(error instanceof ApiRequestError) || error.status !== 409 || error.code !== 'conflict' || error.message !== 'device_rebind_required' ||
          scope.installationId !== scope.externalDeviceId || !scope.legacyOwnedDeviceId || foreignRows) throw error;
      // Keep B's own external row and A's binding. The durable pending flag
      // retries signed confirmation and key separation after a lost response.
      scope = await renewVpnAccountInstallation(options, scope);
      device = await register(scope);
    }
    requireCurrentSession(options.isCurrentSessionOperation);
    if (device.userId && device.userId !== options.userId) throw new Error('VPN-устройство принадлежит другому аккаунту.');
    const requiresKeySeparation = Boolean(scope.legacyRegistrationPending && scope.legacyOwnedDeviceId && scope.installationId !== scope.externalDeviceId);
    if (requiresKeySeparation) {
      // Register can reuse the row without changing its WG public key. A B-first
      // migration may have copied A's old global pair: rotate only B's row.
      device = (await rotateVpnAccountDeviceKey(accessToken, device, scope, await pendingVpnAccountKeyPair(scope.keyScope, options.isCurrentSessionOperation), options.isCurrentSessionOperation, { client, options })).device;
      scope = { ...scope, confirmedDeviceId: device.id };
    }
    if (scope.legacyRegistrationPending) await confirmVpnAccountRegistration(options, scope);
    if (requiresKeySeparation) await clearPendingVpnAccountKeyPair(scope.keyScope, options.isCurrentSessionOperation);
    return device;
  });
}

async function registerNativeDevice(accessToken: string, client: VpnClientDescriptor, keyPair: Pick<WireGuardKeyPair, 'publicKey' | 'keyEpoch'> | null, locationId: string, externalDeviceId: string, isCurrentSessionOperation?: () => boolean, installationId = externalDeviceId, accountUserId?: string, requireIdentityProof = false, reconciliation?: { deviceId: string }): Promise<VpnDevice> {
  const reconcileDeviceId = reconciliation?.deviceId;
  if (reconciliation !== undefined && !isVpnAccountDeviceId(reconcileDeviceId)) {
    throw new Error('Не удалось подтвердить цель сверки VPN-устройства.');
  }
  if (!keyPair?.publicKey) {
    const error = new Error('Локальные ключи WireGuard не сгенерированы. Проверьте настройки устройства.');
    // Web can use the server-generated legacy config. No registration has
    // been dispatched at this local capability check. Native callers fail.
    if (!requiresManagedNativeProfile(client)) throw new LegacyProfileFallbackError(error);
    throw error;
  }
  const appInfo = await getAppInfo();
  requireCurrentSession(isCurrentSessionOperation);
  const identity = await nativeDeviceIdentityRegistration(accessToken, installationId, keyPair.publicKey, reconcileDeviceId);
  requireCurrentSession(isCurrentSessionOperation);
  if ((requireIdentityProof || reconcileDeviceId) && !identity.identity_signature) throw new Error('Не удалось подтвердить прежнюю регистрацию VPN.');
  const response = await jsonRequest<RegisterNativeDeviceResultDTO>('/v1/devices/register', {
    method: 'POST',
    accessToken,
    // A prior API may handle this POST during a rolling upgrade. A fresh
    // challenge key cannot hit its creation replay before purpose validation.
    idempotencyKey: reconcileDeviceId ? `native-reconcile-${identity.identity_challenge_id}`
      : accountUserId ? vpnAccountRegistrationIdempotencyKey(accountUserId, installationId, locationId) : `native-register-${installationId}-${locationId}`,
    ...(reconcileDeviceId ? { retryCount: 0 } : {}),
    body: {
      device_id: externalDeviceId,
      ...(reconcileDeviceId ? { reconcile_device_id: reconcileDeviceId } : {}),
      installation_id: installationId,
      device_name: nativeDeviceName(client),
      platform: client.platform || appInfo.platform || Platform.OS,
      app_version: appInfo.version,
      protocol: mobileProtocol,
      location: locationId,
      public_key: keyPair?.publicKey,
      key_epoch: keyPair?.keyEpoch ?? (keyPair ? 1 : undefined),
      ...identity,
    } satisfies NativeDeviceRegistrationRequest,
  });
  if (reconcileDeviceId && (response.device_registered !== true || response.binding_status !== 'active' || response.trust_level !== 'software_secure_store')) {
    throw new Error('Сервер не подтвердил владельца нового VPN-устройства.');
  }
  return parseDevice(response.device);
}

type NativeDeviceIdentityProof = {
  [Key in 'identity_public_key' | 'identity_key_type' | 'identity_challenge_id' | 'identity_signature']-?: NonNullable<NativeDeviceRegistrationRequest[Key]>;
};

async function nativeDeviceIdentityRegistration(
  accessToken: string,
  installationId: string,
  wireGuardPublicKey: string,
  reconcileDeviceId?: string,
): Promise<NativeDeviceIdentityProof | Record<string, never>> {
  const identity = await getOrCreateDeviceIdentity().catch((error) => {
    logApiDebug('device identity unavailable:', error instanceof Error ? error.message : error);
    return null;
  });
  if (!identity) {
    return {};
  }
  try {
    const challenge = await jsonRequest<DeviceIdentityChallengeDTO>('/v1/devices/identity-challenge', {
      method: 'POST',
      accessToken,
      suppressErrorLog: true,
      body: {
        installation_id: installationId,
        purpose: reconcileDeviceId ? 'reconcile' : 'register',
        ...(reconcileDeviceId ? { device_id: reconcileDeviceId } : {}),
      } satisfies NativeDeviceIdentityChallengeRequest,
    });
    // An older API may normalize an unknown purpose to register. Never send
    // the read-only reconciliation request unless support is explicit.
    if (reconcileDeviceId && (challenge.purpose !== 'reconcile' || typeof challenge.id !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(challenge.id))) {
      throw new Error('Сервер не поддерживает безопасную сверку VPN-устройства.');
    }
    const payload = deviceIdentitySignaturePayload(
      {
        id: challenge.id,
        nonce: challenge.nonce,
        purpose: challenge.purpose || 'register',
      },
      installationId,
      identity.publicKey,
      wireGuardPublicKey,
    );
    return {
      identity_public_key: identity.publicKey,
      identity_key_type: identity.keyType,
      identity_challenge_id: challenge.id,
      identity_signature: await identity.sign(payload),
    };
  } catch (error) {
    logApiDebug('device identity challenge failed, falling back to legacy registration:', error instanceof Error ? error.message : error);
    return {};
  }
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
  return requireVpnLocationId(locationId);
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
  return { deviceName: 'Web', idempotencyPrefix: 'web', platform: 'web' };
}

export function requiresManagedNativeProfile(client: VpnClientDescriptor): boolean {
  return Platform.OS === 'android' || Platform.OS === 'ios' || client.platform === 'android' || client.platform === 'ios';
}

function logApiDebug(...items: unknown[]) {
  console.log(...items);
}

export function parseDevice(item: DeviceDTO): VpnDevice {
  if (item.psk_epoch !== undefined && !isNonnegativeSafeInteger(item.psk_epoch)) {
    throw new Error('Сервер вернул некорректную эпоху ключа VPN.');
  }
  return {
    id: item.id,
    userId: item.user_id || undefined,
    name: item.name ?? '',
    status: item.status ?? '',
    assignedIpv4: item.assigned_ipv4 || undefined,
    nodeId: item.node_id || undefined,
    protocol: item.protocol || undefined,
    protocolLabel: item.protocol_label || undefined,
    endpoint: item.endpoint || undefined,
    latencyMs: typeof item.latency_ms === 'number' ? item.latency_ms : undefined,
    publicKey: item.public_key || undefined,
    keyEpoch: typeof item.psk_epoch === 'number' ? item.psk_epoch : undefined,
    provisioningMode: item.provisioning_mode || undefined,
    clientKeyOwnership: item.client_key_ownership || undefined,
    externalDeviceId: item.external_device_id || undefined,
    platform: item.platform || undefined,
    pushProvider: item.push_provider || undefined,
  };
}

export function parseDeviceUsage(item: DeviceUsageDTO): VpnDeviceUsage {
  return {
    deviceId: item.device_id,
    connectionStatus: item.connection_status || 'unknown',
    connected: Boolean(item.connected),
    secondsSinceHandshake: typeof item.seconds_since_handshake === 'number' ? item.seconds_since_handshake : undefined,
    rxBytes: typeof item.rx_bytes === 'number' ? item.rx_bytes : 0,
    txBytes: typeof item.tx_bytes === 'number' ? item.tx_bytes : 0,
    totalBytes: typeof item.total_bytes === 'number' ? item.total_bytes : 0,
    historicalRxBytes: typeof item.historical_rx_bytes === 'number' ? item.historical_rx_bytes : 0,
    historicalTxBytes: typeof item.historical_tx_bytes === 'number' ? item.historical_tx_bytes : 0,
    historicalTotalBytes: typeof item.historical_total_bytes === 'number' ? item.historical_total_bytes : 0,
    lastNonzeroTrafficAt: item.last_nonzero_traffic_at || undefined,
    rateLimitMbps: typeof item.rate_limit_mbps === 'number' ? item.rate_limit_mbps : undefined,
    trafficPriority: typeof item.traffic_priority === 'number' ? item.traffic_priority : 0,
    rxRateBps: typeof item.rx_rate_bps === 'number' ? item.rx_rate_bps : undefined,
    txRateBps: typeof item.tx_rate_bps === 'number' ? item.tx_rate_bps : undefined,
  };
}

export function parseDeviceTrafficQuota(item: DeviceTrafficQuotaDTO): VpnTrafficQuota {
  return {
    deviceId: item.device_id,
    usedBytes: typeof item.used_bytes === 'number' ? item.used_bytes : 0,
    limitBytes: typeof item.limit_bytes === 'number' ? item.limit_bytes : 0,
    resetAt: item.reset_at,
    multiplier: typeof item.multiplier === 'number' ? item.multiplier : 1,
    limitReached: Boolean(item.limit_reached),
    effectiveRateLimitMbps: typeof item.effective_rate_limit_mbps === 'number'
      ? item.effective_rate_limit_mbps
      : undefined,
  };
}

export function managedProfileConfig(profile: NativeVPNProfileDTO, keyPair: WireGuardKeyPair | null): string {
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
  const amnezia = managedProfileAmneziaConfig(profile.amnezia ?? undefined);
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

export function managedProfileEndpoint(profile: NativeVPNProfileDTO): string | undefined {
  if (!profile.server) {
    return undefined;
  }
  if (typeof profile.port === 'number' && profile.port > 0) {
    return `${profile.server}:${profile.port}`;
  }
  return profile.server;
}
