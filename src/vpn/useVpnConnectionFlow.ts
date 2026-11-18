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
  scheduleVpnVerificationTimeout,
  type VpnStatus,
} from '@/native/vexVpn';
import { waitForVerifiedVpnConnection } from '@/vpn/connectVerification';
import { connectFreshSameLocationProfile } from '@/vpn/sameLocationProfileRecovery';
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
  type ServerSelectionMode,
} from '@/vpn/serverSelection';
import { prepareClientNetworkDiagnostics, uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import { submitClientDiagnostics, type VpnLocation } from '@/api/vexApi';
import { dynamicRouteRuntime } from '@/vpn/dynamicRouteRuntime';
import { routeTransport, type DynamicRouteAttempt, type DynamicRouteCandidate } from '@/vpn/dynamicRouteCore';
import type { VpnProfile } from '@/vpn/profile';
import { SessionOperationSupersededError } from '@/vpn/sessionOperation';

type UseVpnConnectionFlowInput = {
  isCurrentSessionOperation: () => boolean;
  antiLeakEnabled: boolean;
  selectedLocationId: string;
  serverSelectionMode: ServerSelectionMode;
  availableLocations: VpnLocation[];
  cacheProfile: (locationId: string, profile: VpnProfile) => void;
  resolveConnectableVpnProfile: (
    locationId: string,
    options?: {
      preferCached?: boolean;
      forceRefresh?: boolean;
      validateCachedProfile?: boolean;
      requestPermission?: boolean;
    }
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

  const connectProfileWithEndpointFallback = useCallback(async (profile: VpnProfile, isCurrentOperation: () => boolean = () => true, beforeNativeConnect?: () => Promise<unknown>) => {
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
            nativeStartMs = Date.now();
            nativeDispatched = true;
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
          if (error instanceof VpnProfileKeyChangedError || error instanceof SessionOperationSupersededError) throw error;
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
  }, [antiLeakEnabled, isCurrentSessionOperation, requireCurrentSession, session?.accessToken, session?.user.id]);

  const connectCurrentVpn = useCallback(async ({
    locationId = selectedLocationId,
    waitForAnimation = false,
    requestPermission = true,
    isCurrentOperation = () => true,
  }: {
    locationId?: string;
    waitForAnimation?: boolean;
    requestPermission?: boolean;
    isCurrentOperation?: () => boolean;
  } = {}) => {
    const requireCurrentOperation = () => {
      requireCurrentSession();
      if (!isCurrentOperation()) throw new SessionOperationSupersededError();
    };
    requireCurrentOperation();
    const resolveCurrentProfile: typeof resolveConnectableVpnProfile = async (location, options = {}) => {
      requireCurrentOperation();
      try {
        const resolve = () => resolveConnectableVpnProfile(location, {
          ...options,
          // Only an explicit manual connect may obtain/reclaim Android's VPN
          // grant. Automatic retries retain this prohibition for every route.
          requestPermission: requestPermission && options.requestPermission !== false,
        });
        // Smart routing captures this app too. A failed tunnel must not carry
        // the API request that repairs it; keep other app UIDs protected.
        return options.forceRefresh && options.requestPermission === false
          ? await withProfileRecoveryTransport(resolve)
          : await resolve();
      } finally {
        requireCurrentOperation();
      }
    };
    const connectCurrentProfile = async (candidate: VpnProfile) => {
      requireCurrentOperation();
      try {
        return await connectProfileWithEndpointFallback(candidate, isCurrentOperation);
      } finally {
        requireCurrentOperation();
      }
    };
    const tapStartedAt = Date.now();
    void waitForAnimation;

    const initialLocationId = serverSelectionMode === 'auto'
      ? chooseBestVpnLocation(availableLocations)?.id ?? locationId
      : locationId;
    let profile: VpnProfile | null = null;
    let profileLocationId = initialLocationId;
    let lastProfileError: unknown;
    // Разрешаем все локации параллельно: сумма последовательных запросов
    // стоит дороже, чем самый долгий из параллельных.
    const orderedLocations = profileResolutionOrder(initialLocationId, availableLocations);
    const profileResults = await Promise.allSettled<{ locationId: string; profile: VpnProfile } | { locationId: string; profile: null; error: unknown }>(
      orderedLocations.map(async (candidate) => {
        try {
          const p = await resolveCurrentProfile(candidate.id, explicitConnectProfileResolutionOptions);
          return { locationId: candidate.id, profile: p } as { locationId: string; profile: VpnProfile };
        } catch (error) {
          return { locationId: candidate.id, profile: null, error } as { locationId: string; profile: null; error: unknown };
        }
      })
    );
    for (const result of profileResults) {
      if (result.status === 'fulfilled') {
        if (result.value.profile) {
          profile = result.value.profile;
          profileLocationId = result.value.locationId;
          break;
        }
      } else {
        lastProfileError = result.reason;
        if (!isProfileResolutionFallbackError(result.reason)) {
          throw result.reason;
        }
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
    // A cached or hot profile can be stale. Fetch a fresh one in parallel so
    // recovery does not add a second network round trip on the slow path. The
    // prefetch is superseded if the first connect attempt succeeds, so its
    // result cannot overwrite the just-connected profile in the cache.
    let prefetchSuperseded = false;
    const freshProfilePrefetch = isUnverifiedProfileSource(profile)
      ? resolveCurrentProfile(profileLocationId, { forceRefresh: true, preferCached: false, requestPermission: false }).then((fresh) => (prefetchSuperseded ? null : fresh)).catch(() => null)
      : null;

    try {
      connected = await connectCurrentProfile(profile);
      prefetchSuperseded = true;
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
    }

    try {
      if (!connected) {
        let freshProfile: VpnProfile | undefined;
        try {
          connected = await connectFreshSameLocationProfile({
            connectProfile: connectCurrentProfile,
            locationId: profileLocationId,
            resolveProfile: async (locationId, options) => (freshProfilePrefetch ? await freshProfilePrefetch : null)
              ?? resolveCurrentProfile(locationId, options),
          });
        } catch (error) {
          lastConnectError = error;
          // Issuance can commit placement before losing its reply. A transport-
          // shaped preparation error cannot authorize another location's issue.
          if (!isProfileResolutionFallbackError(error)) {
            throw error;
          }
        }
        if (freshProfile) {
          try {
            connected = await connectCurrentProfile(freshProfile);
            connectedLocationId = profileLocationId;
          } catch (error) {
            lastConnectError = error;
            if (!isVpnTransportFallbackError(error) && !isProfileResolutionFallbackError(error)) {
              throw error;
            }
          }
        }
      }

      // Разрешаем все профили фолбэков параллельно, затем пробуем подключаться
      // по очереди (одновременные туннели невозможны, но чтение профилей — параллельно).
      const fallbackLocations = profileResolutionOrder(profileLocationId, availableLocations)
        .filter((location) => location.id !== profileLocationId);
      const fallbackProfileResults = await Promise.allSettled(
        fallbackLocations.map(async (location) => {
          try {
            const p = await resolveCurrentProfile(location.id, {
              forceRefresh: true,
              preferCached: false,
              requestPermission: false,
            });
            return { locationId: location.id, profile: p as VpnProfile };
          } catch {
            return { locationId: location.id, profile: null as VpnProfile | null };
          }
        })
      );
      const fallbackProfiles = fallbackProfileResults
        .filter((r): r is PromiseFulfilledResult<{ locationId: string; profile: VpnProfile }> =>
          r.status === 'fulfilled' && r.value.profile !== null
        )
        .map((r) => r.value);

      for (const { locationId, profile: fallbackProfile } of fallbackProfiles) {
        if (connected?.status.state === 'connected') break;
        try {
          connected = await connectCurrentProfile(fallbackProfile);
          connectedLocationId = locationId;
        } catch (error) {
          lastConnectError = error;
          if (!isVpnTransportFallbackError(error)) {
            throw error;
          }
          const freshFallbackProfile = await resolveProfileOrSkipMissing(() => resolveCurrentProfile(locationId, {
            forceRefresh: true,
            preferCached: false,
            requestPermission: false,
          }));
          if (!freshFallbackProfile) continue;
          try {
            connected = await connectCurrentProfile(freshFallbackProfile);
            connectedLocationId = locationId;
          } catch (freshError) {
            lastConnectError = freshError;
            if (!isVpnTransportFallbackError(freshError)) {
              throw freshError;
            }
          }
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

    if (connectedLocationId !== selectedLocationId) {
      const persistedLocationId = await setSelectedVpnLocation(connectedLocationId);
      requireCurrentOperation();
      setSelectedLocationId(persistedLocationId);
      cacheProfile(persistedLocationId, connected.profile);
    }

    requireCurrentOperation();
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
    availableLocations,
    cacheProfile,
    clientLatencyMs,
    connectProfileWithEndpointFallback,
    reportVpnConnectEvent,
    requireCurrentSession,
    resolveConnectableVpnProfile,
    selectedLocationId,
    setSelectedLocationId,
    serverSelectionMode,
    session,
    setActiveProfile,
    setVpnStatus,
    vpnStatus,
  ]);

  return {
    connectProfileWithEndpointFallback,
    connectCurrentVpn,
  };
}
