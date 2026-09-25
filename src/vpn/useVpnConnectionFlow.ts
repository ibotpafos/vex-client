import { useCallback } from 'react';
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
  vpnConnectTelemetry,
  vpnConnectTimingSamples,
} from '@/vpn/connectFlow';
import {
  connectAttemptTimeoutMs,
  type ConnectedVpnAttempt,
  errorMessage,
  withTimeout,
} from '@/screens/home-screen-helpers';
import {
  connectVpn,
  disconnectVpn,
  getVpnStatus,
  type VpnStatus,
} from '@/native/vexVpn';
import { waitForVerifiedVpnConnection } from '@/vpn/connectVerification';
import { cleanupFailedVpnConnection } from '@/vpn/failedConnectionCleanup';
import {
  isProfileResolutionFallbackError,
  profileResolutionOrder,
} from '@/vpn/profileResolutionFallback';
import { androidVpnProfileWithinBinderBudget } from '@/vpn/androidRoutingSafety';
import { vpnProfileAddressMatchesDevice } from '@/vpn/profileConsistency';
import {
  getVpnApplicationSelection,
  setSelectedVpnLocation,
} from '@/settings/vpnPreferences';
import {
  chooseBestVpnLocation,
  type ServerSelectionMode,
} from '@/vpn/serverSelection';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import { submitClientDiagnostics, type VpnLocation } from '@/api/vexApi';
import { dynamicRouteRuntime } from '@/vpn/dynamicRouteRuntime';
import { routeTransport, type DynamicRouteAttempt, type DynamicRouteCandidate } from '@/vpn/dynamicRouteCore';
import type { VpnProfile } from '@/vpn/profile';
import { connectFreshSameLocationProfile } from '@/vpn/sameLocationProfileRecovery';

type UseVpnConnectionFlowInput = {
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

  const connectProfileWithEndpointFallback = useCallback(async (profile: VpnProfile) => {
    if (!vpnProfileAddressMatchesDevice(profile)) {
      throw new Error('VPN connection failed: cached profile address does not match its device assignment.');
    }
    if (!androidVpnProfileWithinBinderBudget(Platform.OS, profile.config)) {
      throw new Error('Android VPN profile exceeds the safe route limit. Refresh the profile before connecting.');
    }
    const endpointAttempts: string[] = [];
    const applicationSelection = await getVpnApplicationSelection();
    if (Platform.OS === 'android' && session?.user.id && session.accessToken) {
      await dynamicRouteRuntime.prepare(session.user.id, session.accessToken);
    }
    const attempts: DynamicRouteAttempt[] = Platform.OS === 'android'
      ? dynamicRouteRuntime.attempts(profile)
      : connectionAttemptsForProfile(profile).map((attempt) => ({ profile: attempt }));
    let previousRouteTransport: 'awg3_direct' | 'awg3_relay' | undefined;
    let lastError: unknown = new Error('VPN connection failed.');
    const reportRoute = (candidate: DynamicRouteCandidate, event: 'connect_failed' | 'connect_succeeded' | 'fallback_failed' | 'fallback_succeeded', status: string) => {
      if (!session?.accessToken) return;
      void submitClientDiagnostics(session.accessToken, {
        reason: 'dynamic_route', status, platform: 'android', deviceId: profile.device?.id,
        connectionEvent: event, transportFrom: previousRouteTransport,
        transportTo: routeTransport(candidate),
      }).catch(() => undefined);
    };
    for (const { profile: attempt, candidate } of attempts) {
      try {
        const endpoint = profileEndpoint(attempt);
        if (endpoint) {
          endpointAttempts.push(endpoint);
        }
        const previousStatus = Platform.OS === 'android'
          ? await getVpnStatus().catch(() => null)
          : null;
        const nativeStartMs = Date.now();
        const startedStatus = await withTimeout(
          connectVpn(attempt.config, {
            antiLeakEnabled,
            applicationRoutingMode: applicationSelection.mode,
            selectedApplications: applicationSelection.packageNames,
          }),
          connectAttemptTimeoutMs,
          'VPN connect timed out.',
        );
        const interfaceUpMs = Date.now();
        const status = await waitForVerifiedVpnConnection(startedStatus, getVpnStatus, {
          // The native backend can briefly expose the previous peer timestamp
          // while replacing a tunnel. Require activity from this attempt. The
          // small tolerance covers second-resolution backend timestamps.
          minimumHandshakeEpochMillis: nativeStartMs - 2_000,
          previousHandshakeEpochMillis: previousStatus?.latestHandshakeEpochMillis,
        });
        const verificationCompletedMs = Date.now();
        // TODO(android-route-canary): require DNS and HTTPS over a VPN-bound
        // socket before calling this full data-plane recovery. A plain JS fetch
        // can bypass the tunnel in per-app mode, so it cannot prove this safely.
        if (candidate) {
          dynamicRouteRuntime.recordSuccess(candidate);
          reportRoute(candidate, previousRouteTransport ? 'fallback_succeeded' : 'connect_succeeded', 'ok');
        } else {
          dynamicRouteRuntime.clearActive();
        }
        return {
          interfaceUpMs,
          endpointAttempts,
          nativeStartMs,
          profile: withLastSuccessfulEndpoint(attempt, endpoint),
          status,
          verificationCompletedMs,
        };
      } catch (error) {
        lastError = error;
        if (!isVpnTransportFallbackError(error)) {
          throw error;
        }
        if (candidate) {
          dynamicRouteRuntime.recordFailure(candidate);
          reportRoute(candidate, previousRouteTransport ? 'fallback_failed' : 'connect_failed', 'error');
          previousRouteTransport = routeTransport(candidate);
        }
      }
    }
    throw lastError;
  }, [antiLeakEnabled, session?.accessToken, session?.user.id]);

  const connectCurrentVpn = useCallback(async ({
    locationId = selectedLocationId,
    waitForAnimation = false,
  }: {
    locationId?: string;
    waitForAnimation?: boolean;
  } = {}) => {
    const tapStartedAt = Date.now();
    void waitForAnimation;

    const initialLocationId = serverSelectionMode === 'auto'
      ? chooseBestVpnLocation(availableLocations)?.id ?? locationId
      : locationId;
    let profile: VpnProfile | null = null;
    let profileLocationId = initialLocationId;
    let lastProfileError: unknown;
    for (const candidate of profileResolutionOrder(initialLocationId, availableLocations)) {
      try {
        // Start with the locally validated profile. Revocation events and the
        // two-minute background refresh clear it; handshake verification below
        // still prevents a stale peer from being reported as connected. A failed
        // local attempt is retried with a fresh same-location profile.
        profile = await resolveConnectableVpnProfile(candidate.id, explicitConnectProfileResolutionOptions);
        profileLocationId = candidate.id;
        break;
      } catch (error) {
        lastProfileError = error;
        if (!isProfileResolutionFallbackError(error)) {
          throw error;
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

    try {
      connected = await connectProfileWithEndpointFallback(profile);
    } catch (error) {
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

    if (!connected) {
      try {
        connected = await connectFreshSameLocationProfile({
          connectProfile: connectProfileWithEndpointFallback,
          locationId: profileLocationId,
          resolveProfile: resolveConnectableVpnProfile,
        });
        connectedLocationId = profileLocationId;
      } catch (error) {
        lastConnectError = error;
        if (!isVpnTransportFallbackError(error)) {
          throw error;
        }
      }
    }

    for (const fallbackLocation of availableLocations) {
      if (connected?.status.state === 'connected' || fallbackLocation.id === profileLocationId) {
        continue;
      }
      const fallbackProfile = await resolveConnectableVpnProfile(fallbackLocation.id, {
        preferCached: true,
        requestPermission: false,
      });
      try {
        connected = await connectProfileWithEndpointFallback(fallbackProfile);
        connectedLocationId = fallbackLocation.id;
      } catch (error) {
        lastConnectError = error;
        if (!isVpnTransportFallbackError(error)) {
          throw error;
        }
        const freshFallbackProfile = await resolveConnectableVpnProfile(fallbackLocation.id, {
          forceRefresh: true,
          preferCached: false,
          requestPermission: false,
        });
        try {
          connected = await connectProfileWithEndpointFallback(freshFallbackProfile);
          connectedLocationId = fallbackLocation.id;
        } catch (freshError) {
          lastConnectError = freshError;
          if (!isVpnTransportFallbackError(freshError)) {
            throw freshError;
          }
        }
      }
    }

    if (!connected || connected.status.state !== 'connected') {
      await cleanupFailedVpnConnection(antiLeakEnabled, disconnectVpn, lastConnectError).catch(() => undefined);
      throw lastConnectError ?? new Error('VPN не подключился.');
    }

    if (connectedLocationId !== selectedLocationId) {
      const persistedLocationId = await setSelectedVpnLocation(connectedLocationId);
      setSelectedLocationId(persistedLocationId);
      cacheProfile(persistedLocationId, connected.profile);
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
