import { useCallback, useEffect, useRef } from 'react';
import { withProfileRecoveryTransport } from '@/api/client';
import { Platform } from 'react-native';

import {
  saveHotVpnProfile,
  withLastSuccessfulEndpoint,
} from '@/vpn/hotProfileCache';
import {
  connectionAttemptsForProfile,
  isVpnTransportFallbackError,
  profileEndpoint,
} from '@/vpn/connectionFallback';
import {
  explicitConnectProfileResolutionOptions,
  isUnverifiedProfileSource,
  vpnConnectTelemetry,
  vpnConnectTimingSamples,
} from '@/vpn/connectFlow';
import {
  cachedConnectAttemptTimeoutMs,
  connectAttemptTimeoutMs,
  type ConnectedVpnAttempt,
  errorMessage,
  withTimeout,
} from '@/screens/home-screen-helpers';
import {
  connectVpn,
  disconnectVpn,
  getVpnStatus,
  readVpnNetworkObservation,
  scheduleVpnVerificationTimeout,
  supportsNativeVless,
  type VpnStatus,
} from '@/native/vexVpn';
import { waitForVerifiedVpnConnection } from '@/vpn/connectVerification';
import { cleanupFailedVpnConnection } from '@/vpn/failedConnectionCleanup';
import {
  isProfileResolutionFallbackError,
  profileResolutionOrder,
  resolveProfileOrSkipMissing,
} from '@/vpn/profileResolutionFallback';
import { androidVpnProfileWithinBinderBudget } from '@/vpn/androidRoutingSafety';
import { vpnProfileAddressMatchesDevice } from '@/vpn/profileConsistency';
import { withCurrentVpnProfileKey, VpnProfileKeyChangedError } from '@/api/vexApi';
import {
  getVpnApplicationSelection,
  setSelectedVpnLocation,
} from '@/settings/vpnPreferences';
import {
  chooseBestVpnLocation,
  isSelectableLocation,
  locationSupportsVless,
  type ServerSelectionMode,
} from '@/vpn/serverSelection';
import { prepareClientNetworkDiagnostics, uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import { submitClientDiagnostics, type VpnLocation } from '@/api/vexApi';
import { dynamicRouteRuntime } from '@/vpn/dynamicRouteRuntime';
import { routeTransport, type DynamicRouteAttempt, type DynamicRouteCandidate } from '@/vpn/dynamicRouteCore';
import { canFallbackVpnProtocol, normalizeVpnTransport, type VpnTransport, type VpnTransportPreference } from './transport';
import type { VpnRoutingMode } from './routingPolicy';
import type { VpnProfile } from '@/vpn/profile';
import type { ResolveConnectableProfileOptions } from '@/vpn/serverSwitch';
import { SessionOperationSupersededError } from '@/vpn/sessionOperation';

// Only inspect the settled disconnect result: Android may retain an empty anti-leak blocker.
function isSettledVpnDisconnect(status: VpnStatus): boolean {
  return status.state === 'disconnected' || (
    status.state === 'error' && status.leakProtection === 'blocking' && status.verified === false
    && status.rxBytes === 0 && status.txBytes === 0 && status.latestHandshakeEpochMillis === 0
    && status.verificationReason === 'endpoint_failed'
  );
}

// Optional native observation must never hold profile issuance or tunnel admission open.
const readBoundedNetworkObservation = () => withTimeout(
  readVpnNetworkObservation(), 200, 'VPN network observation timed out.',
).catch(() => null);

class VpnVlessUnavailableError extends Error {
  readonly code = 'VPN_VLESS_UNAVAILABLE';
  constructor() { super('VLESS недоступен для выбранного сервера. Обновите список серверов.'); }
}

type QualifiedLocation = {
  userId: string;
  isCurrent: () => boolean;
  locationId: string;
  transport: VpnTransport;
  networkClass: string;
  generation: string;
  verifiedAt: number;
};
const qualifiedLocationMaxAgeMs = 5 * 60_000;

type UseVpnConnectionFlowInput = {
  supportsVless?: boolean;
  transportPreference?: VpnTransportPreference;
  routingMode?: VpnRoutingMode;
  isCurrentSessionOperation: () => boolean;
  antiLeakEnabled: boolean;
  selectedLocationId: string;
  serverSelectionMode: ServerSelectionMode;
  availableLocations: VpnLocation[];
  cacheProfile: (locationId: string, profile: VpnProfile) => void;
  resolveConnectableVpnProfile: (
    locationId: string,
    options?: ResolveConnectableProfileOptions
  ) => Promise<VpnProfile>;
  vpnStatus: VpnStatus;
  clientLatencyMs: number | null;
  reportVpnConnectEvent: (profile: VpnProfile, reason: string) => void;
  setSelectedLocationId: (locationId: string) => void;
  setActiveProfile: (profile: VpnProfile | null) => void;
  setVpnStatus: React.Dispatch<React.SetStateAction<VpnStatus>>;
  session: { accessToken: string; user: { id: string } } | null;
};

export function useVpnConnectionFlow({
  supportsVless = false,
  transportPreference,
  routingMode,
  isCurrentSessionOperation,
  antiLeakEnabled,
  selectedLocationId,
  serverSelectionMode,
  availableLocations,
  cacheProfile,
  resolveConnectableVpnProfile,
  vpnStatus,
  clientLatencyMs,
  reportVpnConnectEvent,
  setSelectedLocationId,
  setActiveProfile,
  setVpnStatus,
  session,
}: UseVpnConnectionFlowInput) {
  const vlessAvailabilityRef = useRef({ supportsVless, availableLocations, userId: session?.user.id, isCurrent: isCurrentSessionOperation });
  vlessAvailabilityRef.current = { supportsVless, availableLocations, userId: session?.user.id, isCurrent: isCurrentSessionOperation };
  const qualifiedLocationRef = useRef<QualifiedLocation | null>(null);
  const lastVerifiedTransportRef = useRef<{ userId: string; isCurrent: () => boolean; transport: VpnTransport } | null>(null);
  useEffect(() => {
    if (session && isCurrentSessionOperation() && vpnStatus.state === 'connected' && vpnStatus.verified === true) {
      lastVerifiedTransportRef.current = { userId: session.user.id, isCurrent: isCurrentSessionOperation, transport: normalizeVpnTransport(vpnStatus.transport) };
    }
  }, [isCurrentSessionOperation, session, vpnStatus]);
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; };
  }, []);
  const requireCurrentSession = useCallback(() => {
    if (!mountedRef.current || !isCurrentSessionOperation()) {
      throw new SessionOperationSupersededError();
    }
  }, [isCurrentSessionOperation]);

  const requireCurrentVlessLocation = useCallback((locationId: string) => {
    requireCurrentSession();
    const latest = vlessAvailabilityRef.current;
    if (latest.userId !== session?.user.id || latest.isCurrent !== isCurrentSessionOperation || !latest.isCurrent()) {
      throw new SessionOperationSupersededError();
    }
    if (!supportsNativeVless() || latest.supportsVless !== true
      || !latest.availableLocations.some(location => location.id === locationId && locationSupportsVless(location))) {
      throw new VpnVlessUnavailableError();
    }
  }, [isCurrentSessionOperation, requireCurrentSession, session?.user.id]);

  const connectProfileWithEndpointFallback = useCallback(async (profile: VpnProfile, isCurrentOperation: () => boolean = () => true, beforeNativeConnect?: () => Promise<unknown>, onNativeDispatched?: () => void) => {
    const requireCurrentOperation = () => {
      requireCurrentSession();
      if (!isCurrentOperation()) throw new SessionOperationSupersededError();
    };
    requireCurrentOperation();
    if (session?.accessToken) {
      // Network observation is diagnostic only: start it and connect in
      // parallel instead of waiting up to connectDiagnosticsPrepareTimeoutMs.
      void prepareClientNetworkDiagnostics(session.accessToken, profile.device?.id, isCurrentSessionOperation);
      requireCurrentOperation();
    }
    if (!vpnProfileAddressMatchesDevice(profile)) {
      throw new Error('VPN connection failed: cached profile address does not match its device assignment.');
    }
    if (!androidVpnProfileWithinBinderBudget(Platform.OS, profile.config)) {
      throw new Error('Android VPN profile exceeds the safe route limit. Refresh the profile before connecting.');
    }
    const endpointAttempts: string[] = [];
    const applicationSelection = await getVpnApplicationSelection();
    requireCurrentOperation();
    if (profile.transport !== 'vless' && Platform.OS === 'android' && session?.user.id && session.accessToken) {
      // Route policy is optional background data: the direct endpoint always
      // works. Start preparation and continue connecting immediately.
      void dynamicRouteRuntime.prepare(session.user.id, session.accessToken, isCurrentSessionOperation);
    }
    const attempts: DynamicRouteAttempt[] = profile.transport === 'vless' ? [{ profile }] : Platform.OS === 'android'
      ? dynamicRouteRuntime.attempts(profile)
      : connectionAttemptsForProfile(profile).map((attempt) => ({ profile: attempt }));
    let previousRouteTransport: 'awg3_direct' | 'awg3_relay' | undefined;
    let lastError: unknown = new Error('VPN connection failed.');
    // A cached or hot profile is unverified: prove it quickly instead of
    // spending the full attempt budget on an endpoint the server already replaced.
    const firstAttemptTimeoutMs = isUnverifiedProfileSource(profile)
      ? cachedConnectAttemptTimeoutMs
      : connectAttemptTimeoutMs;
    let firstAttemptMs: number | null = null;
    let nativePreparationCompleted = false;
    // Поддержка VPN один раз перед циклом попыток — не на каждую итерацию.
    const cachedVpnStatus = Platform.OS === 'android' ? await getVpnStatus().catch(() => null) : null;
    const reportRoute = (candidate: DynamicRouteCandidate, event: 'connect_failed' | 'connect_succeeded' | 'fallback_failed' | 'fallback_succeeded', status: string) => {
      if (!session?.accessToken) return;
      void submitClientDiagnostics(session.accessToken, {
        reason: 'dynamic_route', status, platform: 'android', deviceId: profile.device?.id,
        connectionEvent: event, transportFrom: previousRouteTransport,
        transportTo: routeTransport(candidate),
      }).catch(() => undefined);
    };
    for (const [attemptIndex, { profile: attempt, candidate }] of attempts.entries()) {
      const attemptStartedAtMs = Date.now();
      let nativeDispatched = false;
      try {
        requireCurrentOperation();
        const endpoint = profileEndpoint(attempt);
        if (endpoint) {
          endpointAttempts.push(endpoint);
        }
        const previousStatus = cachedVpnStatus;
        requireCurrentOperation();
        let nativeStartMs = Date.now();
        let admissionIsCurrent = true;
        let startedStatus: VpnStatus;
        try {
          startedStatus = await withTimeout(withCurrentVpnProfileKey(session?.accessToken ?? '', attempt, async () => {
            requireCurrentOperation();
            if (!nativePreparationCompleted) {
              await beforeNativeConnect?.();
              nativePreparationCompleted = true;
            }
            requireCurrentOperation();
            if (!admissionIsCurrent) throw new SessionOperationSupersededError();
            if (attempt.transport === 'vless') requireCurrentVlessLocation(attempt.locationId);
            nativeStartMs = Date.now();
            nativeDispatched = true;
            onNativeDispatched?.();
            return connectVpn(attempt.config, {
              antiLeakEnabled,
              transport: attempt.transport ?? 'amneziawg',
              routingParameters: attempt.routingParameters,
              routingMode: attempt.routingMode,
              applicationRoutingMode: applicationSelection.mode,
              selectedApplications: applicationSelection.packageNames,
            });
          }, { userId: session?.user.id, isCurrentSessionOperation: () => admissionIsCurrent && mountedRef.current && isCurrentSessionOperation() && isCurrentOperation() }), attemptIndex === 0 ? firstAttemptTimeoutMs : connectAttemptTimeoutMs, 'VPN connect timed out.');
        } finally {
          // A timed-out borrower must not dispatch later from the owner queue.
          admissionIsCurrent = false;
        }
        const interfaceUpMs = Date.now();
        requireCurrentOperation();
        const status = await waitForVerifiedVpnConnection(startedStatus, () => getVpnStatus({ fresh: true }), {
          scheduleTimeout: scheduleVpnVerificationTimeout,
          assertCurrent: requireCurrentOperation,
          transport: attempt.transport ?? 'amneziawg',
          expectedConnectionId: startedStatus.connectionId,
          minimumVerificationEpochMillis: nativeStartMs,
          previousConnectionId: previousStatus?.connectionId,
          requireDataPlane: Platform.OS === 'android' && attempt.transport !== 'vless',
          expectedDataPlaneGeneration: startedStatus.dataPlaneGeneration,
          timeoutMs: Platform.OS === 'android' ? 15_000 : 10_000,
          // The native backend can briefly expose the previous peer timestamp
          // while replacing a tunnel. Require activity from this attempt. The
          // small tolerance covers second-resolution backend timestamps.
          minimumHandshakeEpochMillis: nativeStartMs - 2_000,
          previousHandshakeEpochMillis: previousStatus?.latestHandshakeEpochMillis,
        });
        const verificationCompletedMs = Date.now();
        requireCurrentOperation();
        // Android admission requires fresh peer-bound DNS and TLS/HTTP proof
        // from the AWG NetTUN, independent of DIRECT and per-app routing.
        if (candidate) {
          dynamicRouteRuntime.recordSuccess(candidate);
          reportRoute(candidate, endpointAttempts.length > 1 ? 'fallback_succeeded' : 'connect_succeeded', 'ok');
        } else {
          dynamicRouteRuntime.clearActive();
        }
        if (attemptIndex === 0) firstAttemptMs = Date.now() - attemptStartedAtMs;
        return {
          interfaceUpMs,
          endpointAttempts,
          firstAttemptMs,
          nativeStartMs,
          profile: withLastSuccessfulEndpoint(attempt, endpoint),
          status,
          verificationCompletedMs,
        };
      } catch (error) {
        requireCurrentOperation();
        if (attemptIndex === 0) firstAttemptMs = Date.now() - attemptStartedAtMs;
        if (!nativeDispatched) {
          if (error instanceof VpnProfileKeyChangedError || error instanceof SessionOperationSupersededError || error instanceof VpnVlessUnavailableError) throw error;
          throw new Error('Не удалось проверить ключ и подготовить VPN к подключению.', { cause: error });
        }
        lastError = error;
        if (!isVpnTransportFallbackError(error)) {
          throw error;
        }
        if (candidate) {
          dynamicRouteRuntime.recordFailure(candidate);
          reportRoute(candidate, endpointAttempts.length > 1 ? 'fallback_failed' : 'connect_failed', 'error');
          previousRouteTransport = routeTransport(candidate);
        }
        if (profile.transport !== 'vless' && Platform.OS === 'android' && !attempts.some((item) => item.candidate)) {
          // A background policy may arrive while the signed endpoint is being
          // tried. Keep its bounded relay choices available to this connection.
          const seen = new Set(endpointAttempts.map((endpoint) => endpoint.toLowerCase()));
          for (const prepared of dynamicRouteRuntime.attempts(profile)) {
            const endpoint = profileEndpoint(prepared.profile)?.toLowerCase();
            if (prepared.candidate && endpoint && !seen.has(endpoint)) {
              seen.add(endpoint);
              attempts.push(prepared);
            }
          }
        }
      }
    }
    throw lastError;
  }, [antiLeakEnabled, isCurrentSessionOperation, requireCurrentSession, requireCurrentVlessLocation, session?.accessToken, session?.user.id]);

  const connectCurrentVpn = useCallback(async ({
    locationId: requestedLocationId,
    waitForAnimation = false,
    requestPermission = true,
    isCurrentOperation = () => true,
    protocol,
    onFailurePhase,
  }: {
    locationId?: string;
    waitForAnimation?: boolean;
    requestPermission?: boolean;
    isCurrentOperation?: () => boolean;
    protocol?: VpnTransport;
    onFailurePhase?: (phase: 'profile' | 'native') => void;
  } = {}) => {
    const requireCurrentOperation = () => {
      requireCurrentSession();
      if (!isCurrentOperation()) throw new SessionOperationSupersededError();
    };
    requireCurrentOperation();
    const resolveCurrentProfile: typeof resolveConnectableVpnProfile = async (location, options = {}) => {
      requireCurrentOperation();
      try {
        const resolve = () => {
          requireCurrentOperation();
          if (protocol === 'vless' || options.transport === 'vless' || transportPreference === 'vless') requireCurrentVlessLocation(location);
          return resolveConnectableVpnProfile(location, {
            ...options,
            ...(protocol ? { transport: protocol, ...(protocol === 'vless' ? { routingMode: 'full_tunnel' as const } : routingMode ? { routingMode } : {}) } : {}),
            isCurrentOperation: () => isCurrentOperation() && options.isCurrentOperation?.() !== false,
            // Only an explicit manual connect may obtain/reclaim Android's VPN
            // grant. Automatic retries retain this prohibition for every route.
            requestPermission: requestPermission && options.requestPermission !== false,
          });
        };
        // Smart routing captures this app too. A failed tunnel must not carry
        // the API request that repairs it; keep other app UIDs protected.
        return options.forceRefresh && options.requestPermission === false
          ? await withProfileRecoveryTransport(resolve)
          : await resolve();
      } catch (error) {
        onFailurePhase?.('profile');
        throw error;
      } finally {
        requireCurrentOperation();
      }
    };
    const connectCurrentProfile = async (candidate: VpnProfile) => {
      requireCurrentOperation();
      try {
        const connected = await connectProfileWithEndpointFallback(candidate, isCurrentOperation, undefined, () => onFailurePhase?.('native'));
        onFailurePhase?.('profile');
        return connected;
      } finally {
        requireCurrentOperation();
      }
    };
    const tapStartedAt = Date.now();
    const locationId = requestedLocationId ?? selectedLocationId;
    const requiresVless = protocol === 'vless' || transportPreference === 'vless';
    const protocolLocations = requiresVless ? availableLocations.filter(locationSupportsVless) : availableLocations;
    // Consume before any fallible work: a failed attempt cannot preserve old success.
    const evidence = qualifiedLocationRef.current;
    qualifiedLocationRef.current = null;
    const networkBefore = await readBoundedNetworkObservation();
    requireCurrentOperation();
    const ageMs = evidence ? Date.now() - evidence.verifiedAt : -1;
    const qualifiedLocation = evidence && session && evidence.userId === session.user.id
      && evidence.isCurrent === isCurrentSessionOperation && evidence.isCurrent()
      && ageMs >= 0 && ageMs <= qualifiedLocationMaxAgeMs
      && evidence.transport === (protocol ?? transportPreference ?? 'amneziawg')
      && networkBefore?.networkClass === evidence.networkClass && networkBefore.generation === evidence.generation
      ? protocolLocations.find(location => location.id === evidence.locationId && isSelectableLocation(location))
      : undefined;
    void waitForAnimation;

    if (serverSelectionMode === 'auto' && requestedLocationId === undefined && requiresVless && protocolLocations.length === 0) {
      throw new Error('VPN-профиль недоступен.');
    }
    const initialLocationId = serverSelectionMode === 'auto' && requestedLocationId === undefined
      ? qualifiedLocation?.id ?? chooseBestVpnLocation(protocolLocations)?.id ?? locationId
      : locationId;
    let profile: VpnProfile | null = null;
    let profileLocationId = initialLocationId;
    let lastProfileError: unknown;
    // Profile issuance can move placement: never acquire unused locations.
    const orderedLocations = protocol ? [{ id: initialLocationId }] : profileResolutionOrder(initialLocationId, protocolLocations);
    for (const candidate of orderedLocations) {
      try {
        profile = await resolveCurrentProfile(candidate.id, explicitConnectProfileResolutionOptions);
        profileLocationId = candidate.id;
        break;
      } catch (error) {
        lastProfileError = error;
        if (protocol || !isProfileResolutionFallbackError(error)) throw error;
      }
    }
    if (!profile) {
      throw lastProfileError ?? new Error('VPN-профиль недоступен.');
    }
    if (!androidVpnProfileWithinBinderBudget(Platform.OS, profile.config)) {
      throw new Error('Android VPN profile exceeds the safe route limit. Refresh the profile before connecting.');
    }
    let connected: ConnectedVpnAttempt | null = null;
    let connectedLocationId = profileLocationId;
    let lastConnectError: unknown;
    try {
      connected = await connectCurrentProfile(profile);
    } catch (error) {
      requireCurrentOperation();
      if (profile.hotProfileUsed && session?.accessToken) {
        void uploadClientDiagnostics(session.accessToken, {
          reason: 'hot_profile_connect_failed',
          status: 'failed',
          deviceId: profile.device?.id,
          endpoint: profileEndpoint(profile),
          vpnStatus,
          samples: {
            connect_error: errorMessage(error, 'hot_profile_connect_failed'),
            hot_profile_age_ms: profile.hotProfileAgeMs ?? null,
          },
        }).catch(() => undefined);
      }
      if (!isVpnTransportFallbackError(error)) {
        throw error;
      }
      lastConnectError = error;
      if (protocol) throw error;
    }

    try {
      if (!connected) {
        // A lost issuance reply is not permission to issue on another location.
        const freshProfile = await resolveProfileOrSkipMissing(() => resolveCurrentProfile(profileLocationId, {
          forceRefresh: true,
          preferCached: false,
          requestPermission: false,
        }));
        if (freshProfile) {
          try {
            connected = await connectCurrentProfile(freshProfile);
          } catch (error) {
            lastConnectError = error;
            if (!isVpnTransportFallbackError(error)) throw error;
          }
        }
      }

      const fallbackLocations = profileResolutionOrder(profileLocationId, protocolLocations)
        .filter((location) => location.id !== profileLocationId);
      for (const location of fallbackLocations) {
        if (connected?.status.state === 'connected') break;
        const fallbackProfile = await resolveProfileOrSkipMissing(() => resolveCurrentProfile(location.id, {
          forceRefresh: true,
          preferCached: false,
          requestPermission: false,
        }));
        if (!fallbackProfile) continue;
        try {
          connected = await connectCurrentProfile(fallbackProfile);
          connectedLocationId = location.id;
        } catch (error) {
          lastConnectError = error;
          if (!isVpnTransportFallbackError(error)) throw error;
        }
      }

      if (!connected || connected.status.state !== 'connected') {
        throw lastConnectError ?? new Error('VPN не подключился.');
      }
    } catch (error) {
      // Logout owns teardown. A completion from an older login must never
      // disconnect the tunnel of the account that signed in afterwards.
      requireCurrentOperation();
      // Profile/API failures during recovery must not leave an unverified
      // native attempt running. Admission errors retain the previous tunnel.
      await cleanupFailedVpnConnection(antiLeakEnabled, disconnectVpn, error).catch(() => undefined);
      throw error;
    }

    const networkAfter = await readBoundedNetworkObservation();
    requireCurrentOperation();

    if (connectedLocationId !== selectedLocationId) {
      const persistedLocationId = await setSelectedVpnLocation(connectedLocationId);
      requireCurrentOperation();
      setSelectedLocationId(persistedLocationId);
      cacheProfile(persistedLocationId, connected.profile);
    }

    requireCurrentOperation();
    const verifiedAt = Date.now();
    const actualTransport = connected.profile.transport;
    if (session && connected.status.verified === true
      && (actualTransport === 'amneziawg' || actualTransport === 'vless')
      && connected.status.transport === actualTransport
      && networkBefore && networkBefore.networkClass !== 'unknown' && networkBefore.generation
      && networkAfter?.networkClass === networkBefore.networkClass && networkAfter.generation === networkBefore.generation
      && verifiedAt >= tapStartedAt && verifiedAt - tapStartedAt <= qualifiedLocationMaxAgeMs
      && availableLocations.some(location => location.id === connected.profile.locationId && isSelectableLocation(location))) {
      qualifiedLocationRef.current = {
        userId: session.user.id, isCurrent: isCurrentSessionOperation,
        locationId: connected.profile.locationId, transport: actualTransport,
        networkClass: networkBefore.networkClass, generation: networkBefore.generation, verifiedAt,
      };
    }
    setActiveProfile(connected.profile);
    if (session?.user.id) {
      void saveHotVpnProfile(session.user.id, connected.profile.locationId || connectedLocationId, connected.profile, {
        lastSuccessfulEndpoint: profileEndpoint(connected.profile),
      }).catch(() => undefined);
    }
    const nextStatus = connected.status;
    setVpnStatus(nextStatus);
    if (session) {
      reportVpnConnectEvent(connected.profile, 'user');
      void uploadClientDiagnostics(session.accessToken, {
        reason: 'vpn_connect_timing',
        status: nextStatus.verified === false ? 'verifying' : 'ok',
        deviceId: connected.profile.device?.id,
        endpoint: connected.profile.device?.endpoint,
        vpnStatus: nextStatus,
        latencyMs: clientLatencyMs,
        ...vpnConnectTelemetry({
          connectedProfile: connected.profile,
          endpointAttempts: connected.endpointAttempts,
          initialProfile: profile,
          locationFallback: connectedLocationId !== profileLocationId,
          tapStartedAt,
          verificationCompletedMs: connected.verificationCompletedMs,
        }),
        samples: {
          ...vpnConnectTimingSamples({
            endpointAttempts: connected.endpointAttempts,
            firstAttemptMs: connected.firstAttemptMs,
            interfaceUpMs: connected.interfaceUpMs,
            nativeStartMs: connected.nativeStartMs,
            profile: connected.profile,
            tapStartedAt,
            verificationCompletedMs: connected.verificationCompletedMs,
          }),
        },
      }).catch(() => undefined);
    }
  }, [
    antiLeakEnabled,
    routingMode,
    transportPreference,
    isCurrentSessionOperation,
    availableLocations,
    cacheProfile,
    clientLatencyMs,
    connectProfileWithEndpointFallback,
    reportVpnConnectEvent,
    requireCurrentSession,
    requireCurrentVlessLocation,
    resolveConnectableVpnProfile,
    selectedLocationId,
    setSelectedLocationId,
    serverSelectionMode,
    session,
    setActiveProfile,
    setVpnStatus,
    vpnStatus,
  ]);

  const connectAutomaticVpn = useCallback(async (options: Parameters<typeof connectCurrentVpn>[0] = {}) => {
    const isCurrent = () => mountedRef.current && isCurrentSessionOperation() && options.isCurrentOperation?.() !== false;
    const requireCurrent = () => { if (!isCurrent()) throw new SessionOperationSupersededError(); };
    requireCurrent();
    // A live verified tunnel is evidence, not an opportunity to benchmark another protocol.
    if (vpnStatus.state === 'connected' && vpnStatus.verified === true) return;
    const native = await getVpnStatus({ fresh: true });
    requireCurrent();
    if (native.state === 'connected' && native.verified === true) return;
    if (native.state === 'connecting' || native.state === 'verifying' || native.state === 'disconnecting') {
      throw new Error('Дождитесь завершения текущей операции VPN.');
    }
    if (native.state !== 'disconnected') {
      const stopped = await disconnectVpn({ releaseAntiLeak: !antiLeakEnabled });
      requireCurrent();
      if (!isSettledVpnDisconnect(stopped)) throw new Error('Не удалось остановить предыдущее подключение VPN.');
    }
    const evidence = lastVerifiedTransportRef.current;
    const vlessAvailable = supportsNativeVless() && supportsVless === true;
    const first = evidence?.userId === session?.user.id && evidence?.isCurrent() && (evidence.transport !== 'vless' || vlessAvailable)
      ? evidence.transport : 'amneziawg';
    const protocols: VpnTransport[] = vlessAvailable
      ? [first, first === 'vless' ? 'amneziawg' : 'vless'] : ['amneziawg'];
    for (const [index, protocol] of protocols.entries()) {
      requireCurrent();
      const attempt = { phase: 'profile' as 'profile' | 'native' };
      try {
        await connectCurrentVpn({ ...options, protocol, requestPermission: index === 0 && options.requestPermission !== false,
          isCurrentOperation: isCurrent, onFailurePhase: value => { attempt.phase = value; } });
        requireCurrent();
        if (session) lastVerifiedTransportRef.current = { userId: session.user.id, isCurrent: isCurrentSessionOperation, transport: protocol };
        return;
      } catch (error) {
        requireCurrent();
        if (!canFallbackVpnProtocol(error, attempt.phase)) throw error;
        const latest = await getVpnStatus({ fresh: true });
        requireCurrent();
        if (latest.state === 'connected' && latest.verified === true) throw error;
        if (attempt.phase === 'native' || latest.state !== 'disconnected') {
          // Do not issue the alternate until the old native tunnel has actually stopped.
          const stopped = await disconnectVpn({ releaseAntiLeak: !antiLeakEnabled });
          requireCurrent();
          if (!isSettledVpnDisconnect(stopped)) throw error;
        }
        if (index === protocols.length - 1) throw error;
      }
    }
  }, [antiLeakEnabled, connectCurrentVpn, isCurrentSessionOperation, session, supportsVless, vpnStatus]);

  return {
    connectProfileWithEndpointFallback,
    connectCurrentVpn: transportPreference === 'auto' ? connectAutomaticVpn : connectCurrentVpn,
  };
}
